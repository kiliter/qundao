import Foundation

public enum SummaryTrigger: String, Codable, Hashable { case immediate, periodic }
public struct ConversationScope: Codable, Hashable {
  public let account: String
  public let group: String
  public init(account: String, group: String) { self.account = account; self.group = group }
  // 长度前缀避免账号或群标识包含分隔符时串号。
  public var key: String { "\(account.utf8.count):\(account)\(group)" }
}
public struct SummaryMarker: Codable, Equatable {
  public let lastMessageID: String
  public let firstMessageID: String
  public let count: Int
  public let completedAt: Date
  public init(snapshot: UnreadSnapshot, now: Date = Date()) {
    lastMessageID = snapshot.messages.last!.id
    firstMessageID = snapshot.messages.first!.id
    count = snapshot.messages.count; completedAt = now
  }
}
public struct SummaryJob: Codable, Identifiable, Equatable {
  public let scope: ConversationScope
  public var sources: Set<SummaryTrigger>
  public var enqueuedAt: Date
  public var retryAt: Date
  public var attempts = 0
  public var running = false
  public var needsCheck = false
  public var id: String { scope.key }
  public init(scope: ConversationScope, trigger: SummaryTrigger, now: Date = Date()) {
    self.scope = scope; sources = [trigger]; enqueuedAt = now; retryAt = now
  }
}
public struct SummaryState: Codable, Equatable {
  public var markers: [String: SummaryMarker] = [:]
  public var jobs: [String: SummaryJob] = [:]
  public init() {}
  public mutating func recover() {
    for key in Array(jobs.keys) { jobs[key]?.running = false; jobs[key]?.needsCheck = false }
  }
}
public struct SummaryCompletion {
  public let snapshot: UnreadSnapshot
  public let result: AIResult
}

/// 两种触发共享同一份账号/群状态。所有变更在主 actor 上串行，网络调用可跨群并发。
@MainActor public final class SummaryCoordinator {
  public private(set) var state: SummaryState
  public private(set) var active: [String: Task<Void, Never>] = [:]
  private var generation = UUID()
  /// 批量扫描期间合并落盘与界面通知，结束时只保存一次。
  private var batching = 0, batchDirty = false
  public var load: (ConversationScope) async throws -> UnreadSnapshot
  public var summarize: (UnreadSnapshot) async throws -> AIResult
  /// 同一次原子写入中保存摘要结果与成功标记；失败时不得更新内存标记。
  public var persist: (SummaryState, SummaryCompletion?) throws -> Void
  public var trace: (String, ConversationScope?, [String: String]) -> Void
  public var isAllowed: (ConversationScope) -> Bool
  public var changed: () -> Void = {}
  public init(state: SummaryState = SummaryState(),
              load: @escaping (ConversationScope) async throws -> UnreadSnapshot,
              summarize: @escaping (UnreadSnapshot) async throws -> AIResult,
              persist: @escaping (SummaryState, SummaryCompletion?) throws -> Void,
              isAllowed: @escaping (ConversationScope) -> Bool = { _ in true },
              trace: @escaping (String, ConversationScope?, [String: String]) -> Void = { _, _, _ in }) {
    self.state = state; self.state.recover()
    self.load = load; self.summarize = summarize; self.persist = persist; self.trace = trace
    self.isAllowed = isAllowed
  }
  public func enqueue(_ scope: ConversationScope, trigger: SummaryTrigger, now: Date = Date()) {
    guard isAllowed(scope) else { return }
    let existing = state.jobs[scope.key]
    if var job = existing {
      job.sources.insert(trigger)
      if job.running { job.needsCheck = true }
      state.jobs[scope.key] = job
    } else { state.jobs[scope.key] = SummaryJob(scope: scope, trigger: trigger, now: now) }
    trace(existing == nil ? "摘要入队" : "同群触发合并", scope,
          ["来源": trigger.rawValue, "运行中": String(existing?.running ?? false), "待处理群数": "\(state.jobs.count)"])
    savePending(); notifyChanged()
  }
  /// 在一次扫描内合并多个 enqueue / consider 的待办保存，避免逐群整份写盘与刷新界面。
  public func batch(_ body: () throws -> Void) rethrows {
    batching += 1
    defer {
      batching -= 1
      if batching == 0, batchDirty { batchDirty = false; savePending(); changed() }
    }
    try body()
  }
  private func notifyChanged() { if batching == 0 { changed() } }
  public func consider(_ scope: ConversationScope, head: UnreadHead?) {
    guard isAllowed(scope) else { return }
    let old = state.markers[scope.key]?.lastMessageID
    let reason = head == nil ? "无未读" : (old == head?.lastID ? "末条与成功标记一致" : "新增未读或尚无成功记录")
    trace("周期扫描", scope, ["当前末条": head?.lastID ?? "无", "成功末条": old ?? "无", "原因": reason])
    if let head, head.lastID != old { enqueue(scope, trigger: .periodic) }
  }
  public func pump(account: String, concurrency: Int, now: Date = Date()) {
    let limit = min(8, max(1, concurrency))
    let jobs = state.jobs.values.filter { isAllowed($0.scope) && !$0.running && active[$0.id] == nil && $0.scope.account == account && $0.retryAt <= now }
      .sorted {
        if $0.sources.contains(.immediate) != $1.sources.contains(.immediate) { return $0.sources.contains(.immediate) }
        return $0.enqueuedAt < $1.enqueuedAt
      }
    for var job in jobs {
      guard active.count < limit else { break }
      job.running = true; job.needsCheck = false
      state.jobs[job.id] = job
      // 任务先落盘，再发送网络请求。写入失败保留待办，不冒险发送。
      do { try persist(state, nil) }
      catch {
        state.jobs[job.id]?.running = false
        state.jobs[job.id]?.retryAt = now.addingTimeInterval(5)
        trace("任务保存失败", job.scope, ["错误": error.localizedDescription]); continue
      }
      let current = generation
      active[job.id] = Task { [weak self] in await self?.execute(job, generation: current) }
      trace("摘要开始执行", job.scope, ["来源": job.sources.map(\.rawValue).sorted().joined(separator: ","),
                                      "并发": "\(active.count)/\(limit)", "重试次数": "\(job.attempts)"])
    }
    changed()
  }
  public func stop() {
    generation = UUID()
    active.values.forEach { $0.cancel() }; active = [:]
    state.recover(); savePending(); changed()
  }
  public func removeImmediate(account: String, groups: Set<String>) {
    for key in Array(state.jobs.keys) {
      guard var job = state.jobs[key], job.scope.account == account, groups.contains(job.scope.group) else { continue }
      job.sources.remove(.immediate)
      if job.sources.isEmpty {
        active[key]?.cancel()
        state.jobs[key] = nil
      } else { state.jobs[key] = job }
    }
    savePending(); changed()
  }
  /// 白名单同时限制两种触发；移出后取消在途工作并删除等待/重试任务。
  public func retainGroups(admission: MessageAdmission) {
    var removed = false
    for (key, job) in Array(state.jobs) where !job.scope.group.hasSuffix("@chatroom")
      || (job.scope.account == admission.account && !admission.allows(job.scope)) {
      active[key]?.cancel()
      state.jobs[key] = nil
      removed = true
    }
    if removed { savePending(); changed() }
  }
  private func savePending() {
    if batching > 0 { batchDirty = true; return }
    do { try persist(state, nil) }
    catch { trace("待办保存失败，内存保留待重试", nil, ["错误": error.localizedDescription]) }
  }
  private func execute(_ job: SummaryJob, generation current: UUID) async {
    let started = Date()
    defer {
      if generation == current { active[job.id] = nil; changed() }
    }
    do {
      guard isAllowed(job.scope) else { return }
      let snapshot = try await load(job.scope)
      try Task.checkCancellation()
      guard generation == current, state.jobs[job.id] != nil, isAllowed(job.scope) else { return }
      guard snapshot.scope == job.scope else { throw AppFailure.message("未读快照账号或群不匹配") }
      let last = snapshot.messages.last?.id
      if last == nil || state.markers[job.id]?.lastMessageID == last {
        var candidate = state
        finish(&candidate, id: job.id)
        try persist(candidate, nil); state = candidate
        trace("摘要跳过", job.scope, ["当前末条": last ?? "无", "原因": last == nil ? "无未读" : "该末条已经成功摘要"])
        return
      }
      trace("固定未读快照", job.scope, ["首条": snapshot.messages.first!.id, "末条": last!,
                                    "消息数": "\(snapshot.messages.count)", "读取时间": "\(snapshot.capturedAt)"])
      let result = try await summarize(snapshot)
      try Task.checkCancellation()
      guard generation == current, state.jobs[job.id] != nil, isAllowed(job.scope) else { return }
      try result.validate(allowedIDs: Set(snapshot.messages.map(\.id)))
      var candidate = state
      candidate.markers[job.id] = SummaryMarker(snapshot: snapshot)
      finish(&candidate, id: job.id)
      try persist(candidate, SummaryCompletion(snapshot: snapshot, result: result))
      state = candidate
      trace("摘要完成，成功标记已保存", job.scope,
            ["成功末条": last!, "消息数": "\(snapshot.messages.count)", "耗时毫秒": "\(Int(Date().timeIntervalSince(started) * 1000))",
             "待检查": String(state.jobs[job.id] != nil)])
    } catch {
      guard !Task.isCancelled, generation == current, var latest = state.jobs[job.id] else { return }
      latest.running = false; latest.needsCheck = false; latest.attempts += 1
      let delay = min(300, pow(2, Double(min(latest.attempts, 6))) * 5)
      latest.retryAt = Date().addingTimeInterval(delay)
      state.jobs[job.id] = latest
      savePending()
      trace("摘要失败，保留任务退避重试", job.scope,
            ["次数": "\(latest.attempts)", "退避秒": "\(delay)", "错误": error.localizedDescription,
             "成功标记": state.markers[job.id]?.lastMessageID ?? "无"])
    }
  }
  private func finish(_ candidate: inout SummaryState, id: String) {
    if candidate.jobs[id]?.needsCheck == true {
      candidate.jobs[id]?.running = false; candidate.jobs[id]?.needsCheck = false
      candidate.jobs[id]?.attempts = 0; candidate.jobs[id]?.retryAt = Date()
    } else { candidate.jobs[id] = nil }
  }
}

public struct PeriodicSummaryClock {
  public private(set) var last: Date
  public init(now: Date = Date()) { last = now }
  public mutating func tick(now: Date = Date(), intervalMinutes: Int) -> Bool {
    guard now.timeIntervalSince(last) >= Double(max(1, intervalMinutes)) * 60 else { return false }
    last = now; return true
  }
}
