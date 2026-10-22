import XCTest
@testable import Qundao
import QundaoCore

final class AppStoreReviewTests: XCTestCase {
  @MainActor
  private func fixture(blockConfig: Bool = false) throws -> (AppStore, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("群岛状态审查-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let configDirectory = root.appendingPathComponent("config", isDirectory: true)
    if blockConfig { try Data("合成不可写父路径".utf8).write(to: configDirectory) }
    let store = AppStore(disk: DiskStore(directory: root.appendingPathComponent("state")),
      configFile: AppConfigFile(url: configDirectory.appendingPathComponent("config.toml")),
      log: EventLog(directory: root.appendingPathComponent("logs")))
    return (store, root)
  }

  private func message(_ id: String, account: String = "synthetic-account") -> Message {
    Message(id: id, accountID: account, groupID: "synthetic-group@chatroom", senderID: "synthetic-colleague",
      sender: "合成同事", text: "合成消息 \(id)", timestamp: 1_000)
  }

  @MainActor
  func testFailedCredentialSavePreservesRunningKeysAndPreferences() async throws {
    let (store, root) = try fixture(blockConfig: true)
    defer { store.stop(); store.saveNow(); store.log.flush(); try? FileManager.default.removeItem(at: root) }
    store.alphaToken = "synthetic-old-alpha"
    store.cpaKey = "synthetic-old-cpa"
    let original = store.preferences
    XCTAssertThrowsError(try store.saveCredentials(alpha: "synthetic-new-alpha", cpa: "synthetic-new-cpa"))
    XCTAssertEqual(store.alphaToken, "synthetic-old-alpha")
    XCTAssertEqual(store.cpaKey, "synthetic-old-cpa")
    XCTAssertEqual(store.preferences, original)
    XCTAssertFalse(store.configFile.exists)
  }

  @MainActor
  func testCredentialSaveCommitsWholeConfigBeforeApplyingKeys() async throws {
    let (store, root) = try fixture()
    defer { store.stop(); store.saveNow(); store.log.flush(); try? FileManager.default.removeItem(at: root) }
    store.snapshot.preferences.cpaSystemPrompt = "合成摘要规则"
    store.snapshot.preferences.jevSystemPrompt = "合成判断规则"
    store.jevKey = "synthetic-independent-jev"
    try store.saveCredentials(alpha: "synthetic-new-alpha", cpa: "synthetic-new-cpa")
    let saved = try AppConfig.parse(String(contentsOf: store.configFile.url, encoding: .utf8))
    XCTAssertEqual(saved.alphaToken, store.alphaToken)
    XCTAssertEqual(saved.cpaKey, store.cpaKey)
    XCTAssertEqual(saved.jevKey, "synthetic-independent-jev")
    XCTAssertEqual(saved.cpaSystemPrompt, "合成摘要规则")
    XCTAssertEqual(saved.jevSystemPrompt, "合成判断规则")
  }

  @MainActor
  func testFailedPromptSaveLeavesCurrentPromptsUnchanged() async throws {
    let (store, root) = try fixture(blockConfig: true)
    defer { store.stop(); store.saveNow(); store.log.flush(); try? FileManager.default.removeItem(at: root) }
    store.snapshot.preferences.cpaSystemPrompt = "原合成摘要"
    store.snapshot.preferences.jevSystemPrompt = "原合成判断"
    XCTAssertThrowsError(try store.saveModelPrompts(summary: "新合成摘要", jev: "新合成判断"))
    XCTAssertEqual(store.preferences.cpaSystemPrompt, "原合成摘要")
    XCTAssertEqual(store.preferences.jevSystemPrompt, "原合成判断")
  }

  @MainActor
  func testSavesDuringCredentialMigrationCannotOverwritePendingLoad() async throws {
    let (store, root) = try fixture()
    defer { store.stop(); store.saveNow(); store.log.flush(); try? FileManager.default.removeItem(at: root) }
    store.loadingCredentials = true
    XCTAssertThrowsError(try store.saveCredentials(alpha: "synthetic-new-alpha", cpa: "synthetic-new-cpa"))
    XCTAssertThrowsError(try store.saveModelPrompts(summary: "合成摘要", jev: "合成判断"))
    XCTAssertThrowsError(try store.saveDecisionConnection(.openRouter, key: "synthetic-jev"))
    XCTAssertTrue(store.alphaToken.isEmpty)
    XCTAssertTrue(store.cpaKey.isEmpty)
    XCTAssertTrue(store.jevKey.isEmpty)
    XCTAssertNil(store.preferences.cpaSystemPrompt)
    XCTAssertFalse(store.configFile.exists)
  }

  @MainActor
  func testCapturedFocusReadLeavesSnoozedAndLaterArrivalsUntouched() async throws {
    let (store, root) = try fixture()
    defer { store.stop(); store.saveNow(); store.log.flush(); try? FileManager.default.removeItem(at: root) }
    let first = message("first"), later = message("later"), snoozedMessage = message("snoozed")
    let digest = Digest(accountID: first.accountID, groupID: first.groupID, groupName: "合成群", text: "合成摘要",
      count: 3, evidence: [first, later, snoozedMessage], related: true, relevanceReason: "合成规则")
    let pending = Attention(message: first, groupName: "合成群", title: "合成待阅", reason: "合成规则", definite: true)
    var snoozed = Attention(message: snoozedMessage, groupName: "合成群", title: "合成稍后", reason: "合成规则", definite: true)
    snoozed.status = "snoozed"
    snoozed.remindAt = Date().addingTimeInterval(900)
    store.snapshot.preferences.accountID = first.accountID
    store.snapshot.digests = [digest]
    store.snapshot.attentions = [pending, snoozed]
    let selection = store.captureFocusSelection([.summary(digest)])
    store.snapshot.attentions.append(Attention(message: later, groupName: "合成群", title: "点击后到达", reason: "合成规则", definite: true))
    store.readFocusSelection(selection)
    XCTAssertNotNil(store.snapshot.digests[0].attentionReadAt)
    XCTAssertEqual(store.snapshot.attentions.map(\.status), ["done", "snoozed", "pending"])
    XCTAssertEqual(store.snapshot.attentions[1].remindAt, snoozed.remindAt)
    let restored = try store.disk.load()
    XCTAssertEqual(restored.attentions.map(\.status), ["done", "snoozed", "pending"])
  }

  @MainActor
  func testCapturedFocusReadIsRejectedAfterAccountSwitch() async throws {
    let (store, root) = try fixture()
    defer { store.stop(); store.saveNow(); store.log.flush(); try? FileManager.default.removeItem(at: root) }
    let first = message("first")
    let pending = Attention(message: first, groupName: "合成群", title: "合成待阅", reason: "合成规则", definite: true)
    store.snapshot.preferences.accountID = first.accountID
    store.snapshot.attentions = [pending]
    let selection = store.captureFocusSelection([.response(pending)])
    store.snapshot.preferences.accountID = "synthetic-other-account"
    store.readFocusSelection(selection)
    XCTAssertEqual(store.snapshot.attentions[0].status, "pending")
  }

  @MainActor
  func testJevPromptReloadKeepsBatchAndLateOldRequestCannotClearNewProgress() async throws {
    let (store, root) = try fixture()
    let gate = DecisionGate()
    let monitor = JevMonitor(store: store, evaluate: gate.evaluate)
    store.jevMonitor = monitor
    defer {
      store.running = false; monitor.stop(); gate.finishAll(); store.stop(); store.saveNow(); store.log.flush()
      try? FileManager.default.removeItem(at: root)
    }
    let first = message("first")
    store.snapshot.preferences.accountID = first.accountID
    store.snapshot.preferences.selectedGroups = [first.groupID]
    store.snapshot.preferences.decisionMethod = "jev"
    store.snapshot.preferences.autoExpand = false
    store.jevKey = "synthetic-jev"
    store.running = true
    monitor.receive([first], scope: ConversationScope(account: first.accountID, group: first.groupID))
    monitor.start()
    await waitUntil { gate.requests.count == 1 }
    let batchID = store.snapshot.decisionBatches?.first?.id
    try store.saveModelPrompts(summary: "合成摘要", jev: "新的合成判断")
    await waitUntil { gate.requests.count == 2 }
    XCTAssertEqual(gate.requests[1].prompt, "新的合成判断")
    XCTAssertEqual(store.snapshot.decisionBatches?.first?.id, batchID)
    gate.finish(0, related: true)
    // 模拟不合作的旧传输在取消后才返回；等待其收尾，不依赖真实服务。
    try await Task.sleep(nanoseconds: 20_000_000)
    XCTAssertEqual(store.jevJudging, first.groupID)
    XCTAssertEqual(store.snapshot.decisionBatches?.count, 1)
    XCTAssertTrue(store.snapshot.attentions.isEmpty)
    XCTAssertTrue(store.summaries.state.jobs.isEmpty)
    gate.finish(1, related: false)
    await waitUntil { store.snapshot.decisionBatches?.isEmpty == true }
    XCTAssertNil(store.jevJudging)
  }

  @MainActor
  func testJevRuleChangeRestartsPendingJudgementAndStopClearsProgress() async throws {
    let (store, root) = try fixture()
    let gate = DecisionGate()
    let monitor = JevMonitor(store: store, evaluate: gate.evaluate)
    store.jevMonitor = monitor
    defer {
      store.running = false; monitor.stop(); gate.finishAll(); store.stop(); store.saveNow(); store.log.flush()
      try? FileManager.default.removeItem(at: root)
    }
    let first = message("first")
    store.snapshot.preferences.accountID = first.accountID
    store.snapshot.preferences.selectedGroups = [first.groupID]
    store.snapshot.preferences.decisionMethod = "jev"
    store.jevKey = "synthetic-jev"
    store.running = true
    monitor.receive([first], scope: ConversationScope(account: first.accountID, group: first.groupID))
    monitor.start()
    await waitUntil { gate.requests.count == 1 }
    store.update { $0.keywords = ["新的合成关键词"] }
    await waitUntil { gate.requests.count == 2 }
    XCTAssertEqual(gate.requests[1].keywords, ["新的合成关键词"])
    monitor.stop()
    XCTAssertNil(store.jevJudging)
    XCTAssertEqual(store.snapshot.decisionBatches?.count, 1)
  }

  @MainActor
  func testJevLateSelfIdentityCannotCreateSummaryOrResponse() async throws {
    let (store, root) = try fixture()
    let gate = DecisionGate()
    let monitor = JevMonitor(store: store, evaluate: gate.evaluate)
    store.jevMonitor = monitor
    defer {
      monitor.stop(); gate.finishAll(); store.stop(); store.saveNow(); store.log.flush()
      try? FileManager.default.removeItem(at: root)
    }
    var first = message("first")
    first.senderID = ""
    store.accounts = [Account(id: first.accountID, name: "合成账号", subjectID: "synthetic-self")]
    store.snapshot.preferences.accountID = first.accountID
    store.snapshot.preferences.selectedGroups = [first.groupID]
    store.snapshot.preferences.decisionMethod = "jev"
    store.jevKey = "synthetic-jev"
    let admission = store.messageAdmission
    store.snapshot.ingestRealtime([first], admission: admission, selfID: "synthetic-self")
    monitor.receive([first], scope: ConversationScope(account: first.accountID, group: first.groupID))
    monitor.start()
    await waitUntil { gate.requests.count == 1 }
    first.senderID = "synthetic-self"
    store.snapshot.ingestRealtime([first], admission: admission, selfID: "synthetic-self")
    gate.finish(0, related: true)
    await waitUntil { store.snapshot.decisionBatches?.isEmpty == true }
    XCTAssertTrue(store.snapshot.attentions.isEmpty)
    XCTAssertTrue(store.summaries.state.jobs.isEmpty)
  }

  @MainActor
  func testJevFailureFallbackUsesLatestSelfIdentity() async throws {
    let (store, root) = try fixture()
    let gate = DecisionGate()
    let monitor = JevMonitor(store: store, evaluate: gate.evaluate)
    store.jevMonitor = monitor
    defer {
      monitor.stop(); gate.finishAll(); store.stop(); store.saveNow(); store.log.flush()
      try? FileManager.default.removeItem(at: root)
    }
    var first = message("first")
    first.senderID = ""
    store.accounts = [Account(id: first.accountID, name: "合成账号", subjectID: "synthetic-self")]
    store.snapshot.preferences.accountID = first.accountID
    store.snapshot.preferences.selectedGroups = [first.groupID]
    store.snapshot.preferences.decisionMethod = "jev"
    store.snapshot.preferences.keywords = ["合成消息"]
    store.jevKey = "synthetic-jev"
    let admission = store.messageAdmission
    store.snapshot.ingestRealtime([first], admission: admission, selfID: "synthetic-self")
    monitor.receive([first], scope: ConversationScope(account: first.accountID, group: first.groupID))
    monitor.start()
    await waitUntil { gate.requests.count == 1 }
    first.senderID = "synthetic-self"
    store.snapshot.ingestRealtime([first], admission: admission, selfID: "synthetic-self")
    gate.fail(0)
    await waitUntil { store.snapshot.decisionBatches?.first?.attempts == 1 }
    XCTAssertFalse(store.snapshot.decisionBatches?.first?.fallbackTriggered ?? true)
    XCTAssertTrue(store.snapshot.attentions.isEmpty)
    XCTAssertTrue(store.summaries.state.jobs.isEmpty)
  }

  @MainActor
  private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    for _ in 0..<200 {
      if condition() { return }
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("合成异步操作未按预期完成", file: file, line: line)
  }
}

@MainActor
private final class DecisionGate {
  struct Request {
    let messages: [Message]
    let prompt: String?
    let keywords: [String]
    var continuation: CheckedContinuation<[JevDecision], Error>?
  }
  var requests: [Request] = []

  func evaluate(client: JevClient, messages: [Message], context: [Message], preferences: Preferences,
                selfID: String) async throws -> [JevDecision] {
    try await withCheckedThrowingContinuation { continuation in
      requests.append(Request(messages: messages, prompt: client.systemPrompt, keywords: preferences.keywords, continuation: continuation))
    }
  }
  func finish(_ index: Int, related: Bool) {
    guard requests.indices.contains(index), let continuation = requests[index].continuation else { return }
    requests[index].continuation = nil
    let value = related ? 0.99 : 0.01
    let data = try! JSONSerialization.data(withJSONObject: ["answers": [
      "related_0": ["type": "noul", "noul": value], "response_0": ["type": "noul", "noul": value]
    ]])
    continuation.resume(returning: try! JevClient.parse(data, messages: requests[index].messages))
  }
  func finishAll() {
    for index in requests.indices {
      requests[index].continuation?.resume(throwing: CancellationError())
      requests[index].continuation = nil
    }
  }
  func fail(_ index: Int) {
    guard requests.indices.contains(index), let continuation = requests[index].continuation else { return }
    requests[index].continuation = nil
    continuation.resume(throwing: AppFailure.message("合成模型服务失败"))
  }
}
