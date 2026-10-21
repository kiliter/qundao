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
    case .summary(let item): return item.attentionReadAt == nil
    }
  }
}

public struct AttentionThread: Identifiable {
  public let id: String
  public let entries: [AttentionEntry]
  /// 历史开关只改变可见记录；小点始终只统计尚待关注的内容，与微信未读独立。
  public var pendingCount: Int { entries.filter(\.isPending).count }
}

public enum AttentionFeed {
  public static func entries(attentions: [Attention], digests: [Digest], account: String,
                             includeHistory: Bool = false) -> [AttentionEntry] {
    let responses = attentions.filter {
      $0.message.accountID == account
    }.map(AttentionEntry.response)
    let summaries = digests.filter {
      $0.accountID == account && $0.related
    }.map(AttentionEntry.summary)
    var seen: Set<String> = []
    return (responses + summaries).filter { includeHistory || $0.isPending }.sorted {
      $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date
    }.filter { seen.insert($0.id).inserted }
  }

  public static func threads(attentions: [Attention], digests: [Digest], account: String,
                             includeHistory: Bool = false) -> [AttentionThread] {
    let visible = entries(attentions: attentions, digests: digests, account: account,
                          includeHistory: includeHistory)
    return Dictionary(grouping: visible, by: \.groupID).map { id, values in
      AttentionThread(id: id, entries: values)
    }.sorted {
      let left = $0.entries[0].date, right = $1.entries[0].date
      return left == right ? $0.id < $1.id : left > right
    }
  }
}
