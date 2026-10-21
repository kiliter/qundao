import XCTest
@testable import QundaoCore

final class ReadingWorkflowTests: XCTestCase {
  private func digest(_ group: String, messageTime: Int64, generated: TimeInterval = 1_000, account: String = "a") -> Digest {
    let message = Message(id: "M1", accountID: account, groupID: group, senderID: "sender", sender: "同事",
                          text: "需要关注的内容", timestamp: messageTime)
    var value = Digest(accountID: account, groupID: group, groupName: group, text: "摘要", count: 1,
                       evidence: [message], related: true, relevanceReason: "与工作相关")
    value.date = Date(timeIntervalSince1970: generated)
    return value
  }
  func testSummaryOrderUsesLatestUnreadTimeInsteadOfGenerationTime() {
    let older = digest("old", messageTime: 100_000, generated: 9_000)
    let newer = digest("new", messageTime: 200_000, generated: 1_000)
    let groups = [ChatGroup(id: "old", name: "old", unread: 1, lastActivityTimestamp: 100_000),
                  ChatGroup(id: "new", name: "new", unread: 2, lastActivityTimestamp: 200_000)]
    let rows = SummaryTimeline.threads(digests: [older, newer], groups: groups, account: "a")
    XCTAssertEqual(rows.map(\.id), ["new", "old"])
    XCTAssertEqual(rows.first?.messageDate, Date(timeIntervalSince1970: 200))
  }
  func testUnreadGroupsStayAboveReadGroupsAndUseNewAlphaActivityBeforeSummaryCompletes() {
    let groups = [ChatGroup(id: "waiting", name: "等待摘要", unread: 1, lastActivityTimestamp: 500_000),
                  ChatGroup(id: "read", name: "已读", unread: 0, lastActivityTimestamp: 900_000),
                  ChatGroup(id: "other", name: "另一群", unread: 2, lastActivityTimestamp: 300_000)]
    let rows = SummaryTimeline.threads(digests: [digest("waiting", messageTime: 100_000),
      digest("read", messageTime: 900_000), digest("other", messageTime: 300_000)], groups: groups, account: "a")
    XCTAssertEqual(rows.map(\.id), ["waiting", "other", "read"])
  }
  func testBatchOrderUsesMessageTimeAndLegacyGroupLoadsWithoutActivityField() throws {
    let oldGroup = try JSONDecoder().decode(ChatGroup.self, from: Data(#"{"id":"g","name":"群","unread":2}"#.utf8))
    XCTAssertNil(oldGroup.lastActivityTimestamp)
    let older = digest("g", messageTime: 100_000, generated: 9_000)
    let newer = digest("g", messageTime: 200_000, generated: 1_000)
    let rows = SummaryTimeline.threads(digests: [older, newer, digest("other", messageTime: 999_000, account: "b")],
                                       groups: [oldGroup], account: "a")
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows[0].digests.map(\.id), [newer.id, older.id])
  }
  func testOneClickViewedOnlyUpdatesCapturedRecordsForCurrentAccount() throws {
    var state = AppSnapshot()
    let a = digest("g", messageTime: 100), b = digest("g", messageTime: 200, account: "b")
    let arrivedLater = digest("g", messageTime: 300)
    let response = Attention(message: a.evidence[0], groupName: "群", title: "提醒", reason: "命中", definite: true)
    state.digests = [a, b, arrivedLater]
    state.attentions = [response]
    state.groups = [ChatGroup(id: "g", name: "群", unread: 10)]
    state.markViewed(account: "a", digestIDs: [a.id, b.id], attentionIDs: [response.id], now: Date(timeIntervalSince1970: 500))
    XCTAssertNotNil(state.digests[0].attentionReadAt)
    XCTAssertNil(state.digests[1].attentionReadAt)
    XCTAssertNil(state.digests[2].attentionReadAt, "操作后新到的摘要不能被提前已阅")
    XCTAssertEqual(state.attentions[0].status, "done")
    XCTAssertEqual(state.groups[0].unread, 10)
    let restored = try JSONDecoder().decode(AppSnapshot.self, from: JSONEncoder().encode(state))
    XCTAssertEqual(AttentionFeed.entries(attentions: restored.attentions, digests: restored.digests, account: "a").count, 1)
    XCTAssertEqual(AttentionFeed.entries(attentions: restored.attentions, digests: restored.digests, account: "a", includeHistory: true).count, 3)
  }
  func testSummaryViewedDoesNotChangeAlphaOrIndependentlyPendingReminder() {
    var state = AppSnapshot()
    let value = digest("g", messageTime: 100)
    state.digests = [value]
    state.groups = [ChatGroup(id: "g", name: "群", unread: 2)]
    state.attentions = [Attention(message: value.evidence[0], groupName: "群", title: "提醒", reason: "命中", definite: true)]
    state.markViewed(account: "a", digestIDs: [value.id])
    XCTAssertEqual(state.attentions[0].status, "pending")
    XCTAssertEqual(state.groups[0].unread, 2)
    XCTAssertNotNil(state.digests[0].attentionReadAt)
  }
}
