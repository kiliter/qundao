import Foundation

public struct BufferedMessage: Codable {
  public let message: Message
  public let receivedAt: Date
}
public struct RealtimeFlush {
  public let scope: ConversationScope
  public let messages: [Message]
  public let reason: String
}
public struct RealtimeBuffer: Codable {
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
public struct DecisionBatch: Codable, Identifiable {
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
