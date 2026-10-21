import Foundation
import QundaoCore

/// 缓冲 flush 后判断一批，整批全部判断结束后只提交一次群任务。失败批次落盘并退避。
@MainActor final class JevMonitor {
  private weak var store: AppStore?
  private var task: Task<Void, Never>?
  private var generation = UUID()
  init(store: AppStore) { self.store = store }
  func receive(_ messages: [Message], scope: ConversationScope) {
    guard let store, store.messageAdmission.allows(scope) else { return }
    let messages = messages.filter { store.messageAdmission.allows($0) && $0.groupID == scope.group }
    guard !messages.isEmpty else { return }
    if store.snapshot.decisionBatches == nil { store.snapshot.decisionBatches = [] }
    store.snapshot.decisionBatches?.append(DecisionBatch(scope: scope, messages: messages))
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
          store.decisionStatus = store.preferences.usesJev ? "Jev 未配置，使用本地识别" : "本地识别"
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
      }
    }
  }
  func stop() { generation = UUID(); task?.cancel(); task = nil }
  @discardableResult private func fallback(_ batch: DecisionBatch) -> Bool {
    guard let store, store.messageAdmission.allows(batch.scope), batch.messages.allSatisfy(store.messageAdmission.allows) else { return false }
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
  private func decide(_ batch: DecisionBatch, current: UUID) async {
    guard let store, store.messageAdmission.allows(batch.scope), batch.messages.allSatisfy(store.messageAdmission.allows) else { return }
    let prefs = store.preferences
    let selfID = store.activeAccount?.subjectID ?? ""
    let name = store.snapshot.groups.first(where: { $0.id == batch.scope.group })?.name ?? batch.scope.group
    do {
      store.decisionStatus = "Jev 正在判断"
      let client = JevClient(key: store.jevKey, configuration: prefs.jevConfiguration, trace: { [weak store] in
        guard let store, store.messageAdmission.allows(batch.scope) else { return }
        store.log.record($0)
      })
      // 用与摘要相同的完整分片策略承载长消息；Jev 每次仍遵守最多 20 条。
      var fragments: [Message] = []
      func split(_ message: Message) throws {
        if message.text.utf8.count <= 20_000 { fragments.append(message); return }
        guard message.text.count > 1 else { throw AppFailure.message("Jev 消息无法在预算内分片") }
        let middle = message.text.index(message.text.startIndex, offsetBy: message.text.count / 2)
        var a = message, b = message
        a.text = String(message.text[..<middle]); b.text = String(message.text[middle...])
        try split(a); try split(b)
      }
      for message in batch.messages { try split(message) }
      var chunks: [[Message]] = [], chunk: [Message] = [], bytes = 0
      for message in fragments {
        if !chunk.isEmpty && (chunk.count >= 20 || bytes + message.text.utf8.count > 40_000) {
          chunks.append(chunk); chunk = []; bytes = 0
        }
        chunk.append(message); bytes += message.text.utf8.count
      }
      if !chunk.isEmpty { chunks.append(chunk) }
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
      var results: [JevDecision] = []
      for chunk in chunks {
        try Task.checkCancellation()
        guard generation == current, store.messageAdmission.allows(batch.scope) else { throw CancellationError() }
        let part = try await client.decide(messages: chunk, context: context.reversed(), names: prefs.names,
                                           keywords: prefs.keywords, selfID: selfID)
        results += part
      }
      try Task.checkCancellation()
      guard generation == current, store.preferences.accountID == batch.scope.account,
            store.preferences.jevConfiguration == prefs.jevConfiguration,
            store.preferences.decisionThreshold == prefs.decisionThreshold,
            store.preferences.selectedGroups.contains(batch.scope.group),
            store.snapshot.decisionBatches?.contains(where: { $0.id == batch.id }) == true else { return }
      let related = results.contains { $0.isRelated(threshold: prefs.decisionThreshold) }
      store.log.record(DiagnosticRecord(category: .jev, event: "整批决策路由", correlationID: batch.id.uuidString, scope: batch.scope.key,
        output: DiagnosticRecord.safeText(try? JSONSerialization.data(withJSONObject: [
          "消息数": batch.messages.count, "分段数": chunks.count, "相关": related,
          "提交群任务": related && !batch.fallbackTriggered,
          "结果": results.map { ["消息键": $0.messageKey, "相关概率": $0.relevance, "回应概率": $0.needsResponse] as [String: Any] }
        ]))))
      if related, !batch.fallbackTriggered { store.enqueue(batch.scope.group) }
      for result in results where result.needsResponse >= prefs.decisionThreshold {
        if let message = batch.messages.first(where: { $0.key == result.messageKey }),
           message.senderID.isEmpty || message.senderID != selfID {
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
