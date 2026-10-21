import XCTest
@testable import QundaoCore

final class AttentionFeedTests: XCTestCase {
  private func message(id: String = "M1", account: String = "a", group: String = "g") -> Message {
    Message(id: id, accountID: account, groupID: group, senderID: "colleague", sender: "同事",
            text: "无纸化服务异常", timestamp: 1_000)
  }

  private func digest(account: String = "a", group: String = "g", related: Bool = true) -> Digest {
    Digest(accountID: account, groupID: group, groupName: "办公群", text: "关注的系统出现异常，暂未要求回应。",
           count: 1, evidence: [message(account: account, group: group)], related: related,
           relevanceReason: related ? "命中关注事项，无需回应" : "不涉及关注事项")
  }

  private func attention(id: String = "M1", account: String = "a", status: String = "pending") -> Attention {
    var result = Attention(message: message(id: id, account: account), groupName: "办公群",
                           title: "请确认", reason: "明确提及", definite: true)
    result.status = status
    return result
  }

  func testRelevantSummaryWithoutResponseAppearsInAttentionFeed() throws {
    let summary = digest()
    let entries = AttentionFeed.entries(attentions: [], digests: [summary], account: "a")
    let entry = try XCTUnwrap(entries.first)
    XCTAssertEqual(entries.count, 1)
    XCTAssertFalse(entry.isResponse, "相关知会不能冒充有人找我的消息")
    XCTAssertEqual(entry.groupID, summary.groupID)
    XCTAssertEqual(entry.groupName, summary.groupName)
    XCTAssertTrue(entry.preview.contains(summary.text))
    guard case .summary(let shown) = entry else { return XCTFail("应展示相关摘要") }
    XCTAssertEqual(shown.id, summary.id)
  }

  func testUnrelatedSummariesStayOutOfBothPendingAndHistory() {
    let unrelated = digest(related: false)
    for history in [false, true] {
      XCTAssertTrue(AttentionFeed.entries(attentions: [], digests: [unrelated], account: "a",
                                          includeHistory: history).isEmpty)
    }
  }

  func testLegacySummaryWithoutReadFieldDecodesAndAppearsImmediately() throws {
    var old = digest()
    old.attentionReadAt = Date(timeIntervalSince1970: 42)
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
    XCTAssertNotNil(json.removeValue(forKey: "attentionReadAt"))
    let restored = try JSONDecoder().decode(Digest.self, from: JSONSerialization.data(withJSONObject: json))
    XCTAssertNil(restored.attentionReadAt)
    let entries = AttentionFeed.entries(attentions: [], digests: [restored], account: "a")
    XCTAssertEqual(entries.count, 1, "旧版相关摘要无需重新跑模型即可出现在需要关注")
    XCTAssertEqual(entries.first?.id, "summary|\(old.id.uuidString)")
  }

  func testReadSummaryPersistsAcrossDiskRestartWithoutChangingAlphaUnread() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let disk = SnapshotPersistence(directory: directory)
    let readAt = Date(timeIntervalSince1970: 1_000)
    var state = AppSnapshot()
    state.preferences.accountID = "a"
    state.groups = [ChatGroup(id: "g", name: "办公群", unread: 7)]
    state.digests = [digest()]
    try disk.save(state)
    state.digests[0].attentionReadAt = readAt
    try disk.save(state)

    let restored = try SnapshotPersistence(directory: directory).load()
    XCTAssertEqual(restored.digests.first?.attentionReadAt, readAt)
    XCTAssertEqual(restored.groups.first?.unread, 7, "群岛已阅只影响关注状态，不能覆盖 Alpha 未读")
    XCTAssertTrue(AttentionFeed.entries(attentions: restored.attentions, digests: restored.digests,
                                        account: "a").isEmpty)
    XCTAssertEqual(AttentionFeed.entries(attentions: restored.attentions, digests: restored.digests,
                                         account: "a", includeHistory: true).count, 1)
  }

  func testPendingDoneAndSnoozedResponsesKeepTheirExistingVisibility() {
    let pending = attention(id: "待办")
    let done = attention(id: "已处理", status: "done")
    var snoozed = attention(id: "稍后", status: "snoozed")
    snoozed.remindAt = Date(timeIntervalSince1970: 9_000)
    let items = [pending, done, snoozed]
    let pendingEntries = AttentionFeed.entries(attentions: items, digests: [], account: "a")
    XCTAssertEqual(pendingEntries.map(\.id), ["response|\(pending.id)"])
    XCTAssertTrue(pendingEntries.allSatisfy(\.isResponse))
    let history = AttentionFeed.entries(attentions: items, digests: [], account: "a", includeHistory: true)
    XCTAssertEqual(Set(history.map(\.id)), Set(items.map { "response|\($0.id)" }))
    let statuses = history.compactMap { entry -> String? in
      guard case .response(let response) = entry else { return nil }
      return response.status
    }
    XCTAssertEqual(Set(statuses), ["pending", "done", "snoozed"])
  }

  func testAccountIsolationWithMatchingGroupsAndMessageIDs() {
    let summaries = [digest(account: "a"), digest(account: "b")]
    let responses = [attention(account: "a"), attention(account: "b")]
    for account in ["a", "b"] {
      let entries = AttentionFeed.entries(attentions: responses, digests: summaries,
                                          account: account, includeHistory: true)
      XCTAssertEqual(entries.count, 2)
      for entry in entries {
        switch entry {
        case .response(let item): XCTAssertEqual(item.message.accountID, account)
        case .summary(let item): XCTAssertEqual(item.accountID, account)
        }
      }
    }
    XCTAssertTrue(AttentionFeed.entries(attentions: responses, digests: summaries, account: "c").isEmpty)
  }

  func testDuplicateSummaryUUIDAndResponseIDAppearOnlyOnce() {
    let summary = digest()
    let response = attention()
    let entries = AttentionFeed.entries(attentions: [response, response], digests: [summary, summary], account: "a")
    XCTAssertEqual(entries.count, 2)
    XCTAssertEqual(Set(entries.map(\.id)).count, 2)
    XCTAssertEqual(entries.filter(\.isResponse).count, 1)
    XCTAssertEqual(entries.filter { !$0.isResponse }.count, 1)
  }

  func testReadingRelatedSummaryDoesNotResolveResponseFromSameMessage() {
    var summary = digest()
    summary.attentionReadAt = Date(timeIntervalSince1970: 42)
    let response = attention()
    let entries = AttentionFeed.entries(attentions: [response], digests: [summary], account: "a")
    XCTAssertEqual(entries.map(\.id), ["response|\(response.id)"])
    XCTAssertEqual(response.status, "pending")
  }

  func testViewedHistoryHasNoPendingBadgeEvenWhenAlphaHasUnread() throws {
    var state = AppSnapshot()
    state.groups = [ChatGroup(id: "g", name: "办公群", unread: 5)]
    var viewed = digest()
    viewed.attentionReadAt = Date(timeIntervalSince1970: 42)
    state.digests = [viewed]
    state.attentions = [attention(status: "done")]

    let history = AttentionFeed.threads(attentions: state.attentions, digests: state.digests,
                                        account: "a", includeHistory: true)
    let group = try XCTUnwrap(history.first)
    XCTAssertEqual(group.entries.count, 2)
    XCTAssertEqual(group.pendingCount, 0, "历史已阅群不能因为微信还有未读而亮点")
    XCTAssertEqual(state.groups[0].unread, 5)
    XCTAssertTrue(AttentionFeed.threads(attentions: state.attentions, digests: state.digests,
                                        account: "a").isEmpty)
  }

  func testHistoryToggleDoesNotChangePendingCountsForMixedGroups() throws {
    var viewed = digest()
    viewed.attentionReadAt = Date(timeIntervalSince1970: 42)
    var historicalGroup = digest(group: "history-only")
    historicalGroup.attentionReadAt = viewed.attentionReadAt
    let digests = [viewed, digest(), historicalGroup, digest(related: false)]
    let responses = [attention(), attention(id: "done", status: "done")]
    for includeHistory in [false, true, false] {
      let rows = AttentionFeed.threads(attentions: responses, digests: digests,
                                       account: "a", includeHistory: includeHistory)
      let group = try XCTUnwrap(rows.first { $0.id == "g" })
      XCTAssertEqual(group.pendingCount, 2)
      XCTAssertEqual(group.entries.count, includeHistory ? 4 : 2)
      XCTAssertEqual(rows.first { $0.id == "history-only" }?.pendingCount, includeHistory ? 0 : nil)
      let pending = AttentionFeed.entries(attentions: responses, digests: digests, account: "a")
      XCTAssertEqual(rows.reduce(0) { $0 + $1.pendingCount }, pending.count,
                     "群小点计数合计应始终与主窗口、刘海和菜单栏的待关注数一致")
    }
  }

  func testPendingBadgesDeduplicateAndIsolateAccountsAndSnoozedReminders() throws {
    let summary = digest(), response = attention()
    var snoozed = attention(id: "later", status: "snoozed")
    snoozed.remindAt = Date(timeIntervalSince1970: 9_000)
    let responses = [response, response, attention(account: "b"), snoozed]
    let summaries = [summary, summary, digest(account: "b")]
    let a = try XCTUnwrap(AttentionFeed.threads(attentions: responses, digests: summaries,
                                                account: "a", includeHistory: true).first)
    XCTAssertEqual(a.entries.count, 3)
    XCTAssertEqual(a.pendingCount, 2, "稍后提醒及重复记录不增加小点计数")
    let b = try XCTUnwrap(AttentionFeed.threads(attentions: responses, digests: summaries,
                                                account: "b", includeHistory: true).first)
    XCTAssertEqual(b.pendingCount, 2)
    XCTAssertTrue(AttentionFeed.threads(attentions: responses, digests: summaries,
                                        account: "c", includeHistory: true).isEmpty)
    snoozed.status = "pending"
    snoozed.remindAt = nil
    let due = try XCTUnwrap(AttentionFeed.threads(attentions: [response, snoozed], digests: [summary],
                                                  account: "a", includeHistory: true).first)
    XCTAssertEqual(due.pendingCount, 3, "稍后提醒到期恢复待关注后应重新计入小点")
  }

  func testOneClickViewedClearsBadgesAfterRestartAndNewSummaryRestoresOne() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let disk = SnapshotPersistence(directory: directory)
    var state = AppSnapshot()
    state.digests = [digest(), digest(group: "h"), digest(account: "b")]
    state.attentions = [attention(), attention(account: "b")]
    state.groups = [ChatGroup(id: "g", name: "办公群", unread: 5)]
    state.markViewed(account: "a", digestIDs: Set(state.digests.map(\.id)),
                     attentionIDs: Set(state.attentions.map(\.id)))
    try disk.save(state)
    var restored = try SnapshotPersistence(directory: directory).load()
    let history = AttentionFeed.threads(attentions: restored.attentions, digests: restored.digests,
                                        account: "a", includeHistory: true)
    XCTAssertEqual(history.count, 2)
    XCTAssertTrue(history.allSatisfy { $0.pendingCount == 0 })
    XCTAssertEqual(restored.groups[0].unread, 5)
    XCTAssertEqual(AttentionFeed.threads(attentions: restored.attentions, digests: restored.digests,
                                        account: "b", includeHistory: true).first?.pendingCount, 2)
    restored.digests.append(digest())
    let updated = AttentionFeed.threads(attentions: restored.attentions, digests: restored.digests,
                                        account: "a", includeHistory: true)
    XCTAssertEqual(updated.first { $0.id == "g" }?.pendingCount, 1)
    XCTAssertEqual(updated.first { $0.id == "h" }?.pendingCount, 0)
  }

  func testReadingOneEntryOnlyDecrementsItsGroupBadge() throws {
    var state = AppSnapshot()
    state.digests = [digest(), digest(group: "h")]
    state.attentions = [attention()]
    let summaryID = state.digests[0].id
    let responseID = state.attentions[0].id
    state.markViewed(account: "a", digestIDs: [summaryID])
    var rows = AttentionFeed.threads(attentions: state.attentions, digests: state.digests,
                                     account: "a", includeHistory: true)
    XCTAssertEqual(rows.first { $0.id == "g" }?.pendingCount, 1)
    XCTAssertEqual(rows.first { $0.id == "h" }?.pendingCount, 1)
    state.markViewed(account: "a", attentionIDs: [responseID])
    rows = AttentionFeed.threads(attentions: state.attentions, digests: state.digests,
                                 account: "a", includeHistory: true)
    XCTAssertEqual(rows.first { $0.id == "g" }?.pendingCount, 0)
    XCTAssertEqual(rows.first { $0.id == "h" }?.pendingCount, 1)
  }
}
