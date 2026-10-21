import Foundation

public enum PushMessage {
  public static func decode(_ data: Data, account: String, allowedGroups: Set<String>? = nil) -> Message? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    let row = (root["message"] as? [String: Any]) ?? root
    let accountID = root.string("accountId").isEmpty ? account : root.string("accountId")
    guard accountID == account else { return nil }
    func value(_ keys: [String]) -> String {
      for key in keys {
        let s = row.string(key)
        if !s.isEmpty { return s }
        let r = root.string(key)
        if !r.isEmpty { return r }
      }
      return ""
    }
    let group = value([
      "sessionId", "session_id", "conversationId", "conversation_id", "talker", "username",
    ])
    // 先识别会话，不提取正文；私聊及白名单外群聊不能进入后续缓存、判断或日志。
    guard group.hasSuffix("@chatroom"), allowedGroups == nil || allowedGroups!.contains(group) else { return nil }
    let kind = value(["sessionType", "session_type"])
    guard kind.isEmpty || kind == "group" || kind == "2" else { return nil }
    let id = value(["rawid", "server_id", "id", "messageId", "message_id"])
    guard !group.isEmpty, !id.isEmpty, id != "0",
      let rawTimestamp = Int64(
        value([
          "sent_at_unix_ms", "timestampUnixMs", "timestamp_unix_ms", "createTimeMs", "timestamp",
        ])), rawTimestamp > 0
    else { return nil }
    let timestamp = rawTimestamp < 10_000_000_000 ? rawTimestamp * 1000 : rawTimestamp
    return Message(
      id: id, accountID: accountID, groupID: group,
      senderID: value(["sender_id", "senderId", "senderUsername"]),
      sender: value(["sourceName", "sender", "senderName", "sender_name"]),
      text: value(["text", "content", "plainText"]), timestamp: timestamp,
      mentions: row["mention_usernames"] as? [String] ?? row["mentions"] as? [String] ?? [])
  }
}
