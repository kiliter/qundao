import Foundation
import QundaoCore

/// 缓冲 flush 后判断一批，整批全部判断结束后只提交一次群任务。失败批次落盘并退避。
@MainActor final class JevMonitor {
  private weak var store: AppStore?
  private var task: Task<Void, Never>?
  private var generation = UUID()
  typealias Evaluate = (JevClient, [Message], [Message], Preferences, String) async throws -> [JevDecision]
  private let evaluate: Evaluate
  init(store: AppStore, evaluate: @escaping Evaluate = { client, messages, context, preferences, selfID in
    try await client.decide(messages: messages, context: context, names: preferences.names,
                            keywords: preferences.keywords, selfID: selfID)
  }) {
    self.store = store
    self.evaluate = evaluate
  }
  func receive(_ messages: [Message], scope: ConversationScope, summaryTriggered: Bool = false) {
    guard let store, store.messageAdmission.allows(scope) else { return }
    let messages = messages.filter { store.messageAdmission.allows($0) && $0.groupID == scope.group }
    guard !messages.isEmpty else { return }
    if store.snapshot.decisionBatches == nil { store.snapshot.decisionBatches = [] }
    var batch = DecisionBatch(scope: scope, messages: messages)
    // 复用既有字段：表示本群摘要已由其他途径提交，Jev 结果不再重复触发群任务。
    batch.fallbackTriggered = summaryTriggered
    store.snapshot.decisionBatches?.append(batch)
  }
  func start() {
    stop()
    if let store {
      store.decisionStatus = store.preferences.usesJev
        ? (store.jevKey.isEmpty ? "Jev 未配置，使用本地识别" : "Jev 等待消息") : "本地识别"
    }
    let current = generation
    task = Task { [weak self] in
      guard let self, let store = self.store else { return }
      while !Task.isCancelled, generation == current {
        if let batch = store.snapshot.decisionBatches?.first(where: {
          store.messageAdmission.allows($0.scope) && $0.retryAt <= Date()
        }) {
          if store.preferences.usesJev, !store.jevKey.isEmpty { await decide(batch, current: current) }
          else {
            fallback(batch)
            store.snapshot.decisionBatches?.removeAll { $0.id == batch.id }
            store.save()
          }
        }
        if !store.preferences.usesJev || store.jevKey.isEmpty {
          // 每 200ms 一轮；值相同不写，避免反复通知界面。
          let status = store.preferences.usesJev ? "Jev 未配置，使用本地识别" : "本地识别"
          if store.decisionStatus != status { store.decisionStatus = status }
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
      }
    }
  }
  func stop() {
    generation = UUID(); task?.cancel(); task = nil
    store?.jevJudging = nil
    store?.refreshActivity()
  }
  @discardableResult private func fallback(_ batch: DecisionBatch) -> Bool {
    guard let store else { return false }
    let batch = refreshed(batch, store: store)
    guard store.messageAdmission.allows(batch.scope), batch.messages.allSatisfy(store.messageAdmission.allows) else { return false }
    let prefs = store.preferences
    let decisions = RealtimeDecision.local(batch.messages, preferences: prefs, selfID: store.activeAccount?.subjectID ?? "",
      semantic: { store.semantic.matches($0, keywords: prefs.keywords) })
    let related = decisions.contains(where: \.related)
    for decision in decisions {
      store.log.localDecision(decision.message, preferences: prefs, selfID: store.activeAccount?.subjectID ?? "",
        match: decision.match, semantic: decision.semantic,
        action: decision.related ? "Jev 回退本地命中" : "Jev 回退本地未命中", elapsed: 0)
    }
    if related, !batch.fallbackTriggered { store.enqueue(batch.scope.group) }
    return related
  }
  /// REST 补查可能在模型等待期间补齐推送缺失的发送人身份，不能继续使用旧批次判为他人发言。
  private func refreshed(_ batch: DecisionBatch, store: AppStore) -> DecisionBatch {
    var latest = store.snapshot.decisionBatches?.first(where: { $0.id == batch.id }) ?? batch
    let keys = Set(latest.messages.map(\.key))
    let messages = Dictionary(store.snapshot.messages.filter { keys.contains($0.key) }.map { ($0.key, $0) },
                              uniquingKeysWith: { _, last in last })
    latest.messages = latest.messages.map { messages[$0.key] ?? $0 }
    return latest
  }
  private func decide(_ batch: DecisionBatch, current: UUID) async {
    guard let store, store.messageAdmission.allows(batch.scope), batch.messages.allSatisfy(store.messageAdmission.allows) else { return }
    let prefs = store.preferences
    let selfID = store.activeAccount?.subjectID ?? ""
    let name = store.snapshot.groups.first(where: { $0.id == batch.scope.group })?.name ?? batch.scope.group
    store.jevJudging = batch.scope.group
    store.refreshActivity()
    defer {
      // 旧请求可能在新一代判断启动后才返回，不能清掉新请求的进度。
      if generation == current { store.jevJudging = nil; store.refreshActivity() }
    }
    do {
      store.decisionStatus = "Jev 正在判断"
      let client = JevClient(key: store.jevKey, configuration: prefs.jevConfiguration,
        systemPrompt: prefs.jevSystemPrompt, trace: { [weak self, weak store] in
        guard let self, generation == current, let store, store.messageAdmission.allows(batch.scope) else { return }
        store.log.record($0)
      })
      let keys = Set(batch.messages.map(\.key))
      var context: [Message] = [], contextBytes = 0
      for message in store.snapshot.messages.filter({
        $0.accountID == batch.scope.account && $0.groupID == batch.scope.group && !keys.contains($0.key)
          && $0.timestamp >= (batch.messages.first?.timestamp ?? 0) - 300_000
      }).sorted(by: { $0.timestamp > $1.timestamp }).prefix(12) {
        if contextBytes + message.text.utf8.count < 15_000 {
          context.append(message); contextBytes += message.text.utf8.count
        }
      }
      // 提示词也计入实际请求预算；长消息完整分片，编号在每个请求内重新绑定。
      let chunks = try client.prepareBatches(messages: batch.messages, context: context.reversed(),
        names: prefs.names, keywords: prefs.keywords, selfID: selfID)
      var results: [JevDecision] = []
      for chunk in chunks {
        try Task.checkCancellation()
        guard generation == current, store.messageAdmission.allows(batch.scope) else { throw CancellationError() }
        let part = try await evaluate(client, chunk, context.reversed(), prefs, selfID)
        results += part
      }
      try Task.checkCancellation()
      guard generation == current, store.preferences.accountID == batch.scope.account,
            store.preferences.jevConfiguration == prefs.jevConfiguration,
            store.preferences.jevSystemPrompt == prefs.jevSystemPrompt,
            store.preferences.names == prefs.names, store.preferences.keywords == prefs.keywords,
            store.preferences.decisionThreshold == prefs.decisionThreshold,
            store.preferences.selectedGroups.contains(batch.scope.group),
            store.snapshot.decisionBatches?.contains(where: { $0.id == batch.id }) == true else { return }
      let latest = refreshed(batch, store: store)
      let currentSelfID = store.activeAccount?.subjectID ?? selfID
      let ownKeys = Set(latest.messages.filter { !$0.senderID.isEmpty && $0.senderID == currentSelfID }.map(\.key))
      let eligible = results.filter { !ownKeys.contains($0.messageKey) }
      let related = eligible.contains { $0.isRelated(threshold: prefs.decisionThreshold) }
      store.log.record(DiagnosticRecord(category: .jev, event: "整批决策路由", correlationID: batch.id.uuidString, scope: batch.scope.key,
        output: DiagnosticRecord.safeText(try? JSONSerialization.data(withJSONObject: [
          "消息数": batch.messages.count, "分段数": chunks.count, "相关": related,
          "提交群任务": related && !batch.fallbackTriggered,
          "结果": results.map { ["消息键": $0.messageKey, "相关概率": $0.relevance, "回应概率": $0.needsResponse] as [String: Any] }
        ]))))
      if related, !batch.fallbackTriggered { store.enqueue(batch.scope.group) }
      for result in eligible where result.needsResponse >= prefs.decisionThreshold {
        if let message = latest.messages.first(where: { $0.key == result.messageKey }) {
          store.addAttention(Attention(message: message, groupName: name, title: "\(message.sender) 可能需要你回应",
            reason: "Jev 判断需回应的概率为 \(Int(result.needsResponse * 100))%；请结合原文确认", definite: false))
        }
      }
      store.snapshot.decisionBatches?.removeAll { $0.id == batch.id }
      store.decisionStatus = "Jev 已连接"; store.save()
    } catch {
      guard !Task.isCancelled, generation == current,
            store.preferences.accountID == batch.scope.account,
            let index = store.snapshot.decisionBatches?.firstIndex(where: { $0.id == batch.id }) else { return }
      let related = fallback(batch)
      store.snapshot.decisionBatches?[index].fallbackTriggered = batch.fallbackTriggered || related
      let attempts = batch.attempts + 1
      store.snapshot.decisionBatches?[index].attempts = attempts
      store.snapshot.decisionBatches?[index].retryAt = Date().addingTimeInterval(min(300, pow(2, Double(min(attempts, 6))) * 5))
      store.decisionStatus = "Jev 暂不可用，本地识别继续"; store.error = error.localizedDescription
      store.save()
      store.log.write("警告", "Jev 整批保留重试", "群 \(EventLog.ref(batch.scope.group))；第 \(attempts) 次；\(error.localizedDescription)")
    }
  }
}
