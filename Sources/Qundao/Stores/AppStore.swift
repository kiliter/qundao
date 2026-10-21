import AppKit
import Combine
import Foundation
import QundaoCore
import UserNotifications

@MainActor final class AppStore: ObservableObject {
  static let shared = AppStore()
  @Published var snapshot = AppSnapshot()
  @Published var accounts: [Account] = []
  @Published var models: [CatalogModel] = []
  @Published var page: Page = .attention
  @Published var status = "尚未连接 Alpha"
  @Published var streamStatus = "尚未启动"
  @Published var error: String?
  @Published var running = false
  @Published var syncing = false
  @Published var analyzing = false
  @Published var lastSync: Date?
  @Published private(set) var groupStatesLastSync: Date?
  @Published private(set) var groupStatesError: String?
  @Published private(set) var groupStatesRefreshing = false
  @Published var lastAnalysis: Date?
  @Published var detail: Attention?
  @Published var summaryGroupID: String?
  @Published var decisionStatus = "本地识别"
  @Published var busy = false
  @Published var loadingCredentials = false
  @Published var queueDescription = "分析队列空闲"
  var onAttention: (() -> Void)?
  var alphaToken = "", cpaKey = "", jevKey = ""
  lazy var jevMonitor = JevMonitor(store: self)
  let disk = DiskStore(), log = EventLog.shared, semantic = SemanticFilter()
  private var pollTask: Task<Void, Never>?, streamTask: Task<Void, Never>?,
    worker: Task<Void, Never>?, pendingRefresh: Task<Void, Never>?, periodicTask: Task<Void, Never>?, scanTask: Task<Void, Never>?
  private var persistenceHealthy = true
  private var generation = UUID()
  private var groupRefreshTask: Task<Void, Never>?
  private var connectionRequest: UUID?
  private var syncRequest: UUID?
  private var catalogLoading = false
  private var periodicClock = PeriodicSummaryClock()
  private lazy var groupStates = {
    let synchronizer = GroupStateSynchronizer(account: preferences.accountID, cachedGroups: snapshot.groups,
      load: { [weak self] account in
        guard let self, self.preferences.accountID == account, !self.alphaToken.isEmpty else { throw CancellationError() }
        return try await AlphaClient(token: self.alphaToken).groups(account: account)
      })
    synchronizer.changed = { [weak self] state in
      guard let self, state.account == self.preferences.accountID else { return }
      let previousSync = self.groupStatesLastSync
      let previousError = self.groupStatesError
      let groupsChanged = self.snapshot.groups != state.groups
      self.snapshot.groups = state.groups
      self.groupStatesLastSync = state.lastSync
      self.groupStatesError = state.error
      self.groupStatesRefreshing = state.refreshing
      if state.lastSync != previousSync, state.lastSync != nil {
        if groupsChanged { self.save() }
        if previousSync == nil || groupsChanged || previousError != nil {
          self.log.write("信息", "群未读状态已同步", "\(state.groups.count) 个群；\(state.groups.filter { $0.unread > 0 }.count) 个群有未读")
        }
      } else if let failure = state.error, failure != previousError {
        self.log.write("警告", "群未读状态同步失败", failure)
      }
    }
    return synchronizer
  }()
  lazy var summaries: SummaryCoordinator = {
    let coordinator = SummaryCoordinator(state: snapshot.summaryState ?? SummaryState(),
      load: { [weak self] scope in
        guard let self, self.messageAdmission.allows(scope) else { throw CancellationError() }
        let snapshot = try await UnreadSnapshotLoader(source: AlphaClient(token: self.alphaToken)).load(scope)
        guard self.messageAdmission.allows(scope) else { throw CancellationError() }
        return snapshot
      }, summarize: { [weak self] snapshot in
        guard let self else { throw CancellationError() }
        return try await self.summarizeSnapshot(snapshot)
      }, persist: { [weak self] state, completion in
        guard let self else { throw CancellationError() }
        try self.persistSummary(state, completion: completion)
      }, isAllowed: { [weak self] scope in
        self?.messageAdmission.allows(scope) ?? false
      }, trace: { [weak self] event, scope, fields in
        self?.log.record(DiagnosticRecord(category: .runtime, event: event, scope: scope?.key ?? "",
          output: DiagnosticRecord.safeText(try? JSONSerialization.data(withJSONObject: fields))))
        if let failure = fields["错误"] { self?.error = failure }
      })
    coordinator.changed = { [weak self] in self?.refreshQueueStatus() }
    return coordinator
  }()
  var preferences: Preferences { snapshot.preferences }
  var messageAdmission: MessageAdmission { MessageAdmission(account: preferences.accountID, groups: preferences.selectedGroups) }
  var activeAccount: Account? { accounts.first { $0.id == preferences.accountID } }
  var pending: [Attention] {
    snapshot.attentions.filter {
      $0.message.accountID == preferences.accountID && $0.status == "pending"
    }.sorted { $0.message.timestamp > $1.message.timestamp }
  }
  var digests: [Digest] {
    snapshot.digests.filter { $0.accountID == preferences.accountID }.sorted { $0.date > $1.date }
  }
  var relevantDigests: [Digest] { digests.filter(\.related) }
  var isQuiet: Bool { (preferences.dndUntil ?? .distantPast) > Date() }
  var configured: Bool { !alphaToken.isEmpty && !preferences.accountID.isEmpty }
  func groupUnreadCount(_ groupID: String) -> Int? {
    guard groupStatesLastSync != nil else { return nil }
    return snapshot.groups.first(where: { $0.id == groupID }).map { max(0, $0.unread) }
  }

  /// 只读同步 Alpha 会话状态，不读取消息，也不触发摘要；暂停监听时仍可调用。
  func refreshGroupStates() async {
    guard configured else { return }
    ensureGroupStateRefresh()
    do { _ = try await loadGroupStates(account: preferences.accountID) }
    catch { /* 状态协调器保留旧值，并通过 groupStatesError 向界面报告失败。 */ }
  }

  private func loadGroupStates(account: String) async throws -> [ChatGroup] {
    guard account == preferences.accountID, configured else { throw CancellationError() }
    return try await groupStates.refresh(account: account)
  }

  private func ensureGroupStateRefresh() {
    guard configured, groupRefreshTask == nil else { return }
    groupRefreshTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        await self.refreshGroupStates()
        // 会话读取与慢速消息补查独立，微信已读变化不需要等待新消息推送。
        do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { break }
      }
    }
  }

  func stopGroupStateRefresh() {
    groupRefreshTask?.cancel()
    groupRefreshTask = nil
    groupStates.cancel()
  }
  init() {
    do { snapshot = try disk.load() } catch {
      persistenceHealthy = false
      self.error = "本地状态无法读取，未覆盖旧文件。请先备份并检查：\(disk.directory.path)"
    }
    if persistenceHealthy {
      _ = snapshot.migrateWhitelist()
      snapshot.migrateSummaryWorkflow()
      snapshot.migrateAlphaREST()
      snapshot.discardExcludedProcessing(admission: messageAdmission)
      save()
    }
    log.write("信息", "应用启动", "本地语义筛选：\(semantic.available ? "可用":"不可用，使用称呼及关键词筛选")")
  }
  func loadCredentials() async {
    guard !loadingCredentials else { return }
    loadingCredentials = true
    status = "正在读取钥匙串；如有系统授权提示请手动完成"
    // 钥匙串可能等待系统授权，不得在 AppStore 初始化或主线程中阻塞界面。
    let values = await Task.detached(priority: .userInitiated) {
      (KeychainStore.get("alpha"), KeychainStore.get("cpa"), KeychainStore.get("jev"))
    }.value
    alphaToken = values.0; cpaKey = values.1; jevKey = values.2
    if !jevKey.isEmpty, snapshot.preferences.jevBaseURL == nil {
      snapshot.preferences.jevBaseURL = JevConfiguration.typeSafe.baseURL
      snapshot.preferences.jevAPI = .systemOne
      snapshot.preferences.jevModel = snapshot.preferences.jevModel ?? JevConfiguration.typeSafe.model
      save()
    }
    loadingCredentials = false
    status = alphaToken.isEmpty ? "请配置 Alpha 访问令牌" : "凭据已载入"
    ensureGroupStateRefresh()
  }
  func save() {
    guard persistenceHealthy else { return }
    // 即使前一次待办落盘失败，之后保存偏好/缓冲时也必须带上内存中的最新任务。
    snapshot.summaryState = summaries.state
    do { try disk.save(snapshot) } catch {
      self.error = "本地状态保存失败：\(error.localizedDescription)"
      log.write("错误", "状态保存失败")
    }
  }
  func update(_ f: (inout Preferences) -> Void) {
    let old = preferences
    f(&snapshot.preferences)
    save()
    if running && (old.decisionMethod != preferences.decisionMethod || old.decisionThreshold != preferences.decisionThreshold
      || old.jevConfiguration != preferences.jevConfiguration) { jevMonitor.start() }
  }
  func saveDecisionConnection(_ config: JevConfiguration, key: String) throws {
    _ = try config.endpoint()
    try KeychainStore.set(key, account: "jev")
    jevMonitor.stop()
    jevKey = key
    snapshot.preferences.jevBaseURL = config.baseURL
    snapshot.preferences.jevAPI = config.api
    snapshot.preferences.jevModel = config.model
    save()
    if running { jevMonitor.start() }
    log.write("信息", "决策服务配置已保存")
  }
  func setWhitelist(_ ids: Set<String>) {
    jevMonitor.stop()
    snapshot.preferences.selectedGroups = Set(ids.filter { $0.hasSuffix("@chatroom") })
    snapshot.discardExcludedProcessing(admission: messageAdmission)
    summaries.retainGroups(admission: messageAdmission)
    save()
    if running { jevMonitor.start() }
    log.write("信息", "更新监听白名单", "即时与周期均仅处理 \(preferences.selectedGroups.count) 个白名单群")
  }
  func saveCredentials(alpha: String, cpa: String) {
    do {
      try KeychainStore.set(alpha, account: "alpha")
      try KeychainStore.set(cpa, account: "cpa")
      alphaToken = alpha
      cpaKey = cpa
      // 连接信息变化后，之前正在读取的响应不能覆盖新连接的状态。
      groupStates.reset(account: preferences.accountID, cachedGroups: snapshot.groups)
      ensureGroupStateRefresh()
      error = nil
      status = "连接信息已保存"
      log.write("信息", "连接配置已保存")
    } catch {
      self.error = error.localizedDescription
      log.write("错误", "钥匙串保存失败")
    }
  }
  func connect() async {
    let request = UUID()
    let requestedAccount = preferences.accountID
    connectionRequest = request
    busy = true
    defer {
      if connectionRequest == request {
        connectionRequest = nil
        busy = catalogLoading
      }
    }
    do {
      guard !alphaToken.isEmpty else { throw AppFailure.message("请先保存 Alpha 访问令牌") }
      ensureGroupStateRefresh()
      let client = AlphaClient(token: alphaToken)
      let loadedAccounts = try await client.accounts()
      guard connectionRequest == request, preferences.accountID == requestedAccount else { return }
      accounts = loadedAccounts
      guard !accounts.isEmpty else { throw AppFailure.message("Alpha 没有已就绪的微信账号") }
      if !accounts.contains(where: { $0.id == preferences.accountID }) {
        stop()
        snapshot.preferences.accountID = accounts[0].id
        snapshot.preferences.selectedGroups = []
        snapshot.preferences.groupsInitialized = false
        groupStates.reset(account: preferences.accountID)
        snapshot.discardExcludedProcessing(admission: messageAdmission)
        summaries.retainGroups(admission: messageAdmission)
      }
      let account = preferences.accountID
      _ = try await loadGroupStates(account: account)
      guard connectionRequest == request, preferences.accountID == account else { return }
      ensureGroupStateRefresh()
      if !preferences.groupsInitialized {
        snapshot.preferences.groupsInitialized = true
      }
      status = "Alpha 已连接"
      error = nil
      save()
      log.write("信息", "Alpha 连接成功", "账号数量 \(accounts.count)，群数量 \(snapshot.groups.count)")
    } catch {
      guard connectionRequest == request, !(error is CancellationError) else { return }
      status = "连接失败"
      self.error = error.localizedDescription
      log.write("错误", "Alpha 连接失败", error.localizedDescription)
    }
  }
  func loadCatalog() async {
    guard !busy else { return }
    catalogLoading = true
    busy = true
    defer { catalogLoading = false; busy = connectionRequest != nil }
    do {
      try await fetchCatalog()
      error = nil
    } catch {
      self.error = error.localizedDescription
      log.write("错误", "模型目录读取失败", error.localizedDescription)
    }
  }
  private func fetchCatalog() async throws {
    guard !cpaKey.isEmpty else { throw AppFailure.message("请先保存 CPA API Key") }
    models = try await CPAClient(key: cpaKey).catalog()
    if !models.contains(where: { $0.id == preferences.model }) {
      snapshot.preferences.model =
        models.first(where: { $0.id == "gpt-6.1-sol" })?.id ?? models[0].id
    }
    normalizeReasoning()
    save()
    log.write("信息", "模型目录已更新", "\(models.count) 个模型，Codex 目录模式")
  }
  func normalizeReasoning() {
    if let m = models.first(where: { $0.id == preferences.model }),
      !m.reasoningLevels.contains(preferences.reasoning)
    {
      snapshot.preferences.reasoning = m.defaultReasoning ?? m.reasoningLevels.first ?? ""
    }
  }
  func selectAccount(_ id: String) {
    stop()
    connectionRequest = nil
    busy = catalogLoading
    snapshot.preferences.accountID = id
    snapshot.preferences.selectedGroups = []
    snapshot.preferences.groupsInitialized = false
    groupStates.reset(account: id)
    snapshot.discardExcludedProcessing(admission: messageAdmission)
    summaries.retainGroups(admission: messageAdmission)
    save()
    Task { await connect() }
  }
  func start() {
    guard persistenceHealthy else {
      error = "本地状态读取失败，修复前停止监听以保护已有进度"
      return
    }
    guard configured else {
      page = .connection
      error = "请先连接 Alpha 并选择微信账号"
      return
    }
    stop()
    running = true
    ensureGroupStateRefresh()
    jevMonitor.start()
    status = "正在同步"
    error = nil
    generation = UUID()
    let current = generation
    snapshot.discardExcludedProcessing(admission: messageAdmission)
    summaries.retainGroups(admission: messageAdmission)
    log.write("信息", "开始监听", "即时与周期均仅处理 \(preferences.selectedGroups.count) 个白名单群")
    worker = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled && self.generation == current {
        self.wakeSnoozed()
        self.flushRealtime()
        if self.preferences.aiEnabled {
          self.summaries.pump(account: self.preferences.accountID, concurrency: self.preferences.concurrentSummaries)
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
      }
    }
    periodicClock = PeriodicSummaryClock()
    periodicTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled && self.generation == current {
        if self.preferences.aiEnabled,
           self.periodicClock.tick(intervalMinutes: self.preferences.intervalMinutes) {
          self.requestAllAnalysis()
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
      }
    }
    pollTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled && self.generation == current {
        await self.synchronize()
        try? await Task.sleep(nanoseconds: 30_000_000_000)
      }
    }
    streamTask = Task { [weak self] in
      guard let self else { return }
      var delay: UInt64 = 2
      while !Task.isCancelled && self.generation == current {
        do {
          try await AlphaClient(token: self.alphaToken).stream(account: self.preferences.accountID)
          { [weak self] event in self?.streamEvent(event, generation: current) }
        } catch {
          guard !Task.isCancelled, self.generation == current else { break }
          self.streamStatus = error.localizedDescription
          self.log.write("警告", "推送断开", error.localizedDescription)
        }
        try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
        delay = min(delay * 2, 60)
      }
    }
  }
  func stop() {
    jevMonitor.stop()
    generation = UUID()
    syncRequest = nil
    syncing = false
    periodicTask?.cancel()
    periodicTask = nil
    pollTask?.cancel()
    streamTask?.cancel()
    pendingRefresh?.cancel()
    worker?.cancel()
    pollTask = nil
    streamTask = nil
    worker = nil
    pendingRefresh = nil
    scanTask?.cancel(); scanTask = nil
    summaries.stop()
    running = false
    streamStatus = "已暂停"
    status = "监听已暂停"
    refreshQueueStatus()
    log.write("信息", "停止监听")
  }
  func streamEvent(_ event: SSEEvent, generation current: UUID) {
    guard current == generation, running else { return }
    if event.event == "connected" {
      streamStatus = "实时推送已连接"
      log.write("信息", "推送已连接")
    }
    if event.event == "stream.error" {
      streamStatus = "推送异常，继续定时补查"
      log.write("警告", "推送报告缺口", "将从持久化进度补查")
    }
    if event.event == "message.new" {
      guard let data = event.data.data(using: .utf8),
            let message = PushMessage.decode(data, account: preferences.accountID, allowedGroups: preferences.selectedGroups),
            messageAdmission.allows(message) else { return }
      let group = snapshot.groups.first(where: { $0.id == message.groupID }) ?? ChatGroup(id: message.groupID, name: message.groupID, unread: 0)
      ingest([message], group: group)
      save()
    }
    if ["connected", "stream.ready", "message.new", "stream.error"].contains(event.event),
      pendingRefresh == nil
    {
      pendingRefresh = Task { [weak self] in
        try? await Task.sleep(nanoseconds: 500_000_000)
        guard let self, !Task.isCancelled, self.generation == current else { return }
        self.pendingRefresh = nil
        await self.synchronize()
      }
    }
  }
  func synchronize() async {
    guard running, syncRequest == nil else { return }
    let request = UUID()
    syncRequest = request
    syncing = true
    defer {
      if syncRequest == request { syncRequest = nil; syncing = false }
    }
    let current = generation
    let account = preferences.accountID
    let client = AlphaClient(token: alphaToken)
    do {
      let groups = try await loadGroupStates(account: account)
      guard current == generation else { return }
      var failedGroups = 0
      for group in groups {
        do {
          try Task.checkCancellation()
          guard current == generation else { return }
          guard messageAdmission.allows(account: account, group: group.id) else { continue }
          let scope = "\(account)|\(group.id)"
          if snapshot.checkpoints[scope] == nil {
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            snapshot.checkpoints[scope] = Checkpoint(
              after: now - 60000, upper: group.unread > 0 ? now + 1 : nil,
              baseline: group.unread > 0,
              remaining: group.unread)
          }
          guard var checkpoint = snapshot.checkpoints[scope] else { continue }
          if checkpoint.baseline {
            // 大量首次未读也分页持久化；单群每轮最多 3 页，避免一个活跃群占满补查。
            for _ in 0..<3 {
              let remaining = max(1, checkpoint.remaining ?? group.unread)
              let page = try await client.messages(
                account: account, group: group.id, after: nil, before: checkpoint.upper,
                cursor: checkpoint.cursor, limit: min(200, remaining), order: "desc")
              guard current == generation, messageAdmission.allows(account: account, group: group.id) else { return }
              ingest(page.messages, group: group)
              checkpoint.remaining = max(0, remaining - page.messages.count)
              checkpoint.cursor = page.cursor
              if checkpoint.remaining == 0 || page.cursor == nil || page.messages.isEmpty {
                checkpoint.baseline = false
                checkpoint.cursor = nil
                checkpoint.upper = nil
                checkpoint.remaining = nil
              }
              snapshot.checkpoints[scope] = checkpoint
              save()
              if !checkpoint.baseline { break }
              try Task.checkCancellation()
            }
            if checkpoint.baseline { continue }
          }
          if checkpoint.upper == nil {
            checkpoint.upper = Int64(Date().timeIntervalSince1970 * 1000) + 1
          }
          for _ in 0..<10 {
            let page = try await client.messages(
              account: account, group: group.id, after: checkpoint.after, before: checkpoint.upper,
              cursor: checkpoint.cursor)
            guard current == generation, messageAdmission.allows(account: account, group: group.id) else { return }
            ingest(page.messages, group: group)
            checkpoint.cursor = page.cursor
            if page.cursor == nil {
              checkpoint.after = max(
                checkpoint.after, (checkpoint.upper ?? checkpoint.after) - 60000)
              checkpoint.upper = nil
            }
            snapshot.checkpoints[scope] = checkpoint
            save()
            if page.cursor == nil { break }
            try Task.checkCancellation()
          }
        } catch {
          try Task.checkCancellation()
          guard current == generation else { return }
          failedGroups += 1
          self.error = "部分群同步失败，已保留进度：\(error.localizedDescription)"
          log.write("错误", "单群补查失败", "群 \(EventLog.ref(group.id))；继续同步其他群")
        }
      }
      guard current == generation else { return }
      lastSync = Date()
      status =
        failedGroups == 0
        ? "正在关注 \(preferences.selectedGroups.count) 个群" : "\(failedGroups) 个群等待重试，其他群正常"
      save()
    } catch {
      if current == generation, !Task.isCancelled {
        status = "同步失败，进度已保留"
        self.error = error.localizedDescription
        log.write("错误", "补查失败", "未推进失败分页进度，请在主窗口查看错误")
      }
    }
  }
  private func ingest(_ messages: [Message], group: ChatGroup) {
    guard messageAdmission.allows(account: preferences.accountID, group: group.id) else { return }
    let added = snapshot.ingestRealtime(messages.filter { $0.groupID == group.id }, admission: messageAdmission,
                                       selfID: activeAccount?.subjectID ?? "")
    if added > 0 { log.write("信息", "消息入库", "群 \(EventLog.ref(group.id))；新增 \(added) 条，仅缓存不代表已摘要") }
    flushRealtime()
  }
  private func flushRealtime() {
    var drained = snapshot.realtimeBuffer ?? RealtimeBuffer()
    drained.retain(admission: messageAdmission)
    let batches = drained.flush(account: preferences.accountID, capacity: preferences.bufferCapacity,
                                interval: preferences.bufferInterval)
    guard !batches.isEmpty else { return }
    log.record(DiagnosticRecord(category: .runtime, event: "实时缓冲 flush",
      output: DiagnosticRecord.safeText(try? JSONSerialization.data(withJSONObject: batches.map {
        ["账号": $0.scope.account, "群聊": $0.scope.group, "原因": $0.reason, "消息数量": "\($0.messages.count)"]
      }))))
    for batch in batches where messageAdmission.allows(batch.scope) {
      let messages = batch.messages.map { buffered in snapshot.messages.first(where: { $0.key == buffered.key }) ?? buffered }
      let usingJev = preferences.usesJev && !jevKey.isEmpty
      let started = Date()
      let decisions = RealtimeDecision.local(messages, preferences: preferences, selfID: activeAccount?.subjectID ?? "",
        semantic: { [self] in !usingJev && semantic.matches($0, keywords: preferences.keywords) })
      var related = false
      let name = snapshot.groups.first(where: { $0.id == batch.scope.group })?.name ?? batch.scope.group
      for decision in decisions {
        let direct: Bool
        if case .definite(let reason) = decision.match {
          direct = true
          if preferences.immediateMentions {
            addAttention(Attention(message: decision.message, groupName: name, title: "\(decision.message.sender) 找你", reason: reason, definite: true))
          }
        } else { direct = false }
        related = related || direct || (!usingJev && decision.related)
        log.localDecision(decision.message, preferences: preferences, selfID: activeAccount?.subjectID ?? "",
          match: decision.match, semantic: decision.semantic,
          action: direct || (!usingJev && decision.related) ? "命中，本群提交一次即时摘要" : (usingJev ? "本批交给 Jev" : "无关，不触发即时摘要"),
          elapsed: Date().timeIntervalSince(started))
      }
      // 同批只产生一次群触发。已有明确本地命中时无需再等 Jev 重复触发。
      if related { enqueue(batch.scope.group) }
      else if usingJev {
        let candidates = messages.filter { $0.senderID.isEmpty || $0.senderID != activeAccount?.subjectID }
        if !candidates.isEmpty { jevMonitor.receive(candidates, scope: batch.scope) }
      }
    }
    // 先将所有分组的后续任务保存，再移除缓冲消息，崩溃窗口只会复查，不会吞掉后面的群。
    snapshot.realtimeBuffer = drained
    save()
  }
  func enqueue(_ group: String, trigger: SummaryTrigger = .immediate) {
    guard messageAdmission.allows(account: preferences.accountID, group: group) else { return }
    summaries.enqueue(ConversationScope(account: preferences.accountID, group: group), trigger: trigger)
  }
  private func refreshQueueStatus() {
    let jobs = summaries.state.jobs.values
    let immediate = jobs.filter { !$0.running && $0.sources.contains(.immediate) }.count
    let periodic = jobs.filter { !$0.running && !$0.sources.contains(.immediate) }.count
    let active = !summaries.active.isEmpty
    let description = "即时等待 \(immediate) · 定时等待 \(periodic) · 正在摘要 \(summaries.active.count)/\(preferences.concurrentSummaries)"
    if analyzing != active { analyzing = active }
    if queueDescription != description { queueDescription = description }
  }
  func requestAllAnalysis() {
    guard running, preferences.aiEnabled, scanTask == nil else { return }
    let account = preferences.accountID, current = generation
    scanTask = Task { [weak self] in
      guard let self else { return }
      defer { if generation == current { scanTask = nil } }
      let client = AlphaClient(token: alphaToken)
      let loader = UnreadSnapshotLoader(source: client)
      do {
        let groups = try await loadGroupStates(account: account)
        try Task.checkCancellation()
        guard generation == current else { return }
        for group in groups {
          try Task.checkCancellation()
          let scope = ConversationScope(account: account, group: group.id)
          guard messageAdmission.allows(scope) else { continue }
          if group.unread == 0 { summaries.consider(scope, head: nil); continue }
          do {
            let head = try await loader.head(scope)
            try Task.checkCancellation()
            guard generation == current else { return }
            guard messageAdmission.allows(scope) else { continue }
            summaries.consider(scope, head: head)
          } catch {
            try Task.checkCancellation()
            guard generation == current else { return }
            guard messageAdmission.allows(scope) else { continue }
            // 单群边界读取失败也成为可恢复任务，不影响其它群扫描。
            summaries.enqueue(scope, trigger: .periodic)
            log.write("警告", "周期读取失败，入队复查", error.localizedDescription)
          }
        }
        save()
      } catch {
        if !Task.isCancelled, generation == current { self.error = error.localizedDescription; log.write("错误", "周期扫描失败", error.localizedDescription) }
      }
    }
  }
  private func summarizeSnapshot(_ unread: UnreadSnapshot) async throws -> AIResult {
    guard messageAdmission.allows(unread.scope) else { throw CancellationError() }
    guard !cpaKey.isEmpty else { throw AppFailure.message("请在连接与模型中配置 CPA") }
    if models.isEmpty { try await fetchCatalog() }
    try Task.checkCancellation()
    let prefs = preferences
    guard messageAdmission.allows(unread.scope) else { throw CancellationError() }
    guard let model = models.first(where: { $0.id == prefs.model }) else { throw AppFailure.message("所选模型不在目录中，请重新选择") }
    let client = CPAClient(key: cpaKey, trace: { [weak self] record in
      guard let self, self.messageAdmission.allows(unread.scope) else { return }
      var scoped = record
      scoped.scope = unread.scope.key
      self.log.record(scoped)
    })
    let summarizer = SnapshotSummarizer(budget: model.inputBudget, names: prefs.names, keywords: prefs.keywords,
                                      selfID: activeAccount?.subjectID ?? "")
    return try await summarizer.run(unread.messages) { input, ids in
      try Task.checkCancellation()
      guard self.messageAdmission.allows(unread.scope) else { throw CancellationError() }
      return try await client.summarize(input, allowedIDs: ids, model: model, reasoning: prefs.reasoning)
    }
  }
  private func persistSummary(_ state: SummaryState, completion: SummaryCompletion?) throws {
    guard persistenceHealthy else { throw AppFailure.message("本地状态不可写，未推进摘要成功标记") }
    var candidate = snapshot
    candidate.summaryState = state
    var newAttentions: [Attention] = []
    if let completion {
      let unread = completion.snapshot, result = completion.result
      guard messageAdmission.allows(unread.scope) else { throw CancellationError() }
      candidate.digests.append(Digest(accountID: unread.scope.account, groupID: unread.scope.group, groupName: unread.groupName,
        text: result.summary, count: unread.messages.count, evidence: unread.messages, related: result.relevant,
        relevanceReason: result.relevanceReason))
      candidate.digests = Array(candidate.digests.suffix(500))
      for judgment in result.judgements where judgment.needsResponse && judgment.confidence == "high" {
        if let message = unread.messages.first(where: { $0.id == judgment.messageID }),
           message.senderID.isEmpty || message.senderID != activeAccount?.subjectID,
           !candidate.attentions.contains(where: { $0.id == message.key }) {
          let item = Attention(message: message, groupName: unread.groupName, title: judgment.title,
                               reason: "AI 判断：\(judgment.reason)", definite: false)
          candidate.attentions.append(item); newAttentions.append(item)
        }
      }
    }
    // 不能使用吞掉错误的 save()。标记、摘要、待办必须作为同一快照原子保存成功。
    try disk.save(candidate)
    snapshot = candidate
    if let completion {
      lastAnalysis = Date()
      if !isQuiet {
        for item in newAttentions { notify(item) }
        if preferences.autoExpand, completion.result.relevant { onAttention?() }
      }
    }
  }
  func addAttention(_ item: Attention) {
    guard messageAdmission.allows(item.message), !snapshot.attentions.contains(where: { $0.id == item.id }) else { return }
    snapshot.attentions.append(item)
    log.write(
      "信息", "新增相关提醒",
      "群 \(EventLog.ref(item.message.groupID))；消息 \(EventLog.ref(item.id))；\(item.definite ? "直接命中":"AI判断")"
    )
    if !isQuiet {
      if preferences.autoExpand { onAttention?() }
      notify(item)
    }
  }
  func readRelatedSummary(_ digest: Digest) {
    readSummaries([digest])
  }
  func readSummaries(_ digests: [Digest]) {
    setViewed(digestIDs: Set(digests.filter { $0.accountID == preferences.accountID }.map(\.id)))
  }
  func setViewed(digestIDs: Set<UUID> = [], attentionIDs: Set<String> = []) {
    guard persistenceHealthy else { error = "本地状态不可写，未更新摘要已阅状态"; return }
    guard !digestIDs.isEmpty || !attentionIDs.isEmpty else { return }
    var candidate = snapshot
    candidate.summaryState = summaries.state
    candidate.markViewed(account: preferences.accountID, digestIDs: digestIDs, attentionIDs: attentionIDs)
    do {
      try disk.save(candidate)
      snapshot = candidate
      log.write("信息", "内容已阅", "摘要 \(digestIDs.count) 批，提醒 \(attentionIDs.count) 条；仅更新群岛状态")
    } catch {
      self.error = "摘要已阅状态保存失败：\(error.localizedDescription)"
      log.write("错误", "已阅状态保存失败")
    }
  }
  func resolve(_ item: Attention) {
    guard let index = snapshot.attentions.firstIndex(where: { $0.id == item.id }) else { return }
    snapshot.attentions[index].status = "done"
    save()
    log.write("信息", "提醒已处理", EventLog.ref(item.id))
  }
  func snooze(_ item: Attention) {
    guard let index = snapshot.attentions.firstIndex(where: { $0.id == item.id }) else { return }
    snapshot.attentions[index].status = "snoozed"
    snapshot.attentions[index].remindAt = Date().addingTimeInterval(900)
    save()
    log.write("信息", "稍后提醒", EventLog.ref(item.id))
  }
  func wakeSnoozed() {
    var changed = false
    for index in snapshot.attentions.indices
    where messageAdmission.allows(snapshot.attentions[index].message)
      && snapshot.attentions[index].status == "snoozed"
      && (snapshot.attentions[index].remindAt ?? .distantFuture) <= Date()
    {
      snapshot.attentions[index].status = "pending"
      changed = true
      if !isQuiet {
        notify(snapshot.attentions[index])
        onAttention?()
      }
    }
    if changed { save() }
  }
  func requestNotifications() async {
    do {
      let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [
        .alert, .sound, .badge,
      ])
      update { $0.notifications = allowed }
      if !allowed { error = "系统通知未授权，可在系统设置中开启" }
    } catch { self.error = error.localizedDescription }
  }
  private func notify(_ item: Attention) {
    guard preferences.notifications, !isQuiet else { return }
    let content = UNMutableNotificationContent()
    content.title = "\(item.groupName) · \(item.message.sender)"
    content.body = preferences.hideNotificationText ? "有人找你，点击查看" : item.title
    content.userInfo = ["attentionID": item.id]
    UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: item.id, content: content, trigger: nil)
    ) { _ in }
  }
  func toggleQuiet() {
    let quiet = isQuiet
    update { $0.dndUntil = quiet ? nil : Date().addingTimeInterval(3600) }
  }
}
enum Page: String, CaseIterable, Identifiable {
  case attention = "需要关注"
  case summary = "群聊摘要"
  case groups = "监听群聊"
  case rules = "关键词与规则"
  case appearance = "刘海与通知"
  case connection = "连接与模型"
  case logs = "运行日志"
  var id: String { rawValue }
  var icon: String {
    switch self {
    case .attention: return "circle.inset.filled"
    case .summary: return "text.alignleft"
    case .groups: return "square.grid.2x2"
    case .rules: return "command"
    case .appearance: return "macbook"
    case .connection: return "arrow.left.arrow.right"
    case .logs: return "doc.text.magnifyingglass"
    }
  }
}
