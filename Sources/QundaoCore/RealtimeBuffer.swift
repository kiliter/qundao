import Foundation

public struct BufferedMessage: Codable, Equatable {
  public let message: Message
  public let receivedAt: Date
}
public struct RealtimeFlush {
  public let scope: ConversationScope
  public let messages: [Message]
  public let reason: String
}
public struct RealtimeBuffer: Codable, Equatable {
  public private(set) var entries: [String: BufferedMessage] = [:]
  public init() {}
  public mutating func receive(_ message: Message, now: Date = Date()) {
    if entries[message.key] == nil { entries[message.key] = BufferedMessage(message: message, receivedAt: now) }
  }
  public mutating func discard(account: String, groups: Set<String>) {
    entries = entries.filter { $0.value.message.accountID != account || !groups.contains($0.value.message.groupID) }
  }
  public mutating func retain(admission: MessageAdmission) {
    entries = entries.filter {
      let message = $0.value.message
      return message.groupID.hasSuffix("@chatroom") && (message.accountID != admission.account || admission.allows(message))
    }
  }
  public mutating func flush(account: String, capacity: Int, interval: TimeInterval, now: Date = Date()) -> [RealtimeFlush] {
    let current = entries.values.filter { $0.message.accountID == account }
    let full = current.count >= max(1, capacity)
    let groups = Dictionary(grouping: current) { ConversationScope(account: $0.message.accountID, group: $0.message.groupID) }
    var result: [RealtimeFlush] = []
    for (scope, values) in groups {
      // 使用首条到达时间；新消息不会移动截止时间。
      guard full || now.timeIntervalSince(values.map(\.receivedAt).min()!) >= max(0.1, interval) else { continue }
      let messages = values.sorted {
        $0.receivedAt == $1.receivedAt ? $0.message.timestamp < $1.message.timestamp : $0.receivedAt < $1.receivedAt
      }.map(\.message)
      result.append(RealtimeFlush(scope: scope, messages: messages, reason: full ? "容量阈值" : "首条消息等待到期"))
      for message in messages { entries[message.key] = nil }
    }
    return result
  }
}
public struct DecisionBatch: Codable, Identifiable, Equatable {
  public var id = UUID()
  public var scope: ConversationScope
  public var messages: [Message]
  public var retryAt = Date()
  public var attempts = 0
  public var fallbackTriggered = false
  public init(scope: ConversationScope, messages: [Message]) { self.scope = scope; self.messages = messages }
}

public struct LocalDecision {
  public let message: Message
  public let match: RuleMatch
  public let semantic: Bool
  public var related: Bool { match != .none || semantic }
  /// 正文直接命中称呼或关注关键词（含明确 @）属于用户配置的确定信号，任何判断方式下都直接提交摘要；
  /// 系统语义近似只是候选，启用 Jev 时交给 Jev 判断。
  public func triggersSummary(usingJev: Bool) -> Bool { match != .none || (!usingJev && semantic) }
}
public enum RealtimeDecision {
  public static func local(_ messages: [Message], preferences: Preferences, selfID: String,
                           semantic: (String) -> Bool = { _ in false }) -> [LocalDecision] {
    messages.map { message in
      let match = RuleEngine.classify(message, selfID: selfID, names: preferences.names, keywords: preferences.keywords)
      let own = !message.senderID.isEmpty && message.senderID == selfID
      return LocalDecision(message: message, match: match,
                           semantic: !own && match == .none && preferences.semanticEnabled && semantic(message.text))
    }
  }
}
/// 缓冲区当前账号的只读概况，用于界面显示等待时间；不改变缓冲内容。
public struct BufferStatus: Equatable {
  public struct Group: Equatable {
    public let group: String
    public let count: Int
    /// 首条到达时间 + 等待间隔；新消息不会移动截止时间。
    public let deadline: Date
  }
  public let count: Int
  public let capacity: Int
  public let groups: [Group]
  /// 最早到期的群；容量已满时下一轮立即提交。
  public var deadline: Date? { groups.map(\.deadline).min() }
  public var isEmpty: Bool { count == 0 }
  public static let empty = BufferStatus(count: 0, capacity: 1, groups: [])
}
extension RealtimeBuffer {
  public func status(account: String, capacity: Int, interval: TimeInterval) -> BufferStatus {
    let current = entries.values.filter { $0.message.accountID == account }
    guard !current.isEmpty else { return BufferStatus(count: 0, capacity: max(1, capacity), groups: []) }
    let wait: TimeInterval = max(0.1, interval)
    var first: [String: Date] = [:], counts: [String: Int] = [:]
    for entry in current {
      let id = entry.message.groupID
      counts[id, default: 0] += 1
      if let old = first[id], old <= entry.receivedAt { continue }
      first[id] = entry.receivedAt
    }
    var groups: [BufferStatus.Group] = []
    for (id, start) in first {
      groups.append(BufferStatus.Group(group: id, count: counts[id] ?? 0, deadline: start.addingTimeInterval(wait)))
    }
    groups.sort { $0.deadline == $1.deadline ? $0.group < $1.group : $0.deadline < $1.deadline }
    return BufferStatus(count: current.count, capacity: max(1, capacity), groups: groups)
  }
}
