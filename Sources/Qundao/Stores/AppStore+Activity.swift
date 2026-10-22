import Foundation
import QundaoCore

/// 刘海展示的处理阶段。只描述当前账号白名单内的工作，不包含任何聊天正文。
enum IslandPhase: Equatable {
  case paused, idle, buffering, waiting, retrying, judging, loading, summarizing, attention
  /// 收起态是否加宽以显示阶段标签。
  var isActive: Bool { self != .idle && self != .paused }
}

/// 单群摘要进度：读取 Alpha 全部未读 → 第 n 次 CPA 请求（分段时多次）。
struct SummaryProgress: Equatable {
  var group: String
  var groupName: String
  var loading = true
  var messages = 0
  var requests = 0
  var stage = ""
}

struct IslandActivity: Equatable {
  var phase: IslandPhase = .paused
  var buffer: BufferStatus = .empty
  /// 等待或正在 Jev 判断的批次（含退避中的批次）。
  var judgeBatches = 0
  var judging = false
  var judgingGroupName: String?
  var summaries: [SummaryProgress] = []
  var concurrency = 3
  var immediateWaiting = 0
  var periodicWaiting = 0
  var retryAt: Date?
  var pipelineVisible: Bool { phase.isActive && phase != .attention }
}

extension AppStore {
  func groupName(_ id: String) -> String { snapshot.groups.first(where: { $0.id == id })?.name ?? "群聊" }

  /// 由工作循环（200ms）与调度变化调用；值未变化时不写，避免刷新视图。
  func refreshActivity(now: Date = Date()) {
    let account = preferences.accountID
    let buffer = running ? (snapshot.realtimeBuffer ?? RealtimeBuffer())
      .status(account: account, capacity: preferences.bufferCapacity, interval: preferences.bufferInterval) : .empty
    let batches = running ? (snapshot.decisionBatches ?? []).filter { $0.scope.account == account && messageAdmission.allows($0.scope) } : []
    let jobs = summaries.state.jobs.values.filter { $0.scope.account == account && messageAdmission.allows($0.scope) }
    let activeKeys = Set(summaries.active.keys)
    // 已结束的任务清除进度，避免残留“正在更新”。
    for key in summaryProgress.keys where !activeKeys.contains(key) { summaryProgress[key] = nil }
    let waiting = jobs.filter { !$0.running && activeKeys.contains($0.id) == false }
    let retries = (waiting.map(\.retryAt) + batches.map(\.retryAt)).filter { $0 > now.addingTimeInterval(0.5) }

    var next = IslandActivity()
    next.buffer = buffer
    next.judgeBatches = batches.count
    next.judging = jevJudging != nil
    next.judgingGroupName = jevJudging.map(groupName)
    next.summaries = activeKeys.sorted().compactMap { summaryProgress[$0] }
    next.concurrency = preferences.concurrentSummaries
    next.immediateWaiting = waiting.filter { $0.sources.contains(.immediate) }.count
    next.periodicWaiting = waiting.count - next.immediateWaiting
    next.retryAt = retries.min()
    let ready = batches.contains { $0.retryAt <= now }
    if !running { next.phase = .paused }
    else if let flash = attentionFlashAt, now.timeIntervalSince(flash) < 1.6 { next.phase = .attention }
    else if next.summaries.contains(where: { !$0.loading }) { next.phase = .summarizing }
    else if !next.summaries.isEmpty || !activeKeys.isEmpty { next.phase = .loading }
    else if next.judging || (ready && preferences.usesJev) { next.phase = .judging }
    else if !buffer.isEmpty { next.phase = .buffering }
    else if next.immediateWaiting + next.periodicWaiting > 0, next.retryAt == nil { next.phase = .waiting }
    else if next.retryAt != nil { next.phase = .retrying }
    else { next.phase = .idle }
    if activity != next { activity = next }
  }

  func summaryStarted(_ scope: ConversationScope) {
    summaryProgress[scope.key] = SummaryProgress(group: scope.group, groupName: groupName(scope.group))
    refreshActivity()
  }
  func summaryLoaded(_ unread: UnreadSnapshot) {
    guard summaryProgress[unread.scope.key] != nil else { return }
    summaryProgress[unread.scope.key]?.loading = false
    summaryProgress[unread.scope.key]?.messages = unread.messages.count
    refreshActivity()
  }
  func summaryRequest(_ scope: ConversationScope, stage: String) {
    guard summaryProgress[scope.key] != nil else { return }
    summaryProgress[scope.key]?.requests += 1
    summaryProgress[scope.key]?.stage = stage
    refreshActivity()
  }
  func markAttentionArrived() {
    attentionFlashAt = Date()
    refreshActivity()
  }
}
