import XCTest
@testable import QundaoCore

final class PushMessageTests: XCTestCase {
  private let group = "g@chatroom"
  private func decode(_ root: [String: Any]) throws -> Message? {
    PushMessage.decode(try JSONSerialization.data(withJSONObject: root), account: "a", allowedGroups: [group])
  }
  private var row: [String: Any] {
    ["sessionId": group, "id": "local-42", "sent_at_unix_ms": "1700000000000", "text": "合成消息"]
  }
  func testZeroPreferredMessageIDsFallBackToUsableIdentity() throws {
    for key in ["rawid", "server_id"] {
      var payload = row; payload[key] = "0"
      XCTAssertEqual(try decode(payload)?.id, "local-42")
    }
    var payload = row; payload["rawid"] = "0"; payload["server_id"] = "9007199254740993"
    XCTAssertEqual(try decode(payload)?.id, "9007199254740993")
    payload["rawid"] = "local-42"
    XCTAssertEqual(try decode(payload)?.id, "9007199254740993", "推送与 REST 使用相同的非零 server_id")
  }
  func testExplicitAccountAtEitherEnvelopeLevelMustMatch() throws {
    for key in ["accountId", "account_id"] {
      var wrong = row; wrong[key] = "b"
      XCTAssertNil(try decode(wrong))
      XCTAssertNil(try decode(["accountId": "a", "message": wrong]))
      var matching = row; matching[key] = "a"
      XCTAssertNotNil(try decode(["message": matching]))
    }
  }
}
