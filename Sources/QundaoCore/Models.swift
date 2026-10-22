import Foundation

public struct Account: Identifiable, Codable, Hashable {
  public var id: String
  public var name: String
  public var subjectID: String
  public init(id: String, name: String, subjectID: String) {
    self.id = id
    self.name = name
    self.subjectID = subjectID
  }
}
public struct ChatGroup: Identifiable, Codable, Hashable {
  public var id: String
  public var name: String
  public var unread: Int
  public var lastActivityTimestamp: Int64?
  public init(id: String, name: String, unread: Int, lastActivityTimestamp: Int64? = nil) {
    self.id = id
    self.name = name
    self.unread = unread
    self.lastActivityTimestamp = lastActivityTimestamp
  }
}
public struct Message: Identifiable, Codable, Hashable {
  public var id: String
  public var accountID: String
  public var groupID: String
  public var senderID: String
  public var sender: String
  public var text: String
  public var timestamp: Int64
  public var mentions: [String]
  public init(
    id: String, accountID: String, groupID: String, senderID: String, sender: String, text: String,
    timestamp: Int64, mentions: [String] = []
  ) {
    self.id = id
    self.accountID = accountID
    self.groupID = groupID
    self.senderID = senderID
    self.sender = sender
    self.text = text
    self.timestamp = timestamp
    self.mentions = mentions
  }
  public var key: String { "\(accountID)|\(groupID)|\(id)" }
  public var date: Date { Date(timeIntervalSince1970: Double(timestamp) / 1000) }
}
public struct Attention: Identifiable, Codable, Equatable {
  public var id: String
  public var message: Message
  public var groupName: String
  public var title: String
  public var reason: String
  public var definite: Bool
  public var status: String
  public var remindAt: Date?
  public init(message: Message, groupName: String, title: String, reason: String, definite: Bool) {
    self.id = message.key
    self.message = message
    self.groupName = groupName
    self.title = title
    self.reason = reason
    self.definite = definite
    self.status = "pending"
  }
}
public struct Digest: Identifiable, Codable, Equatable {
  public var id: UUID = UUID()
  public var accountID: String
  public var groupID: String
  public var groupName: String
  public var date: Date = Date()
  public var related: Bool
  public var relevanceReason: String
  public var text: String
  public var count: Int
  public var evidence: [Message]
  /// 仅表示在群岛中已阅相关摘要，与 Alpha / 微信的消息已读状态相互独立。
  /// 可选字段让旧版本保存的相关摘要直接进入待关注列表。
  public var attentionReadAt: Date?
  /// 被同群较新且证据完整包含本摘要的相关摘要覆盖（其 ID）；可选字段兼容旧数据。
  /// 覆盖后不再待阅，也不计入小点，历史中保留。
  public var supersededBy: UUID?
  public init(
    accountID: String, groupID: String, groupName: String, text: String, count: Int,
    evidence: [Message], related: Bool, relevanceReason: String
  ) {
    self.related = related
    self.relevanceReason = relevanceReason
    self.accountID = accountID
    self.groupID = groupID
    self.groupName = groupName
    self.text = text
    self.count = count
    self.evidence = evidence
  }
}
public struct Preferences: Codable, Equatable {
  public var accountID = ""
  public var selectedGroups: Set<String> = []
  public var groupsInitialized = false
  public var semanticEnabled = true
  public var names: [String] = []
  public var keywords: [String] = []
  public var model = ""
  public var reasoning = "low"
  public var intervalMinutes = 15
  public var aiEnabled = true
  public var immediateMentions = true
  public var notifications = false
  public var hideNotificationText = true
  public var hover = true
  public var autoExpand = true
  public var dndUntil: Date?
  public var autoStart = false
  // 可选字段保证旧版状态可以直接读取；宽度为空时使用适配屏幕的默认值。
  public var whitelistVersion: Int? = 2
  public var previousSelectedGroups: Set<String>?
  public var notchCompactWidth: Double?
  public var notchExpandedWidth: Double?
  public var summaryConcurrency: Int?
  public var realtimeCapacity: Int?
  public var realtimeFlushSeconds: Double?
  public var concurrentSummaries: Int { min(8, max(1, summaryConcurrency ?? 3)) }
  public var bufferCapacity: Int { min(500, max(1, realtimeCapacity ?? 30)) }
  public var bufferInterval: Double { min(30, max(0.5, realtimeFlushSeconds ?? 3)) }
  public var decisionMethod: String?
  public var jevModel: String?
  public var jevBaseURL: String?
  public var jevAPI: JevAPI?
  public var jevThreshold: Double?
  public var jevConfiguration: JevConfiguration {
    let preset: JevConfiguration = jevBaseURL == nil && jevModel != nil ? .typeSafe : .openRouter
    return JevConfiguration(baseURL: jevBaseURL ?? preset.baseURL, api: jevAPI ?? preset.api,
                            model: jevModel ?? preset.model)
  }
  public var usesJev: Bool { decisionMethod == "jev" }
  public var decisionThreshold: Double { min(0.95, max(0.5, jevThreshold ?? 0.75)) }
  public init() {}
}
public struct Checkpoint: Codable, Equatable {
  public var after: Int64
  public var cursor: String?
  public var upper: Int64?
  public var baseline: Bool = false
  public var remaining: Int?
  public init(
    after: Int64, cursor: String? = nil, upper: Int64? = nil, baseline: Bool = false,
    remaining: Int? = nil
  ) {
    self.after = after
    self.cursor = cursor
    self.upper = upper
    self.baseline = baseline
    self.remaining = remaining
  }
}
public struct AppSnapshot: Codable {
  public var preferences = Preferences()
  public var groups: [ChatGroup] = []
  public var messages: [Message] = []
  public var attentions: [Attention] = []
  public var digests: [Digest] = []
  public var checkpoints: [String: Checkpoint] = [:]
  public var analyzed: Set<String> = []
  public var seen: Set<String> = []
  public var pendingAI: Set<String> = []
  public var pendingJev: Set<String>?
  public var pendingPeriodic: Set<String>?
  public var summaryState: SummaryState?
  public var realtimeBuffer: RealtimeBuffer?
  public var decisionBatches: [DecisionBatch]?
  public var alphaRESTVersion: Int?
  public init() {}
  /// 补算同群摘要覆盖关系；幂等，返回本次新标记数。只打标记，不删除摘要或日志。
  @discardableResult public mutating func migrateDigestCoverage() -> Int { DigestCoverage.apply(&digests) }
  public mutating func migrateSummaryWorkflow() {
    guard summaryState == nil else { return }
    var state = SummaryState()
    var decisions: [ConversationScope: [Message]] = [:]
    for message in messages {
      let scope = ConversationScope(account: message.accountID, group: message.groupID)
      for trigger in [SummaryTrigger.immediate, .periodic] {
        let pending = trigger == .immediate ? pendingAI : (pendingPeriodic ?? [])
        if pending.contains(message.key) {
          if state.jobs[scope.key] == nil { state.jobs[scope.key] = SummaryJob(scope: scope, trigger: trigger) }
          else { state.jobs[scope.key]?.sources.insert(trigger) }
        }
      }
      if pendingJev?.contains(message.key) == true { decisions[scope, default: []].append(message) }
    }
    summaryState = state
    decisionBatches = decisions.map { DecisionBatch(scope: $0.key, messages: $0.value) }
    realtimeBuffer = RealtimeBuffer()
    pendingAI = []; pendingPeriodic = []; pendingJev = []
  }
  /// 旧版自动选择的范围无法与手动选择区分，保留备份后迁移到显式白名单。
  @discardableResult public mutating func migrateWhitelist() -> Bool {
    guard (preferences.whitelistVersion ?? 0) < 2 else { return false }
    preferences.previousSelectedGroups = preferences.selectedGroups
    preferences.selectedGroups = []
    preferences.whitelistVersion = 2
    return true
  }
}
public enum AppFailure: LocalizedError {
  case message(String)
  public var errorDescription: String? {
    if case .message(let text) = self { return text }
    return nil
  }
}
extension Dictionary where Key == String, Value == Any {
  public func string(_ key: String) -> String {
    if let s = self[key] as? String { return s }
    if let n = self[key] as? NSNumber { return n.stringValue }
    return ""
  }
  public func int(_ key: String) -> Int { (self[key] as? Int) ?? Int(string(key)) ?? 0 }
}
