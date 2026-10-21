import Foundation

public enum ConversationMessages {
  /// 摘要证据独立留存；即使原始缓存被清理，仍能打开该批原文。
  public static func collect(cached: [Message], digests: [Digest], account: String, group: String) -> [Message] {
    var unique: [String: Message] = [:]
    for message in digests.filter({ $0.accountID == account && $0.groupID == group }).flatMap(\.evidence) + cached {
      guard message.accountID == account, message.groupID == group else { continue }
      unique[message.key] = message
    }
    return unique.values.sorted {
      $0.timestamp == $1.timestamp ? $0.key < $1.key : $0.timestamp < $1.timestamp
    }
  }
}
