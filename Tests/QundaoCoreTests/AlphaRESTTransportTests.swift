import XCTest
@testable import QundaoCore

private final class RESTStub: URLProtocol {
  static var reply: ((URLRequest) throws -> (Int, [String: Any]))?
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let (status, body) = try Self.reply!(request)
      client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
        httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: body))
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}

@MainActor final class AlphaRESTTransportTests: XCTestCase {
  private func client() -> AlphaClient {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RESTStub.self]
    return AlphaClient(token: "secret-test-token", session: URLSession(configuration: config))
  }
  private func query(_ request: URLRequest) -> [String: String] {
    Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []).map { ($0.name, $0.value ?? "") })
  }
  private func row(_ time: Int64, group: String = "g@chatroom") -> [String: Any] {
    ["id": "local-\(time)", "server_id": "S\(time)", "conversation_id": group,
     "sent_at_unix_ms": "\(time)", "sender_id": "sender", "sender_name": "同事", "text": "消息"]
  }
  private func response(_ rows: [[String: Any]], offset: Int = 0, next: Int? = nil) -> [String: Any] {
    ["status": "ok", "account_id": "a", "talker": "g@chatroom", "messages": rows,
     "offset": offset, "hasMore": next != nil, "nextOffset": next as Any? ?? NSNull()]
  }
  func testAccountsUseRESTGetWithHeaderOnlyAuthentication() async throws {
    RESTStub.reply = { request in
      XCTAssertEqual(request.url?.path, "/api/v1/accounts")
      XCTAssertEqual(request.httpMethod, "GET"); XCTAssertNil(request.httpBody)
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-test-token")
      XCTAssertFalse(request.url!.absoluteString.contains("secret-test-token"))
      return (200, ["status": "ok", "accounts": [["id": "a", "display_name": "账号", "subject_id": "self", "usable": true],
        ["id": "unusable", "usable": false]]])
    }
    let values = try await client().accounts()
    XCTAssertEqual(values.map(\.id), ["a"]); XCTAssertEqual(values.first?.subjectID, "self")
  }
  func testSessionsUseRawPageOffsetAcrossPrivateAndGroupRows() async throws {
    var offsets: [Int] = []
    RESTStub.reply = { request in
      XCTAssertEqual(request.url?.path, "/api/v1/sessions"); XCTAssertEqual(request.httpMethod, "GET")
      let query = self.query(request); XCTAssertEqual(query["account"], "a")
      XCTAssertNil(query["include_hidden"], "REST 不接受 MCP 的布尔字符串参数")
      let offset = Int(query["offset"]!)!; offsets.append(offset)
      let rows: [[String: Any]] = offset == 0
        ? [["id": "private", "unread_count": 8], ["id": "g@chatroom", "display_name": "一群", "unread_count": 2]]
        : [["id": "h@chatroom", "display_name": "二群", "unread_count": 0]]
      return (200, ["status": "ok", "account_id": "a", "items": rows, "offset": offset,
                    "hasMore": offset == 0, "nextOffset": 2, "scanComplete": true])
    }
    let groups = try await client().groups(account: "a")
    XCTAssertEqual(groups.map(\.id), ["g@chatroom", "h@chatroom"])
    XCTAssertEqual(offsets, [0, 2], "分页步长必须包含被过滤的私聊行")
  }
  func testSecondRangeAndMillisecondFilteringContinueAcrossEmptyBoundaryPages() async throws {
    var offsets: [Int] = []
    RESTStub.reply = { request in
      XCTAssertEqual(request.url?.path, "/api/v1/messages")
      let query = self.query(request)
      XCTAssertEqual(query["account"], "a"); XCTAssertEqual(query["username"], "g@chatroom")
      XCTAssertEqual(query["start"], "10"); XCTAssertEqual(query["end"], "10")
      XCTAssertNil(query["before_unix_ms"]); XCTAssertNil(query["cursor"])
      let offset = Int(query["offset"]!)!; offsets.append(offset)
      switch offset {
      case 0: return (200, self.response([self.row(10_999), self.row(10_800)], next: 2))
      case 2: return (200, self.response([self.row(10_700), self.row(10_500)], offset: 2, next: 4))
      default: return (200, self.response([self.row(10_499)], offset: 4))
      }
    }
    let source = client()
    let first = try await source.messages(account: "a", group: "g@chatroom", after: 10_500, before: 10_800, cursor: nil, limit: 2, order: "desc")
    XCTAssertEqual(first.messages.map(\.timestamp), [10_700, 10_500])
    XCTAssertEqual(first.messages.first?.sender, "同事")
    let second = try await source.messages(account: "a", group: "g@chatroom", after: 10_500, before: 10_800,
                                            cursor: try XCTUnwrap(first.cursor), limit: 2, order: "desc")
    XCTAssertTrue(second.messages.isEmpty); XCTAssertNil(second.cursor)
    XCTAssertEqual(offsets, [0, 2, 4])
  }
  func testCursorCannotCrossAccountGroupOrRangeAndOldMcpCursorIsRejectedBeforeRequest() async throws {
    var calls = 0
    RESTStub.reply = { _ in calls += 1; return (200, self.response([self.row(1_000)], next: 1)) }
    let source = client()
    let first = try await source.messages(account: "a", group: "g@chatroom", after: nil, before: 2_000, cursor: nil)
    let cursor = try XCTUnwrap(first.cursor)
    for (account, group, before, value) in [("b", "g@chatroom", Int64(2000), cursor),
      ("a", "h@chatroom", Int64(2000), cursor), ("a", "g@chatroom", Int64(3000), cursor),
      ("a", "g@chatroom", Int64(2000), "old-mcp-cursor")] {
      do { _ = try await source.messages(account: account, group: group, after: nil, before: before, cursor: value); XCTFail("越界游标必须拒绝") }
      catch {}
    }
    XCTAssertEqual(calls, 1)
  }
  func testWrongAccountConversationAndInvalidPaginationAreRejected() async {
    let invalid: [(String, Any)] = [("account_id", "b"), ("talker", "h@chatroom"), ("offset", 1),
                                   ("nextOffset", 0), ("nextOffset", 2), ("hasMore", "true")]
    for (key, value) in invalid {
      RESTStub.reply = { _ in var result = self.response([self.row(1000)], next: 1); result[key] = value; return (200, result) }
      do { _ = try await client().messages(account: "a", group: "g@chatroom", after: nil, before: nil, cursor: nil); XCTFail("非法字段 \(key) 应失败") }
      catch {}
    }
    RESTStub.reply = { _ in (200, self.response([self.row(1000, group: "wrong@chatroom")])) }
    do { _ = try await client().messages(account: "a", group: "g@chatroom", after: nil, before: nil, cursor: nil); XCTFail("行级群聊不符") }
    catch {}
  }
  func testLargeServerIDIsPreservedAndErrorBodyNeverLeaksIntoErrorLog() async throws {
    RESTStub.reply = { _ in
      var row = self.row(1000); row["server_id"] = UInt64(9_223_372_036_854_775_809)
      return (200, self.response([row]))
    }
    let page = try await client().messages(account: "a", group: "g@chatroom", after: nil, before: nil, cursor: nil)
    XCTAssertEqual(page.messages.first?.id, "9223372036854775809")
    RESTStub.reply = { _ in (500, ["error": "禁止写日志的聊天原文 secret-test-token"]) }
    do { _ = try await client().accounts(); XCTFail("服务错误应失败") }
    catch {
      XCTAssertFalse(error.localizedDescription.contains("禁止写日志"))
      XCTAssertFalse(error.localizedDescription.contains("secret-test-token"))
      XCTAssertTrue(error.localizedDescription.contains("500"))
    }
  }
}
