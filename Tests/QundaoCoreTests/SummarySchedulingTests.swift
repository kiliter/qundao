import XCTest
@testable import QundaoCore

private func msg(_ n: Int, group: String = "g", account: String = "a", text: String? = nil) -> Message {
  Message(id: "M\(n)", accountID: account, groupID: group, senderID: "other", sender: "同事",
          text: text ?? "消息 \(n)", timestamp: Int64(n))
}
private func validResult(_ text: String = "完整摘要") -> AIResult {
  AIResult(summary: text, relevant: false, relevanceReason: "无关", evidenceIDs: [], judgements: [])
}
@MainActor private final class Gate {
  var continuations: [CheckedContinuation<Void, Never>] = []
  func wait() async { await withCheckedContinuation { continuations.append($0) } }
  func open() { let values = continuations; continuations = []; values.forEach { $0.resume() } }
}
@MainActor final class SummarySchedulingTests: XCTestCase {
  private let scope = ConversationScope(account: "a", group: "g")
  private let t = Date(timeIntervalSince1970: 1000)
  private func settle(_ predicate: () -> Bool) async {
    for _ in 0..<1000 {
      if predicate() { return }
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("等待异步任务完成超时")
  }
  func testCapacityDeadlineDedupAndAccountIsolation() throws {
    var buffer = RealtimeBuffer()
    buffer.receive(msg(1), now: t)
    buffer.receive(msg(1), now: t.addingTimeInterval(2))
    buffer.receive(msg(1, account: "b"), now: t)
    XCTAssertTrue(buffer.flush(account: "a", capacity: 2, interval: 5, now: t.addingTimeInterval(2)).isEmpty)
    buffer.receive(msg(2), now: t.addingTimeInterval(3))
    let capacity = buffer.flush(account: "a", capacity: 2, interval: 5, now: t.addingTimeInterval(3))
    XCTAssertEqual(capacity.first?.reason, "容量阈值")
    XCTAssertEqual(capacity.first?.messages.count, 2)
    buffer.receive(msg(3), now: t)
    buffer.receive(msg(4), now: t.addingTimeInterval(4.9))
    let restored = try JSONDecoder().decode(RealtimeBuffer.self, from: JSONEncoder().encode(buffer))
    buffer = restored
    let time = buffer.flush(account: "a", capacity: 100, interval: 5, now: t.addingTimeInterval(5))
    XCTAssertEqual(time.first?.reason, "首条消息等待到期")
    XCTAssertEqual(time.first?.messages.count, 2)
    XCTAssertEqual(buffer.entries.count, 1)
    XCTAssertEqual(buffer.entries.values.first?.message.accountID, "b")
  }
  func testUnrelatedFlushNeverSubmitsAndMultipleHitsSubmitOnce() async {
    var modelCalls = 0, prefs = Preferences()
    prefs.names = ["张三"]; prefs.keywords = ["发布"]
    let coordinator = SummaryCoordinator(load: { scope in UnreadSnapshot(scope: scope, groupName: "群", messages: [msg(1)]) },
      summarize: { _ in modelCalls += 1; return validResult() }, persist: { _, _ in })
    let unrelated = RealtimeDecision.local([msg(1, text: "今晚吃火锅")], preferences: prefs, selfID: "me")
    if unrelated.contains(where: \.related) { coordinator.enqueue(scope, trigger: .immediate) }
    coordinator.pump(account: "a", concurrency: 3)
    XCTAssertTrue(coordinator.state.jobs.isEmpty); XCTAssertEqual(modelCalls, 0)
    let related = RealtimeDecision.local([msg(2, text: "@所有人 请确认"), msg(3, text: "@all 发布通知")], preferences: prefs, selfID: "me")
    if related.contains(where: \.related) { coordinator.enqueue(scope, trigger: .immediate) }
    coordinator.pump(account: "a", concurrency: 3)
    await settle { coordinator.active.isEmpty }
    XCTAssertEqual(modelCalls, 1)
  }
  func testM100ThenM101IncludesAllOldUnreadAndPeriodicSkipsSameTail() async throws {
    var unread = (1...100).map { msg($0) }, calls: [[String]] = [], persisted = SummaryState()
    let coordinator = SummaryCoordinator(load: { scope in UnreadSnapshot(scope: scope, groupName: "群", messages: unread) },
      summarize: { snapshot in calls.append(snapshot.messages.map(\.id)); return validResult() },
      persist: { state, _ in persisted = state })
    coordinator.enqueue(scope, trigger: .immediate)
    coordinator.enqueue(scope, trigger: .periodic)
    coordinator.pump(account: "a", concurrency: 3)
    await settle { coordinator.active.isEmpty }
    XCTAssertEqual(calls.count, 1); XCTAssertEqual(calls[0].count, 100)
    coordinator.consider(scope, head: UnreadHead(count: 100, lastID: "M100", timestamp: 100))
    coordinator.pump(account: "a", concurrency: 3)
    XCTAssertEqual(calls.count, 1); XCTAssertTrue(coordinator.state.jobs.isEmpty)
    unread.append(msg(101))
    coordinator.consider(scope, head: UnreadHead(count: 101, lastID: "M101", timestamp: 101))
    coordinator.pump(account: "a", concurrency: 3)
    await settle { coordinator.active.isEmpty }
    XCTAssertEqual(calls.count, 2); XCTAssertEqual(calls[1].count, 101)
    XCTAssertEqual(calls[1].first, "M1"); XCTAssertEqual(persisted.markers[scope.key]?.lastMessageID, "M101")
  }
  func testSameGroupSerialCrossGroupBoundedAndImmediatePriority() async {
    let gate = Gate()
    var started: [String] = []
    let coordinator = SummaryCoordinator(load: { scope in UnreadSnapshot(scope: scope, groupName: "群", messages: [msg(1, group: scope.group)]) },
      summarize: { snapshot in started.append(snapshot.scope.group); await gate.wait(); return validResult() }, persist: { _, _ in })
    coordinator.enqueue(ConversationScope(account: "a", group: "p1"), trigger: .periodic, now: t)
    coordinator.enqueue(ConversationScope(account: "a", group: "p2"), trigger: .periodic, now: t.addingTimeInterval(1))
    coordinator.enqueue(scope, trigger: .immediate, now: t.addingTimeInterval(2))
    coordinator.pump(account: "a", concurrency: 2)
    await settle { started.count == 2 }
    XCTAssertEqual(started, ["g", "p1"])
    for _ in 0..<10 { coordinator.enqueue(scope, trigger: .periodic) }
    coordinator.pump(account: "a", concurrency: 2)
    XCTAssertEqual(started.count, 2); XCTAssertEqual(coordinator.active.count, 2)
    gate.open(); await settle { coordinator.active.isEmpty }
    coordinator.pump(account: "a", concurrency: 2)
    await settle { started.count == 3 }
    XCTAssertEqual(started.last, "p2")
    XCTAssertEqual(started.filter { $0 == "g" }.count, 1)
    gate.open(); await settle { coordinator.active.isEmpty }
  }
  func testNewUnrelatedMessagesDuringExecutionDoNotTriggerOrAdvanceMarker() async {
    let gate = Gate(); var unread = [msg(1)], calls = 0
    let coordinator = SummaryCoordinator(load: { scope in UnreadSnapshot(scope: scope, groupName: "群", messages: unread) },
      summarize: { _ in calls += 1; await gate.wait(); return validResult() }, persist: { _, _ in })
    coordinator.enqueue(scope, trigger: .immediate); coordinator.pump(account: "a", concurrency: 2)
    await settle { calls == 1 }
    unread.append(msg(2)) // 没有相关判断命中，也没有周期扫描。
    gate.open(); await settle { coordinator.active.isEmpty }
    XCTAssertEqual(coordinator.state.markers[scope.key]?.lastMessageID, "M1")
    coordinator.pump(account: "a", concurrency: 2)
    XCTAssertEqual(calls, 1); XCTAssertTrue(coordinator.state.jobs.isEmpty)
  }
  func testTriggersDuringExecutionCoalesceAndFetchLatestSnapshot() async {
    let gate = Gate(); var unread = [msg(1)], inputs: [[String]] = []
    let coordinator = SummaryCoordinator(load: { scope in UnreadSnapshot(scope: scope, groupName: "群", messages: unread) },
      summarize: { snapshot in inputs.append(snapshot.messages.map(\.id)); await gate.wait(); return validResult() }, persist: { _, _ in })
    coordinator.enqueue(scope, trigger: .periodic); coordinator.pump(account: "a", concurrency: 2)
    await settle { inputs.count == 1 }
    unread.append(msg(2))
    for _ in 0..<5 { coordinator.enqueue(scope, trigger: .immediate) }
    gate.open(); await settle { coordinator.active.isEmpty }
    XCTAssertEqual(coordinator.state.markers[scope.key]?.lastMessageID, "M1")
    XCTAssertEqual(coordinator.state.jobs.count, 1)
    coordinator.pump(account: "a", concurrency: 2)
    await settle { inputs.count == 2 }
    XCTAssertEqual(inputs[1], ["M1", "M2"])
    gate.open(); await settle { coordinator.active.isEmpty }
    XCTAssertEqual(coordinator.state.markers[scope.key]?.lastMessageID, "M2")
  }
  func testFailureBackoffPreservesNewTriggerAndRestartsWithoutAccountLeak() async throws {
    let gate = Gate(); var saved = SummaryState(), calls = 0
    let coordinator = SummaryCoordinator(load: { scope in UnreadSnapshot(scope: scope, groupName: "群", messages: [msg(1)]) },
      summarize: { _ in calls += 1; await gate.wait(); throw AppFailure.message("测试失败") }, persist: { state, _ in saved = state })
    coordinator.enqueue(scope, trigger: .periodic); coordinator.pump(account: "a", concurrency: 2)
    await settle { calls == 1 }
    coordinator.enqueue(scope, trigger: .immediate)
    gate.open(); await settle { coordinator.active.isEmpty }
    XCTAssertNil(coordinator.state.markers[scope.key])
    XCTAssertEqual(coordinator.state.jobs[scope.key]?.sources, [.immediate, .periodic])
    coordinator.pump(account: "a", concurrency: 2); XCTAssertEqual(calls, 1)
    let restored = try JSONDecoder().decode(SummaryState.self, from: JSONEncoder().encode(saved))
    let recovery = SummaryCoordinator(state: restored,
      load: { scope in UnreadSnapshot(scope: scope, groupName: "群", messages: [msg(1, account: scope.account)]) },
      summarize: { _ in calls += 1; return validResult() }, persist: { _, _ in })
    recovery.pump(account: "b", concurrency: 3, now: .distantFuture)
    XCTAssertEqual(calls, 1)
    recovery.pump(account: "a", concurrency: 3, now: .distantFuture)
    await settle { recovery.active.isEmpty }
    XCTAssertEqual(calls, 2); XCTAssertEqual(recovery.state.markers[scope.key]?.lastMessageID, "M1")
    let b = ConversationScope(account: "b", group: "g")
    recovery.consider(b, head: UnreadHead(count: 1, lastID: "M1", timestamp: 1))
    recovery.pump(account: "b", concurrency: 3)
    await settle { recovery.active.isEmpty }
    XCTAssertEqual(calls, 3); XCTAssertEqual(recovery.state.markers.count, 2)
  }
  func testPersistenceFailureInvalidOutputAndCancellationDoNotAdvanceMarker() async {
    for mode in ["保存失败", "无效输出", "取消"] {
      let gate = Gate(); var called = false
      let coordinator = SummaryCoordinator(load: { scope in UnreadSnapshot(scope: scope, groupName: "群", messages: [msg(1)]) },
        summarize: { _ in called = true; if mode == "取消" { await gate.wait() }; return validResult(mode == "无效输出" ? "   " : "摘要") },
        persist: { _, completion in if completion != nil && mode == "保存失败" { throw AppFailure.message(mode) } })
      coordinator.enqueue(scope, trigger: .immediate); coordinator.pump(account: "a", concurrency: 1)
      await settle { called }
      if mode == "取消" { coordinator.stop(); gate.open() }
      await settle { coordinator.active.isEmpty }
      XCTAssertNil(coordinator.state.markers[scope.key], mode)
      XCTAssertNotNil(coordinator.state.jobs[scope.key], mode)
    }
  }
  func testRecoveredInFlightAndMigrationNeverTreatSyncedMessagesAsSuccessful() throws {
    var snapshot = AppSnapshot()
    snapshot.messages = [msg(1)]; snapshot.seen = [msg(1).key]; snapshot.analyzed = [msg(1).key]
    snapshot.pendingAI = [msg(1).key]
    snapshot.migrateSummaryWorkflow()
    XCTAssertTrue(snapshot.summaryState!.markers.isEmpty)
    XCTAssertEqual(snapshot.summaryState!.jobs.count, 1)
    snapshot.summaryState?.jobs[scope.key]?.running = true
    let restored = try JSONDecoder().decode(AppSnapshot.self, from: JSONEncoder().encode(snapshot))
    let coordinator = SummaryCoordinator(state: restored.summaryState!, load: { _ in throw CancellationError() },
      summarize: { _ in validResult() }, persist: { _, _ in })
    XCTAssertEqual(coordinator.state.jobs[scope.key]?.running, false)
  }
  func testPeriodicClockDoesNotRunOnStartOrMessageArrival() {
    var clock = PeriodicSummaryClock(now: t)
    XCTAssertFalse(clock.tick(now: t, intervalMinutes: 5))
    XCTAssertFalse(clock.tick(now: t.addingTimeInterval(299), intervalMinutes: 5))
    XCTAssertTrue(clock.tick(now: t.addingTimeInterval(300), intervalMinutes: 5))
  }
}
