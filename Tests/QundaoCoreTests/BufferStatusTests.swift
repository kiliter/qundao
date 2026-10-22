import XCTest
@testable import QundaoCore

final class BufferStatusTests: XCTestCase {
  private func message(_ id: String, group: String, account: String = "a") -> Message {
    Message(id: id, accountID: account, groupID: group, senderID: "s", sender: "同事", text: "合成正文", timestamp: 1)
  }
  func testDeadlineUsesFirstArrivalAndIgnoresOtherAccounts() {
    var buffer = RealtimeBuffer()
    let t0 = Date(timeIntervalSince1970: 1000)
    buffer.receive(message("1", group: "x@chatroom"), now: t0)
    buffer.receive(message("2", group: "x@chatroom"), now: t0.addingTimeInterval(2))
    buffer.receive(message("3", group: "y@chatroom"), now: t0.addingTimeInterval(1))
    buffer.receive(message("4", group: "z@chatroom", account: "b"), now: t0)
    let status = buffer.status(account: "a", capacity: 30, interval: 3)
    XCTAssertEqual(status.count, 3)
    XCTAssertEqual(status.groups.map(\.group), ["x@chatroom", "y@chatroom"])
    XCTAssertEqual(status.groups.first?.count, 2)
    // 后到消息不延后截止时间。
    XCTAssertEqual(status.deadline, t0.addingTimeInterval(3))
    XCTAssertEqual(buffer.status(account: "c", capacity: 30, interval: 3), BufferStatus(count: 0, capacity: 30, groups: []))
  }
}
