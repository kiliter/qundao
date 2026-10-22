import XCTest
@testable import QundaoCore

@MainActor final class MessageAdmissionTests: XCTestCase {
  private let policy = MessageAdmission(account: "a", groups: ["yes@chatroom", "private"])
  private func message(_ group: String, account: String = "a", id: String = "1", text: String = "正文") -> Message {
    Message(id: id, accountID: account, groupID: group, senderID: "other", sender: "同事", text: text, timestamp: 1_000)
  }
  func testRejectedPushesNeverBecomeMessagesEvenWithMentions() throws {
    for (account, group, kind) in [("a", "private", "private"), ("a", "no@chatroom", "group"),
                                   ("b", "yes@chatroom", "group"), ("a", "yes@chatroom", "private")] {
      let data = try JSONSerialization.data(withJSONObject: ["accountId": account, "sessionId": group,
        "sessionType": kind, "rawid": "42", "timestamp": 100, "content": "@所有人 不应保存的正文"])
      XCTAssertNil(PushMessage.decode(data, account: "a", allowedGroups: policy.groups))
    }
    let allowed = try JSONSerialization.data(withJSONObject: ["accountId": "a", "sessionId": "yes@chatroom",
      "sessionType": "group", "rawid": "42", "timestamp": 100, "content": "@all 请确认"])
    XCTAssertNotNil(PushMessage.decode(allowed, account: "a", allowedGroups: policy.groups))
  }
  func testRejectedIngressDoesNotMutateAnyPersistedStateOrBuffer() throws {
    var state = AppSnapshot()
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    let before = try encoder.encode(state)
    let rejected = [message("private", text: "私聊禁止原文"), message("no@chatroom", text: "越界禁止原文"),
                    message("yes@chatroom", account: "b", text: "错账号禁止原文")]
    XCTAssertEqual(state.ingestRealtime(rejected, admission: policy, selfID: "self"), 0)
    XCTAssertEqual(try encoder.encode(state), before)
    XCTAssertTrue(state.messages.isEmpty); XCTAssertNil(state.realtimeBuffer)
    XCTAssertTrue(state.seen.isEmpty); XCTAssertNil(state.decisionBatches)
  }
  func testMixedIngressOnlyPersistsWhitelistAndUnrelatedFlushDoesNotTrigger() throws {
    var state = AppSnapshot()
    let admitted = message("yes@chatroom", text: "今天食堂吃什么")
    let rejected = message("no@chatroom", text: "不应入库的 @all 请立即处理")
    let time = Date(timeIntervalSince1970: 100)
    XCTAssertEqual(state.ingestRealtime([rejected, admitted, admitted], admission: policy, selfID: "self", now: time), 1)
    XCTAssertEqual(state.messages, [admitted]); XCTAssertEqual(state.seen, [admitted.key])
    var buffer = try XCTUnwrap(state.realtimeBuffer)
    XCTAssertEqual(buffer.entries.count, 1)
    let batches = buffer.flush(account: "a", capacity: 1, interval: 10, now: time)
    XCTAssertEqual(batches.count, 1)
    let decisions = RealtimeDecision.local(batches[0].messages, preferences: Preferences(), selfID: "self")
    XCTAssertFalse(decisions.contains(where: \.related))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let disk = SnapshotPersistence(directory: directory)
    try disk.save(state)
    let restored = try disk.load()
    XCTAssertEqual(restored.messages, [admitted])
    XCTAssertFalse(String(decoding: try JSONEncoder().encode(restored), as: UTF8.self).contains("不应入库"))
  }
  func testAllowedMentionFlushTriggersAfterCapacityOrFixedDeadline() {
    for capacity in [1, 50] {
      var state = AppSnapshot()
      let time = Date(timeIntervalSince1970: 100)
      state.ingestRealtime([message("yes@chatroom", text: "@所有人 请确认")], admission: policy, selfID: "self", now: time)
      let batches = state.realtimeBuffer!.flush(account: "a", capacity: capacity, interval: 3,
                                                now: time.addingTimeInterval(capacity == 1 ? 0 : 3))
      XCTAssertEqual(batches.count, 1)
      XCTAssertTrue(RealtimeDecision.local(batches[0].messages, preferences: Preferences(), selfID: "self").contains(where: \.related))
    }
  }
  func testSenderEnrichmentUpdatesPendingCopiesWithoutResettingDeadlineOrContent() throws {
    var state = AppSnapshot()
    var original = message("yes@chatroom", text: "@所有人 合成自身消息")
    original.senderID = ""; original.sender = ""
    let start = Date(timeIntervalSince1970: 100)
    state.ingestRealtime([original], admission: policy, selfID: "self", now: start)
    let scope = ConversationScope(account: "a", group: original.groupID)
    state.decisionBatches = [DecisionBatch(scope: scope, messages: [original])]
    state.attentions = [Attention(message: original, groupName: "群", title: "找你", reason: "待核对", definite: true)]
    var incoming = original; incoming.senderID = "self"; incoming.sender = "本人"
    incoming.text = "重复响应不能替换原正文"; incoming.timestamp = 2_000
    XCTAssertEqual(state.ingestRealtime([incoming], admission: policy, selfID: "self", now: start.addingTimeInterval(2)), 0)
    let buffered = try XCTUnwrap(state.realtimeBuffer?.entries[original.key])
    XCTAssertEqual(buffered.receivedAt, start)
    for enriched in [state.messages[0], buffered.message, state.decisionBatches![0].messages[0]] {
      XCTAssertEqual(enriched.senderID, "self"); XCTAssertEqual(enriched.sender, "本人")
      XCTAssertEqual(enriched.text, original.text); XCTAssertEqual(enriched.timestamp, original.timestamp)
      XCTAssertEqual(RuleEngine.classify(enriched, selfID: "self", names: [], keywords: []), .none)
    }
    XCTAssertTrue(state.attentions.isEmpty)
    var drained = try XCTUnwrap(state.realtimeBuffer)
    XCTAssertEqual(drained.flush(account: "a", capacity: 10, interval: 3, now: start.addingTimeInterval(3)).count, 1)
    state.realtimeBuffer = drained
    state.ingestRealtime([incoming], admission: policy, selfID: "self", now: start.addingTimeInterval(4))
    XCTAssertTrue(state.realtimeBuffer!.entries.isEmpty, "补齐身份不能把已提交的消息重新入池")
  }
  func testRestoreAndWhitelistRemovalPurgeExcludedCachesAndBothTaskSources() throws {
    var state = AppSnapshot()
    let allowed = message("yes@chatroom"), excluded = message("no@chatroom"), privateMessage = message("private")
    let other = message("other@chatroom", account: "b")
    state.messages = [allowed, excluded, privateMessage, other]
    state.seen = Set(state.messages.map(\.key)); state.pendingJev = state.seen; state.pendingAI = state.seen
    state.realtimeBuffer = RealtimeBuffer(); state.summaryState = SummaryState()
    state.decisionBatches = []
    for item in state.messages {
      let scope = ConversationScope(account: item.accountID, group: item.groupID)
      state.realtimeBuffer?.receive(item)
      state.decisionBatches?.append(DecisionBatch(scope: scope, messages: [item]))
      state.summaryState?.jobs[scope.key] = SummaryJob(scope: scope, trigger: .periodic)
      state.checkpoints["\(item.accountID)|\(item.groupID)"] = Checkpoint(after: 1, cursor: "旧游标")
    }
    state.discardExcludedProcessing(admission: policy)
    let restored = try JSONDecoder().decode(AppSnapshot.self, from: JSONEncoder().encode(state))
    XCTAssertEqual(Set(restored.messages.map(\.key)), [allowed.key, other.key])
    XCTAssertEqual(restored.realtimeBuffer?.entries.count, 2)
    XCTAssertEqual(restored.decisionBatches?.count, 2)
    XCTAssertEqual(restored.summaryState?.jobs.count, 2)
    XCTAssertEqual(restored.checkpoints.count, 2)
    state.migrateAlphaREST()
    XCTAssertTrue(state.checkpoints.isEmpty)
    state.checkpoints["a|yes@chatroom"] = Checkpoint(after: 5)
    state.migrateAlphaREST()
    XCTAssertEqual(state.checkpoints.count, 1, "迁移仅执行一次，不清空新的 REST 进度")
  }
  func testRemovingWhitelistCancelsRunningAndQueuedPeriodicJobsWithoutSavingLateResult() async throws {
    let scope = ConversationScope(account: "a", group: "yes@chatroom")
    let another = ConversationScope(account: "a", group: "another@chatroom")
    var continuation: CheckedContinuation<AIResult, Never>?
    var savedResults = 0
    let coordinator = SummaryCoordinator(load: { requested in
      UnreadSnapshot(scope: requested, groupName: "群", messages: [self.message(requested.group)])
    }, summarize: { _ in
      await withCheckedContinuation { continuation = $0 }
    }, persist: { _, result in if result != nil { savedResults += 1 } })
    coordinator.enqueue(scope, trigger: .immediate)
    coordinator.enqueue(scope, trigger: .periodic)
    coordinator.enqueue(another, trigger: .periodic)
    coordinator.pump(account: "a", concurrency: 1)
    for _ in 0..<100 where continuation == nil { await Task.yield() }
    XCTAssertNotNil(continuation)
    coordinator.retainGroups(admission: MessageAdmission(account: "a", groups: []))
    XCTAssertTrue(coordinator.state.jobs.isEmpty)
    continuation?.resume(returning: AIResult(summary: "旧请求结果", relevant: false, relevanceReason: "无关", evidenceIDs: [], judgements: []))
    for _ in 0..<100 where !coordinator.active.isEmpty { await Task.yield() }
    XCTAssertEqual(savedResults, 0)
    XCTAssertTrue(coordinator.state.markers.isEmpty)
    XCTAssertTrue(coordinator.state.jobs.isEmpty)
  }
  func testBothTriggersAndRecoveredJobsCannotReadOrCallModelOutsideWhitelist() async {
    var recovered = SummaryState()
    let excluded = ConversationScope(account: "a", group: "no@chatroom")
    recovered.jobs[excluded.key] = SummaryJob(scope: excluded, trigger: .periodic)
    var reads = 0, models = 0, writes = 0, logs = 0
    let coordinator = SummaryCoordinator(state: recovered, load: { scope in
      reads += 1; return UnreadSnapshot(scope: scope, groupName: "群", messages: [])
    }, summarize: { _ in
      models += 1; return AIResult(summary: "结果", relevant: false, relevanceReason: "无关", evidenceIDs: [], judgements: [])
    }, persist: { _, _ in writes += 1 }, isAllowed: policy.allows, trace: { _, _, _ in logs += 1 })
    for group in ["private", "no@chatroom"] {
      let scope = ConversationScope(account: "a", group: group)
      coordinator.enqueue(scope, trigger: .immediate)
      coordinator.consider(scope, head: UnreadHead(count: 1, lastID: "1", timestamp: 1000))
    }
    coordinator.pump(account: "a", concurrency: 3)
    for _ in 0..<10 { await Task.yield() }
    XCTAssertEqual(reads, 0); XCTAssertEqual(models, 0); XCTAssertEqual(writes, 0); XCTAssertEqual(logs, 0)
    XCTAssertTrue(coordinator.active.isEmpty)
  }
}
