import AppKit
import Observation
import Foundation
import QundaoCore
import UserNotifications

@MainActor @Observable final class AppStore {
  static let shared = AppStore()
  /// 快照本身不参与观察：任何字段（检查点、缓冲、去重集合）变化都会触发整树刷新。
  /// 改为按界面实际使用的分片比较，只有对应分片真正变化才通知读取它的视图。
  @ObservationIgnored var snapshot = AppSnapshot() { didSet { snapshotChanged(from: oldValue) } }
  private(set) var groupsRevision: UInt64 = 0
  private(set) var digestsRevision: UInt64 = 0
  private(set) var attentionsRevision: UInt64 = 0
  private(set) var messagesRevision: UInt64 = 0
  private(set) var preferencesRevision: UInt64 = 0
  /// 群聊摘要页分组结果缓存，键为是否只看相关。
  @ObservationIgnored var summaryThreadCache: [Bool: (account: String, synced: Bool, threads: [SummaryThread])] = [:]
  /// 待关注记录在每次视图刷新时会被多处读取，按快照缓存，避免重复过滤排序。
  @ObservationIgnored var attentionCache: (account: String, entries: [AttentionEntry], threads: [AttentionThread])?
  @ObservationIgnored private var digestCache: (account: String, digests: [Digest])?
  var accounts: [Account] = []
  var models: [CatalogModel] = []
  var page: Page = .attention
  var status = "尚未连接 Alpha"
  var streamStatus = "尚未启动"
  var error: String?
  var running = false
  var syncing = false
  var analyzing = false
  var lastSync: Date?
  private(set) var groupStatesLastSync: Date?
  /// 是否已至少同步过一次 Alpha 未读；只在首次同步时变化，避免每 5 秒刷新摘要列表。
  private(set) var groupStatesSynced = false
  private(set) var groupStatesError: String?
  private(set) var groupStatesRefreshing = false
  var lastAnalysis: Date?
  var detail: Attention?
  /// 刘海点击后主窗口需要关注页选中的群。
  var attentionGroupID: String?
  var summaryGroupID: String?
  var decisionStatus = "本地识别"
  var busy = false
  var loadingCredentials = false
  var queueDescription = "分析队列空闲"
  /// 刘海处理阶段概况；由工作循环与调度变化刷新，值不变不写。
  var activity = IslandActivity()
  @ObservationIgnored var summaryProgress: [String: SummaryProgress] = [:]
  /// 正在 Jev 判断的群 ID。
  @ObservationIgnored var jevJudging: String?
  @ObservationIgnored var attentionFlashAt: Date?
  @ObservationIgnored var onAttention: (() -> Void)?
  @ObservationIgnored var alphaToken = ""
  @ObservationIgnored var cpaKey = ""
  @ObservationIgnored var jevKey = ""
  @ObservationIgnored lazy var jevMonitor = JevMonitor(store: self)
  @ObservationIgnored let disk = DiskStore()
  @ObservationIgnored let log = EventLog.shared
  @ObservationIgnored let semantic = SemanticFilter()
  @ObservationIgnored private var pollTask: Task<Void, Never>?
  @ObservationIgnored private var streamTask: Task<Void, Never>?
  @ObservationIgnored private var worker: Task<Void, Never>?
  @ObservationIgnored private var pendingRefresh: Task<Void, Never>?
  @ObservationIgnored private var periodicTask: Task<Void, Never>?
  @ObservationIgnored private var scanTask: Task<Void, Never>?
  @ObservationIgnored private var persistenceHealthy = true
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var groupRefreshTask: Task<Void, Never>?
  @ObservationIgnored private var connectionRequest: UUID?
  @ObservationIgnored private var syncRequest: UUID?
  @ObservationIgnored private var catalogLoading = false
  @ObservationIgnored private var periodicClock = PeriodicSummaryClock()
  /// 数组相等比较对未修改的共享存储是 O(1)，因此每次快照写入的检查开销很小。
  private func snapshotChanged(from old: AppSnapshot) {
    let groups = old.groups != snapshot.groups, digests = old.digests != snapshot.digests
    let attentions = old.attentions != snapshot.attentions, prefs = old.preferences != snapshot.preferences
    if groups { groupsRevision &+= 1 }
    if digests { digestsRevision &+= 1; digestCache = nil }
    if attentions { attentionsRevision &+= 1 }
    if old.messages != snapshot.messages { messagesRevision &+= 1 }
    if prefs { preferencesRevision &+= 1; digestCache = nil }
    if digests || attentions || prefs { attentionCache = nil }
    if groups || digests || prefs { summaryThreadCache = [:] }
  }
  /// 视图只能通过以下访问器读取快照内容，以便登记对应分片的依赖。
  var groups: [ChatGroup] { _ = groupsRevision; return snapshot.groups }
  var allDigests: [Digest] { _ = digestsRevision; return snapshot.digests }
  var allAttentions: [Attention] { _ = attentionsRevision; return snapshot.attentions }
  var cachedMessages: [Message] { _ = messagesRevision; return snapshot.messages }
  @ObservationIgnored private lazy var groupStates = {
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
      // 每 5 秒同步一次；值不变时不写，避免无谓地通知界面。
      if groupsChanged { self.snapshot.groups = state.groups }
      if previousSync != state.lastSync { self.groupStatesLastSync = state.lastSync }
      if self.groupStatesSynced != (state.lastSync != nil) { self.groupStatesSynced = state.lastSync != nil }
      if previousError != state.error { self.groupStatesError = state.error }
      if self.groupStatesRefreshing != state.refreshing { self.groupStatesRefreshing = state.refreshing }
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
  @ObservationIgnored lazy var summaries: SummaryCoordinator = {
    let coordinator = SummaryCoordinator(state: snapshot.summaryState ?? SummaryState(),
      load: { [weak self] scope in
        guard let self, self.messageAdmission.allows(scope) else { throw CancellationError() }
        self.summaryStarted(scope)
        let snapshot = try await UnreadSnapshotLoader(source: AlphaClient(token: self.alphaToken)).load(scope)
        guard self.messageAdmission.allows(scope) else { throw CancellationError() }
        self.summaryLoaded(snapshot)
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
  var preferences: Preferences { _ = preferencesRevision; return snapshot.preferences }
  var messageAdmission: MessageAdmission { MessageAdmission(account: preferences.accountID, groups: preferences.selectedGroups) }
  var activeAccount: Account? { accounts.first { $0.id == preferences.accountID } }
  var pending: [Attention] {
    snapshot.attentions.filter {
      $0.message.accountID == preferences.accountID && $0.status == "pending"
    }.sorted { $0.message.timestamp > $1.message.timestamp }
  }
  var digests: [Digest] {
    _ = digestsRevision
    let account = preferences.accountID
    if let cache = digestCache, cache.account == account { return cache.digests }
    let value = snapshot.digests.filter { $0.accountID == account }.sorted { $0.date > $1.date }
    digestCache = (account, value)
    return value
  }
  var relevantDigests: [Digest] { digests.filter(\.related) }
  var isQuiet: Bool { (preferences.dndUntil ?? .distantPast) > Date() }
  var configured: Bool { !alphaToken.isEmpty && !preferences.accountID.isEmpty }
  func groupUnreadCount(_ groupID: String) -> Int? {
    guard groupStatesSynced else { return nil }
    return groups.first(where: { $0.id == groupID }).map { max(0, $0.unread) }
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
      let covered = snapshot.migrateDigestCoverage()
      if covered > 0 { log.write("信息", "旧摘要覆盖关系已补算", "\(covered) 条旧摘要被同群较新摘要完整覆盖，不再待阅；历史保留") }
      snapshot.discardExcludedProcessing(admission: messageAdmission)
      save()
    }
    log.write("信息", "应用启动", "本地语义筛选：\(semantic.available ? "可用":"不可用，使用称呼及关键词筛选")")
  }
  /// 配置文件 ~/.config/qundao/config.toml 是密钥与模型/规则配置的唯一来源；
  /// 不存在时从旧版钥匙串一次性迁移，之后不再访问钥匙串，避免重签后反复弹出授权。
  @ObservationIgnored let configFile = AppConfigFile()
  @ObservationIgnored private var configWatcher: ConfigWatcher?
  /// 最近一次与文件一致的配置；按语义比较，避免改写用户手写的注释与格式。
  @ObservationIgnored private var lastConfig: AppConfig?
  func loadCredentials() async {
    guard !loadingCredentials else { return }
    loadingCredentials = true
    defer { loadingCredentials = false }
    if configFile.exists {
      reloadConfig(initial: true)
    } else {
      status = "正在从钥匙串迁移到配置文件；如有系统授权提示请手动完成"
      // 钥匙串可能等待系统授权，不得在主线程中阻塞界面。
      let values = await Task.detached(priority: .userInitiated) {
        (KeychainStore.get("alpha"), KeychainStore.get("cpa"), KeychainStore.get("jev"))
      }.value
      alphaToken = values.0; cpaKey = values.1; jevKey = values.2
      if !jevKey.isEmpty, snapshot.preferences.jevBaseURL == nil {
        snapshot.preferences.jevBaseURL = JevConfiguration.typeSafe.baseURL
        snapshot.preferences.jevAPI = .systemOne
        snapshot.preferences.jevModel = snapshot.preferences.jevModel ?? JevConfiguration.typeSafe.model
      }
      do {
        try writeConfig()
        log.write("信息", "配置已迁移到配置文件", configFile.url.path)
      } catch {
        self.error = "配置文件创建失败：\(error.localizedDescription)"
        log.write("错误", "配置文件创建失败", error.localizedDescription)
      }
    }
    status = alphaToken.isEmpty ? "请在 \(configFile.url.path) 或连接设置中配置 Alpha 访问令牌" : "凭据已载入"
    ensureGroupStateRefresh()
    configWatcher = ConfigWatcher(url: configFile.url) { [weak self] in self?.reloadConfig(initial: false) }
  }
  /// 读取配置文件并应用；格式错误时保留当前配置并提示，不清空密钥。
  func reloadConfig(initial: Bool) {
    guard let text = try? String(contentsOf: configFile.url, encoding: .utf8) else { return }
    let config: AppConfig
    do { config = try AppConfig.parse(text) } catch {
      self.error = "配置文件格式错误，已保留当前配置：\(error.localizedDescription)"
      log.write("警告", "配置文件格式错误", error.localizedDescription)
      return
    }
    if error?.hasPrefix("配置文件格式错误") == true { error = nil }
    guard config != lastConfig else { return }
    lastConfig = config
    let oldAlpha = alphaToken, oldPrefs = preferences, oldJev = jevKey
    alphaToken = config.alphaToken; cpaKey = config.cpaKey; jevKey = config.jevKey
    config.apply(to: &snapshot.preferences)
    save()
    if initial { return }
    log.write("信息", "配置文件已重新加载")
    if oldAlpha != alphaToken {
      groupStates.reset(account: preferences.accountID, cachedGroups: snapshot.groups)
      ensureGroupStateRefresh()
      if running { start() }
    }
    if running && (oldJev != jevKey || oldPrefs.decisionMethod != preferences.decisionMethod
      || oldPrefs.decisionThreshold != preferences.decisionThreshold
      || oldPrefs.jevConfiguration != preferences.jevConfiguration) { jevMonitor.start() }
  }
  /// 把当前密钥和偏好写回配置文件；内容未变时不写。
  func writeConfig() throws {
    let config = AppConfig(preferences: preferences, alpha: alphaToken, cpa: cpaKey, jev: jevKey)
    guard config != lastConfig else { return }
    try configFile.save(config)
    lastConfig = config
  }
  @ObservationIgnored private var pendingSave: Task<Void, Never>?
  /// 普通保存（补查进度、缓冲、偏好等）合并到 250ms 后一次写入，补查一轮从每页一次降为少数几次。
  /// 摘要结果与成功标记、已阅状态走 persistSummary / setViewed 的同步原子写入，不经过这里。
  /// 合并期间若进程崩溃，只会回到上一次一致的快照并重新补查，不会推进任何成功标记。
  func save() {
    guard persistenceHealthy, pendingSave == nil else { return }
    pendingSave = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 250_000_000)
      guard let self else { return }
      self.pendingSave = nil
      self.saveNow()
    }
  }
  /// 立即保存；退出应用时调用。
  func saveNow() {
    pendingSave?.cancel(); pendingSave = nil
    guard persistenceHealthy else { return }
    // 即使前一次待办落盘失败，之后保存偏好/缓冲时也必须带上内存中的最新任务。
    var persisted = snapshot
    persisted.summaryState = summaries.state
    if lastConfig != nil {
      do { try writeConfig() } catch {
        self.error = "配置文件保存失败：\(error.localizedDescription)"
        log.write("错误", "配置文件保存失败", error.localizedDescription)
      }
    }
    do { try disk.save(persisted) } catch {
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
    jevMonitor.stop()
    let oldKey = jevKey, oldPrefs = snapshot.preferences
    jevKey = key
    snapshot.preferences.jevBaseURL = config.baseURL
    snapshot.preferences.jevAPI = config.api
    snapshot.preferences.jevModel = config.model
    do { try writeConfig() } catch {
      jevKey = oldKey; snapshot.preferences = oldPrefs
      if running { jevMonitor.start() }
      throw error
    }
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
      alphaToken = alpha
      cpaKey = cpa
      try writeConfig()
      // 连接信息变化后，之前正在读取的响应不能覆盖新连接的状态。
      groupStates.reset(account: preferences.accountID, cachedGroups: snapshot.groups)
      ensureGroupStateRefresh()
      error = nil
      status = "连接信息已保存"
      log.write("信息", "连接配置已保存")
    } catch {
      self.error = error.localizedDescription
      log.write("错误", "连接配置保存失败")
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
        self.refreshActivity()
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
        let triggers = decision.triggersSummary(usingJev: usingJev)
        related = related || triggers
        log.localDecision(decision.message, preferences: preferences, selfID: activeAccount?.subjectID ?? "",
          match: decision.match, semantic: decision.semantic,
          action: triggers ? (usingJev && !direct ? "关键词 / 称呼命中，直接提交即时摘要；Jev 仅判断是否需回应" : "命中，本群提交一次即时摘要") : (usingJev ? "本批交给 Jev" : "无关，不触发即时摘要"),
          elapsed: Date().timeIntervalSince(started))
      }
      // 同批只产生一次群触发。已有明确本地命中时无需再等 Jev 重复触发。
      if related { enqueue(batch.scope.group) }
      if usingJev {
        // 已由本地命中提交摘要时，Jev 仍判断“是否需你回应”，但不重复提交群任务。
        let pending = decisions.filter { decision in
          if case .definite = decision.match { return false }
          return decision.message.senderID.isEmpty || decision.message.senderID != activeAccount?.subjectID
        }.map(\.message)
        if !pending.isEmpty { jevMonitor.receive(pending, scope: batch.scope, summaryTriggered: related) }
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
    refreshActivity()
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
        // 网络读取边界期间不改状态；全部读完后在一次批量中入队并只落盘一次。
        var heads: [(ConversationScope, UnreadHead?)] = [], failed: [ConversationScope] = []
        for group in groups {
          try Task.checkCancellation()
          let scope = ConversationScope(account: account, group: group.id)
          guard messageAdmission.allows(scope) else { continue }
          if group.unread == 0 { heads.append((scope, nil)); continue }
          do {
            let head = try await loader.head(scope)
            try Task.checkCancellation()
            guard generation == current else { return }
            heads.append((scope, head))
          } catch {
            try Task.checkCancellation()
            guard generation == current else { return }
            failed.append(scope)
            log.write("警告", "周期读取失败，入队复查", error.localizedDescription)
          }
        }
        summaries.batch {
          // 入队前重新校验白名单，扫描期间移出的群不入队。
          for (scope, head) in heads where self.messageAdmission.allows(scope) { self.summaries.consider(scope, head: head) }
          // 单群边界读取失败也成为可恢复任务，不影响其它群扫描。
          for scope in failed where self.messageAdmission.allows(scope) { self.summaries.enqueue(scope, trigger: .periodic) }
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
      self.summaryRequest(unread.scope, stage: input.stage)
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
      // 与新摘要同一次原子落盘：落盘失败时覆盖标记也不生效。
      DigestCoverage.apply(&candidate.digests)
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
    // 仅待办变化时界面无需刷新；有摘要结果时才发布新快照。summaryState 的权威来源是协调器。
    if completion != nil { snapshot = candidate }
    if let completion {
      lastAnalysis = Date()
      if !isQuiet {
        for item in newAttentions { notify(item) }
        if !newAttentions.isEmpty || completion.result.relevant { markAttentionArrived() }
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
    markAttentionArrived()
    if !isQuiet {
      if preferences.autoExpand { onAttention?() }
      notify(item)
    }
  }
  func readRelatedSummary(_ digest: Digest) {
    readFocusEntries([.summary(digest)])
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
