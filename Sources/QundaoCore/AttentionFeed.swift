import Foundation

/// 识别来源保留在内部，所有需看的内容统一进入关注列表。
public enum AttentionEntry: Identifiable {
  case response(Attention)
  case summary(Digest)

  public var id: String {
    switch self {
    case .response(let item): return "response|\(item.id)"
    case .summary(let item): return "summary|\(item.id.uuidString)"
    }
  }
  public var groupID: String {
    switch self {
    case .response(let item): return item.message.groupID
    case .summary(let item): return item.groupID
    }
  }
  public var groupName: String {
    switch self {
    case .response(let item): return item.groupName
    case .summary(let item): return item.groupName
    }
  }
  public var date: Date {
    switch self {
    case .response(let item): return item.message.date
    case .summary(let item): return item.messageDate
    }
  }
  public var preview: String {
    switch self {
    case .response(let item): return item.title
    case .summary(let item): return item.text
    }
  }
  public var isResponse: Bool {
    if case .response = self { return true }
    return false
  }
  public var isPending: Bool {
    switch self {
    case .response(let item): return item.status == "pending"
    case .summary(let item): return item.isAttentionPending
    }
  }
}

public struct AttentionThread: Identifiable {
  public let id: String
  public let entries: [AttentionEntry]
  /// 摘要条目 ID → 被该摘要证据覆盖的「找你 / 需回应」提醒，作为卡片标签显示，不单独成条。
  public var tags: [String: [Attention]] = [:]
  /// 历史开关只改变可见记录；小点始终只统计尚待关注的内容，与微信未读独立。
  public var pendingCount: Int { entries.filter(\.isPending).count }
  public func tags(for entry: AttentionEntry) -> [Attention] { tags[entry.id] ?? [] }
}

public enum AttentionFeed {
  /// 合并后的列表与标签。规则：
  /// - 被较新相关摘要完整覆盖的旧摘要（supersededBy）不进入待阅；
  /// - 提醒的消息若在某条可见摘要的证据内，并入该摘要作为标签；待阅提醒只并入待阅摘要，避免被藏起漏计。
  public static func assemble(attentions: [Attention], digests: [Digest], account: String,
                              includeHistory: Bool = false) -> (entries: [AttentionEntry], tags: [String: [Attention]]) {
    var seenDigest: Set<UUID> = [], seenResponse: Set<String> = []
    var candidates: [(digest: Digest, date: Date)] = []
    for digest in digests where digest.accountID == account && digest.related {
      guard includeHistory || digest.isAttentionPending, seenDigest.insert(digest.id).inserted else { continue }
      candidates.append((digest, digest.messageDate))
    }
    candidates.sort { (a, b) -> Bool in a.date == b.date ? a.digest.id.uuidString < b.digest.id.uuidString : a.date > b.date }
    let summaries: [Digest] = candidates.map { $0.digest }
    var responses: [Attention] = []
    for item in attentions where item.message.accountID == account {
      guard includeHistory || item.status == "pending", seenResponse.insert(item.id).inserted else { continue }
      responses.append(item)
    }
    // 证据键按需构建一次。
    var keys: [UUID: Set<String>] = [:]
    for digest in summaries { keys[digest.id] = Set(digest.evidence.map { (m: Message) in m.key }) }
    var tags: [String: [Attention]] = [:], standalone: [Attention] = []
    for response in responses {
      let host = summaries.first { digest in
        digest.groupID == response.message.groupID && keys[digest.id]?.contains(response.message.key) == true
          && (response.status != "pending" || digest.isAttentionPending)
      }
      if let host { tags["summary|\(host.id.uuidString)", default: []].append(response) }
      else { standalone.append(response) }
    }
    let keyed: [(entry: AttentionEntry, date: Date, id: String)] =
      (standalone.map(AttentionEntry.response) + summaries.map(AttentionEntry.summary)).map { ($0, $0.date, $0.id) }
    let sorted = keyed.sorted { (a, b) -> Bool in a.date == b.date ? a.id < b.id : a.date > b.date }.map(\.entry)
    for key in tags.keys { tags[key]?.sort { $0.message.timestamp > $1.message.timestamp } }
    return (sorted, tags)
  }

  public static func entries(attentions: [Attention], digests: [Digest], account: String,
                             includeHistory: Bool = false) -> [AttentionEntry] {
    assemble(attentions: attentions, digests: digests, account: account, includeHistory: includeHistory).entries
  }

  public static func threads(attentions: [Attention], digests: [Digest], account: String,
                             includeHistory: Bool = false) -> [AttentionThread] {
    let assembled = assemble(attentions: attentions, digests: digests, account: account, includeHistory: includeHistory)
    return Dictionary(grouping: assembled.entries, by: \.groupID).map { id, values in
      var tags: [String: [Attention]] = [:]
      for value in values { if let found = assembled.tags[value.id] { tags[value.id] = found } }
      return AttentionThread(id: id, entries: values, tags: tags)
    }.sorted {
      let left = $0.entries[0].date, right = $1.entries[0].date
      return left == right ? $0.id < $1.id : left > right
    }
  }
}

extension Digest {
  /// 待阅：未在群岛中已阅，且没有被更新的摘要覆盖。
  public var isAttentionPending: Bool { attentionReadAt == nil && supersededBy == nil }
}

/// 同群摘要覆盖关系。每次摘要读取该群当时全部未读，所以较新摘要的证据若完整包含旧摘要，
/// 旧摘要只是较早、较不完整的版本，不再单独待阅。只打标记不删除，历史中仍可查。
public enum DigestCoverage {
  /// 幂等：已标记的不改变；只有较新的相关摘要能覆盖；部分重叠（期间在微信读过）保持并列。
  @discardableResult
  public static func apply(_ digests: inout [Digest]) -> Int {
    var keys: [UUID: Set<String>] = [:]
    func evidence(_ digest: Digest) -> Set<String> {
      if let cached = keys[digest.id] { return cached }
      let value = Set(digest.evidence.map(\.key)); keys[digest.id] = value; return value
    }
    let scopes = Dictionary(grouping: digests.indices) { "\(digests[$0].accountID)\u{1F}\(digests[$0].groupID)" }
    var marked = 0
    for indices in scopes.values where indices.count > 1 {
      let ordered = indices.map { ($0, digests[$0].messageDate) }.sorted { $0.1 == $1.1 ? digests[$0.0].date < digests[$1.0].date : $0.1 < $1.1 }
      for (position, (index, _)) in ordered.enumerated() {
        let older = digests[index]
        guard older.related, older.supersededBy == nil, older.attentionReadAt == nil, !older.evidence.isEmpty else { continue }
        let own = evidence(older)
        // 取覆盖它的最新一条，避免链式覆盖指向中间版本。
        for (candidate, _) in ordered[(position + 1)...].reversed() {
          let newer = digests[candidate]
          guard newer.related, newer.id != older.id, newer.evidence.count >= older.evidence.count,
                own.isSubset(of: evidence(newer)) else { continue }
          digests[index].supersededBy = newer.id
          marked += 1
          break
        }
      }
    }
    return marked
  }
}
