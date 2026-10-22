import Foundation

public enum RuleMatch: Equatable {
  case definite(String)
  case candidate(String)
  case none
}
public enum RuleEngine {
  public static func classify(
    _ message: Message, selfID: String, names: [String], keywords: [String]
  ) -> RuleMatch {
    if !selfID.isEmpty && message.senderID == selfID { return .none }
    if !selfID.isEmpty && message.mentions.contains(selfID) { return .definite("消息结构中明确 @ 你") }
    let broadcastIDs = Set(["notify@all", "@all", "all", "@everyone", "everyone", "所有人", "@所有人"])
    if message.mentions.contains(where: { broadcastIDs.contains($0.lowercased()) }) {
      return .definite("群体提醒：消息结构中 @所有人，包含你")
    }
    let text = message.text
    // 显式 @ 的完整对象由下面的边界规则判断，不能再把相似用户名当作普通正文称呼命中。
    let prose = text.replacingOccurrences(of: "[@＠][^\\s\\p{P}\\u2005]+", with: " ", options: .regularExpression)
    if text.range(
      of: "(?<![A-Za-z0-9_@＠])[@＠](?:所有人|全体成员|全体|全员|大家|all|everyone|here)(?![A-Za-z0-9_]|\\.[A-Za-z])",
      options: [.regularExpression, .caseInsensitive]) != nil {
      return .definite("群体提醒：文字 @所有人 / @all，包含你；按文本匹配")
    }
    for name in names.filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
      // 直接命中文本时注明依据；边界匹配避免把“小张三”当作“小张”。
      let escaped = NSRegularExpression.escapedPattern(for: name)
      if text.range(of: "[@＠]" + escaped + "(?=$|[\\s\\p{P}\\u2005])", options: [.regularExpression, .caseInsensitive])
        != nil
      {
        return .definite("文字明确 @\(name)；按你配置的称呼命中")
      }
      if text.range(
        of: "^(?:找一下|找下|找|请|麻烦)?" + escaped + "(?:[，,、：: \u{2005}]|在吗|在不在|帮忙|麻烦|请)",
        options: .regularExpression) != nil
        && ["找", "请", "麻烦", "帮忙", "确认", "看看", "回复", "在吗", "在不在"].contains(where: {
          text.contains($0)
        })
      {
        return .definite("直接点名称呼并提出请求：\(name)")
      }
      if prose.localizedCaseInsensitiveContains(name) { return .candidate("提到了你的称呼：\(name)") }
    }
    for word in keywords.filter({ !$0.isEmpty }) where text.localizedCaseInsensitiveContains(word) {
      return .candidate("涉及关注事项：\(word)")
    }
    return .none
  }
}
public struct SSEEvent: Equatable {
  public var event: String
  public var data: String
  public var id: String?
}
public struct SSEParser {
  private var event = "message"
  private var data: [String] = []
  private var id: String?
  public init() {}
  public mutating func consume(_ line: String) -> SSEEvent? {
    if line.isEmpty {
      defer {
        event = "message"
        data = []
        id = nil
      }
      return data.isEmpty ? nil : SSEEvent(event: event, data: data.joined(separator: "\n"), id: id)
    }
    if line.hasPrefix(":") { return nil }
    let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    let field = String(parts[0])
    var value = parts.count > 1 ? String(parts[1]) : ""
    if value.hasPrefix(" ") { value.removeFirst() }
    switch field {
    case "event": event = value
    case "data": data.append(value)
    case "id": id = value
    default: break
    }
    return nil
  }
}
