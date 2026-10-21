import XCTest
@testable import QundaoCore

private func sample(_ id: Int, timestamp: Int64? = nil) -> Message {
  Message(id: "M\(id)", accountID: "a", groupID: "g", senderID: "other", sender: "同事",
          text: "原文 \(id)", timestamp: timestamp ?? Int64(id))
}
private final class FakeUnread: UnreadSource {
  var messages: [Message]
  var count: Int
  var fullReads = 0
  var pageCalls: [(Int64?, String?, Int)] = []
  var onPage: ((FakeUnread, String?) -> Void)?
  var repeatCursor = false
  init(_ messages: [Message], unread: Int? = nil) { self.messages = messages; count = unread ?? messages.count }
  func unreadGroup(_ scope: ConversationScope) async throws -> ChatGroup { ChatGroup(id: "g", name: "测试群", unread: count) }
  func unreadPage(_ scope: ConversationScope, before: Int64?, cursor: String?, limit: Int) async throws -> MessagePage {
    pageCalls.append((before, cursor, limit))
    if before != nil { fullReads += 1; onPage?(self, cursor) }
    let source = messages.reversed().filter { before == nil || $0.timestamp < before! }
    let offset = Int(cursor ?? "0") ?? 0
    let rows = Array(source.dropFirst(offset).prefix(limit))
    let next = offset + rows.count < source.count ? (repeatCursor ? "0" : "\(offset + rows.count)") : nil
    return MessagePage(messages: rows, cursor: next)
  }
}
final class UnreadSnapshotTests: XCTestCase {
  let scope = ConversationScope(account: "a", group: "g")
  func testAllPagesWithSameTimestampsKeepStableOrderAndUnreadBoundary() async throws {
    let source = FakeUnread((1...505).map { sample($0, timestamp: 100) }, unread: 501)
    let snapshot = try await UnreadSnapshotLoader(source: source).load(scope)
    XCTAssertEqual(snapshot.messages.count, 501)
    XCTAssertEqual(snapshot.messages.first?.id, "M5")
    XCTAssertEqual(snapshot.messages.last?.id, "M505")
    XCTAssertEqual(Set(snapshot.messages.map(\.id)).count, 501)
    let pages = source.pageCalls.filter { $0.0 != nil }
    XCTAssertEqual(pages.map { $0.2 }, [200, 200, 101])
    XCTAssertEqual(Set(pages.map { $0.0! }), [101])
  }
  func testNewMessageDuringPaginationRestartsThenIncludesWholeNewSnapshot() async throws {
    let source = FakeUnread((1...205).map { sample($0) })
    var added = false
    source.onPage = { source, cursor in
      if cursor != nil && !added { source.messages.append(sample(206)); source.count += 1; added = true }
    }
    let snapshot = try await UnreadSnapshotLoader(source: source).load(scope)
    XCTAssertEqual(snapshot.messages.count, 206); XCTAssertEqual(snapshot.messages.last?.id, "M206")
    XCTAssertEqual(source.fullReads, 4)
  }
  func testChangingReadBoundaryRetriesAndNeverIncludesReadMessages() async throws {
    let source = FakeUnread((1...205).map { sample($0) })
    var changed = false
    source.onPage = { source, cursor in
      if cursor != nil && !changed { source.count = 3; changed = true }
    }
    let snapshot = try await UnreadSnapshotLoader(source: source).load(scope)
    XCTAssertEqual(snapshot.messages.map(\.id), ["M203", "M204", "M205"])
  }
  func testMissingPageAndStuckCursorFailInsteadOfPartialSuccess() async {
    for stuck in [false, true] {
      let source = FakeUnread((1...205).map { sample($0) }, unread: stuck ? 205 : 300)
      source.repeatCursor = stuck
      do { _ = try await UnreadSnapshotLoader(source: source).load(scope); XCTFail("不完整页不能成功") }
      catch { XCTAssertTrue(error.localizedDescription.contains("分页")) }
    }
  }
  func testNoUnreadDoesNotReadMessagePages() async throws {
    let source = FakeUnread([sample(1)], unread: 0)
    let value = try await UnreadSnapshotLoader(source: source).load(scope)
    XCTAssertTrue(value.messages.isEmpty); XCTAssertTrue(source.pageCalls.isEmpty)
  }
}

private final class AlphaStub: URLProtocol {
  static var responder: ((URLRequest) throws -> Data)?
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let data = try Self.responder!(request)
      client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}
final class AlphaSnapshotTransportTests: XCTestCase {
  func testActualAlphaClientPaginatesCompleteUnreadAndKeepsUpperBound() async throws {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AlphaStub.self]
    var pageLimits: [Int] = []
    AlphaStub.responder = { req in
      XCTAssertEqual(req.httpMethod, "GET")
      let query = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!.queryItems!
      let args = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value!) })
      XCTAssertEqual(args["account"], "a")
      let offset = Int(args["offset"] ?? "0")!
      var payload: [String: Any] = ["status": "ok", "account_id": "a", "offset": offset]
      if req.url!.path == "/api/v1/sessions" {
        payload["items"] = [["id": "g@chatroom", "display_name": "群", "unread_count": 401]]
        payload["hasMore"] = false
      } else {
        XCTAssertEqual(req.url!.path, "/api/v1/messages")
        XCTAssertEqual(args["username"], "g@chatroom")
        XCTAssertEqual(args["order"], "desc")
        let limit = Int(args["limit"]!)!
        if args["end"] != nil { XCTAssertEqual(args["end"], "0"); pageLimits.append(limit) }
        let rows = Array((1...401).reversed().dropFirst(offset).prefix(limit)).map { n in
          ["id": "local-\(n)", "server_id": "S\(n)", "conversation_id": "g@chatroom", "sender_id": "other",
           "sender_name": "同事", "text": "正文", "sent_at_unix_ms": "\(n)"]
        }
        payload["talker"] = "g@chatroom"; payload["messages"] = rows
        payload["hasMore"] = offset + rows.count < 401; payload["nextOffset"] = offset + rows.count
      }
      return try JSONSerialization.data(withJSONObject: payload)
    }
    let source = AlphaClient(token: "synthetic", session: URLSession(configuration: config))
    let snapshot = try await UnreadSnapshotLoader(source: source).load(ConversationScope(account: "a", group: "g@chatroom"))
    XCTAssertEqual(snapshot.messages.count, 401); XCTAssertEqual(snapshot.messages.first?.id, "S1")
    XCTAssertEqual(snapshot.messages.last?.id, "S401"); XCTAssertEqual(pageLimits, [200, 200, 1])
  }
}
