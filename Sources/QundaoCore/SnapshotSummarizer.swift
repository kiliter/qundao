import Foundation

/// 分段和汇总都使用同一实际序列化格式计算预算，日志记录的也是这份模型输入。
public struct SummaryModelInput {
  public let messages: [Message]
  public let notes: [String]
  public let names: [String]
  public let keywords: [String]
  public let selfID: String
  public let stage: String
  public init(messages: [Message] = [], notes: [String] = [], names: [String], keywords: [String], selfID: String, stage: String) {
    self.messages = messages; self.notes = notes; self.names = names; self.keywords = keywords; self.selfID = selfID; self.stage = stage
  }
  public func encoded() throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "阶段": stage, "我的账号": selfID, "我的称呼": names, "关注事项": keywords,
      "未读消息": messages.map { ["id": $0.id, "sender_id": $0.senderID, "sender": $0.sender,
        "text": $0.text, "time": $0.timestamp, "mentions": $0.mentions] as [String: Any] },
      "分段整理": notes
    ], options: [.sortedKeys])
  }
}
public struct SnapshotSummarizer {
  public let budget: Int
  public let names: [String]
  public let keywords: [String]
  public let selfID: String
  public init(budget: Int, names: [String], keywords: [String], selfID: String) {
    self.budget = budget; self.names = names; self.keywords = keywords; self.selfID = selfID
  }
  private func input(_ messages: [Message] = [], notes: [String] = [], stage: String) -> SummaryModelInput {
    SummaryModelInput(messages: messages, notes: notes, names: names, keywords: keywords, selfID: selfID, stage: stage)
  }
  public func run(_ messages: [Message], request: (SummaryModelInput, Set<String>) async throws -> AIResult) async throws -> AIResult {
    guard !messages.isEmpty else { throw AppFailure.message("不能摘要空的未读快照") }
    let ids = Set(messages.map(\.id))
    let whole = input(messages, stage: "完整未读摘要")
    if try whole.encoded().count <= budget {
      let result = try await request(whole, ids)
      try result.validate(allowedIDs: ids); try Task.checkCancellation(); return result
    }
    // 长消息按字符边界拆分，ID 保持原消息身份；不丢字符、不排除旧未读。
    var fragments: [Message] = []
    func split(_ message: Message) throws {
      if try input([message], stage: "未读片段整理").encoded().count <= budget { fragments.append(message); return }
      guard message.text.count > 1 else { throw AppFailure.message("模型预算不足以容纳消息元数据或用户配置") }
      let middle = message.text.index(message.text.startIndex, offsetBy: message.text.count / 2)
      var left = message, right = message
      left.text = String(message.text[..<middle]); right.text = String(message.text[middle...])
      try split(left); try split(right)
    }
    for message in messages { try split(message) }
    var batches: [[Message]] = [], batch: [Message] = []
    for fragment in fragments {
      if !batch.isEmpty, try input(batch + [fragment], stage: "未读片段整理").encoded().count > budget {
        batches.append(batch); batch = []
      }
      batch.append(fragment)
    }
    if !batch.isEmpty { batches.append(batch) }
    var notes: [String] = []
    for batch in batches {
      try Task.checkCancellation()
      let result = try await request(input(batch, stage: "未读片段整理"), Set(batch.map(\.id)))
      try result.validate(allowedIDs: Set(batch.map(\.id)))
      notes.append(String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
    }
    // 所有分段均完成后才汇总；极长中间输出也要完整分片送入下一层，绝不 prefix 截断。
    for level in 1...12 {
      try Task.checkCancellation()
      let stage = "完整快照汇总第\(level)层"
      if try input(notes: notes, stage: stage).encoded().count <= budget {
        let result = try await request(input(notes: notes, stage: stage), ids)
        try result.validate(allowedIDs: ids); try Task.checkCancellation(); return result
      }
      var pieces: [String] = []
      func splitNote(_ text: String) throws {
        // 每片至多使用半个净预算，使下一层有空间合并多个片段。
        let overhead = try input(notes: [], stage: stage).encoded().count
        let target = overhead + (budget - overhead) / 2
        if try input(notes: [text], stage: stage).encoded().count <= target { pieces.append(text); return }
        guard text.count > 1 else { throw AppFailure.message("模型预算无法容纳汇总输入") }
        let middle = text.index(text.startIndex, offsetBy: text.count / 2)
        try splitNote(String(text[..<middle])); try splitNote(String(text[middle...]))
      }
      for note in notes { try splitNote(note) }
      var groups: [[String]] = [], current: [String] = []
      for piece in pieces {
        if !current.isEmpty, try input(notes: current + [piece], stage: stage).encoded().count > budget {
          groups.append(current); current = []
        }
        current.append(piece)
      }
      if !current.isEmpty { groups.append(current) }
      var next: [String] = []
      for group in groups {
        try Task.checkCancellation()
        let result = try await request(input(notes: group, stage: stage), ids)
        try result.validate(allowedIDs: ids)
        next.append(String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
      }
      notes = next
    }
    throw AppFailure.message("分段汇总未能在预算内收敛，保留任务与成功标记等待重试")
  }
}

extension AIResult {
  public func validate(allowedIDs: Set<String>) throws {
    guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !relevant || !evidenceIDs.isEmpty,
          evidenceIDs.allSatisfy({ allowedIDs.contains($0) }),
          relevant || !judgements.contains(where: { $0.needsResponse }),
          judgements.allSatisfy({ allowedIDs.contains($0.messageID) && ["high", "medium", "low"].contains($0.confidence) }) else {
      throw AppFailure.message("模型输出格式或证据引用无效，未推进成功标记")
    }
  }
}
