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
      var left = message, right = message
      if message.text.count > 1 {
        let middle = message.text.index(message.text.startIndex, offsetBy: message.text.count / 2)
        left.text = String(message.text[..<middle]); right.text = String(message.text[middle...])
      } else if message.text.unicodeScalars.count > 1 {
        let scalars = message.text.unicodeScalars
        let middle = scalars.index(scalars.startIndex, offsetBy: scalars.count / 2)
        left.text = String(scalars[..<middle]); right.text = String(scalars[middle...])
      } else { throw AppFailure.message("模型预算不足以容纳消息元数据或用户配置") }
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
    var notes: [SummaryNote] = []
    for batch in batches {
      try Task.checkCancellation()
      let result = try await request(input(batch, stage: "未读片段整理"), Set(batch.map(\.id)))
      try result.validate(allowedIDs: Set(batch.map(\.id)))
      notes.append(try SummaryNote(result))
    }
    // 所有分段均完成后才汇总；极长中间输出也要完整分片送入下一层，绝不 prefix 截断。
    for level in 1...12 {
      try Task.checkCancellation()
      let stage = "完整快照汇总第\(level)层"
      if try input(notes: notes.map(\.text), stage: stage).encoded().count <= budget {
        let references = Set(notes.flatMap(\.referenceIDs))
        let result = try await request(input(notes: notes.map(\.text), stage: stage), references)
        try result.validate(allowedIDs: references); try Task.checkCancellation(); return result
      }
      var pieces: [SummaryNote] = []
      func splitNote(_ note: SummaryNote) throws {
        // 每片至多使用半个净预算，使下一层有空间合并多个片段。
        let overhead = try input(notes: [], stage: stage).encoded().count
        let target = overhead + (budget - overhead) / 2
        if try input(notes: [note.text], stage: stage).encoded().count <= target { pieces.append(note); return }
        let left: SummaryNote, right: SummaryNote
        do { (left, right) = try note.split() }
        catch {
          // 一条完整 ID 可能超过半预算，仍允许它占用本层完整预算。
          if try input(notes: [note.text], stage: stage).encoded().count <= budget { pieces.append(note); return }
          throw error
        }
        try splitNote(left); try splitNote(right)
      }
      for note in notes { try splitNote(note) }
      var groups: [[SummaryNote]] = [], current: [SummaryNote] = []
      for piece in pieces {
        if !current.isEmpty, try input(notes: (current + [piece]).map(\.text), stage: stage).encoded().count > budget {
          groups.append(current); current = []
        }
        current.append(piece)
      }
      if !current.isEmpty { groups.append(current) }
      var next: [SummaryNote] = []
      for group in groups {
        try Task.checkCancellation()
        let references = Set(group.flatMap(\.referenceIDs))
        let result = try await request(input(notes: group.map(\.text), stage: stage), references)
        try result.validate(allowedIDs: references)
        next.append(try SummaryNote(result))
      }
      notes = next
    }
    throw AppFailure.message("分段汇总未能在预算内收敛，保留任务与成功标记等待重试")
  }
}

/// 引用随实际传入的整理文本流转，不能借用同一快照内尚未传入的其他消息。
private struct SummaryNote {
  let text: String
  private let referenceTokens: [String: String]
  var referenceIDs: Set<String> { Set(referenceTokens.keys) }
  init(_ result: AIResult) throws {
    text = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
    let ids = Set(result.evidenceIDs + result.judgements.map(\.messageID))
    referenceTokens = try Dictionary(uniqueKeysWithValues: ids.map { id in
      (id, String(decoding: try JSONEncoder().encode(id), as: UTF8.self))
    })
  }
  private init(text: String, referenceTokens: [String: String]) {
    self.text = text
    self.referenceTokens = referenceTokens.filter { text.contains($0.value) }
  }
  func split() throws -> (SummaryNote, SummaryNote) {
    let scalars = text.unicodeScalars
    guard scalars.count > 1 else { throw AppFailure.message("模型预算无法容纳汇总输入") }
    var middle = scalars.index(scalars.startIndex, offsetBy: scalars.count / 2)
    // 不把原始消息 ID 的 JSON 字符串拆断；只有出现完整引用的片段才能沿用该 ID。
    for token in referenceTokens.values {
      var start = text.startIndex
      while let range = text.range(of: token, range: start..<text.endIndex) {
        if range.lowerBound < middle && middle < range.upperBound {
          middle = range.lowerBound == text.startIndex ? range.upperBound : range.lowerBound
        }
        start = range.upperBound
      }
    }
    guard middle > text.startIndex, middle < text.endIndex else {
      throw AppFailure.message("模型预算无法容纳完整证据消息 ID")
    }
    return (SummaryNote(text: String(scalars[..<middle]), referenceTokens: referenceTokens),
            SummaryNote(text: String(scalars[middle...]), referenceTokens: referenceTokens))
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
