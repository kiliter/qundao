import XCTest
@testable import QundaoCore

private final class GroupStateAlphaStub: URLProtocol {
  static var response: (() throws -> [String: Any])?
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      var payload = try Self.response!()
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
      let offset = Int(query.first { $0.name == "offset" }!.value!)!
      payload["status"] = "ok"; payload["account_id"] = "a"; payload["offset"] = offset
      if payload["hasMore"] as? Bool == true { payload["nextOffset"] = offset + (payload["items"] as? [Any] ?? []).count }
      let data = try JSONSerialization.data(withJSONObject: payload)
      client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}

@MainActor final class GroupStateTransportTests: XCTestCase {
  private func source() -> AlphaClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [GroupStateAlphaStub.self]
    return AlphaClient(token: "synthetic", session: URLSession(configuration: config))
  }

  func testAlphaUnreadCountTransitionsThroughRealTransportParser() async throws {
    var unread: Any = 8
    GroupStateAlphaStub.response = {
      ["items": [["id": "g@chatroom", "display_name": "群", "unread_count": unread]], "hasMore": false]
    }
    let client = source()
    let sync = GroupStateSynchronizer(account: "a", load: client.groups)
    for (value, expected) in [(8 as Any, 8), (0 as Any, 0), ("3" as Any, 3)] {
      unread = value
      _ = try await sync.refresh(account: "a")
      XCTAssertEqual(sync.state.groups.first?.unread, expected)
      XCTAssertNil(sync.state.error)
    }
  }
  func testAlphaActivityTimestampIsPreservedForUnreadOrdering() async throws {
    GroupStateAlphaStub.response = {
      ["items": [["id": "g@chatroom", "display_name": "群", "unread_count": 2,
                   "last_activity_unix_ms": "1792560000000"]], "hasMore": false]
    }
    let groups = try await source().groups(account: "a")
    XCTAssertEqual(groups.first?.lastActivityTimestamp, 1_792_560_000_000)
  }

  func testMissingOrInvalidCountsNeverClearPreviousUnread() async throws {
    var row: [String: Any] = ["id": "g@chatroom", "display_name": "群", "unread_count": 7]
    GroupStateAlphaStub.response = { ["items": [row], "hasMore": false] }
    let client = source()
    let sync = GroupStateSynchronizer(account: "a", load: client.groups)
    _ = try await sync.refresh(account: "a")
    let time = sync.state.lastSync
    let invalid: [Any?] = [nil, NSNull(), true, -1, 1.5, "不是数字", ""]
    for value in invalid {
      row["unread_count"] = value
      do { _ = try await sync.refresh(account: "a"); XCTFail("无效未读数应拒绝整次同步") } catch {}
      XCTAssertEqual(sync.state.groups.first?.unread, 7)
      XCTAssertEqual(sync.state.lastSync, time)
      XCTAssertNotNil(sync.state.error)
    }
  }

  func testInvalidLaterPageCannotPartiallyReplaceGroupState() async throws {
    var call = 0
    GroupStateAlphaStub.response = {
      call += 1
      if call == 1 {
        return ["items": [["id": "g@chatroom", "display_name": "群", "unread_count": 0]], "hasMore": true]
      }
      return ["items": [["id": "h@chatroom", "display_name": "另一群"]], "hasMore": false]
    }
    let client = source()
    let sync = GroupStateSynchronizer(account: "a", cachedGroups: [ChatGroup(id: "g@chatroom", name: "群", unread: 4)], load: client.groups)
    do { _ = try await sync.refresh(account: "a"); XCTFail("后续页异常不能提交前页") } catch {}
    XCTAssertEqual(call, 2)
    XCTAssertEqual(sync.state.groups.first?.unread, 4)
    XCTAssertNil(sync.state.lastSync)
    XCTAssertNotNil(sync.state.error)
  }
}
