import Foundation

extension Digest {
  /// 排序使用实际参与摘要的消息时间，不能让模型耗时改变群聊顺序。
  public var messageDate: Date { evidence.map(\.date).max() ?? date }
}

public struct SummaryThread: Identifiable {
  public let id: String
  public let digests: [Digest]
  public let unread: Int?
  public let messageDate: Date
}

public enum SummaryTimeline {
  public static func threads(digests: [Digest], groups: [ChatGroup], account: String,
                             onlyRelated: Bool = false) -> [SummaryThread] {
    let scoped = digests.filter { $0.accountID == account && (!onlyRelated || $0.related) }
    let groupIndex = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return Dictionary(grouping: scoped, by: \.groupID).map { id, values in
      // messageDate 需遍历证据，先算一次再排序，避免比较器中重复计算。
      let ordered = values.map { ($0, $0.messageDate) }.sorted {
        if $0.1 != $1.1 { return $0.1 > $1.1 }
        if $0.0.date != $1.0.date { return $0.0.date > $1.0.date }
        return $0.0.id.uuidString < $1.0.id.uuidString
      }.map(\.0)
      let group = groupIndex[id]
      let latestUnread = (group?.unread ?? 0) > 0 ? group?.lastActivityTimestamp : nil
      return SummaryThread(id: id, digests: ordered, unread: group?.unread,
        messageDate: latestUnread.map { Date(timeIntervalSince1970: Double($0) / 1000) }
          ?? ordered[0].messageDate)
    }.sorted {
      let leftUnread = ($0.unread ?? 0) > 0, rightUnread = ($1.unread ?? 0) > 0
      if leftUnread != rightUnread { return leftUnread }
      return $0.messageDate == $1.messageDate ? $0.id < $1.id : $0.messageDate > $1.messageDate
    }
  }
}

/// 点击时固定摘要与并入提醒的范围；后续动画或异步处理不能扩大已阅范围。
public struct ReadingSelection: Equatable {
  public let account: String
  public let digestIDs: Set<UUID>
  public let attentionIDs: Set<String>

  public init(entries: [AttentionEntry], attentions: [Attention], account: String) {
    self.account = account
    var digestIDs: Set<UUID> = [], attentionIDs: Set<String> = []
    for entry in entries {
      switch entry {
      case .summary(let digest) where digest.accountID == account:
        digestIDs.insert(digest.id)
        let keys = Set(digest.evidence.map(\.key))
        // 稍后提醒并未进入待阅卡片，批量已阅不能取消它的提醒时间。
        for attention in attentions where attention.status == "pending"
          && attention.message.accountID == account && attention.message.groupID == digest.groupID
          && keys.contains(attention.message.key) {
          attentionIDs.insert(attention.id)
        }
      case .response(let attention) where attention.message.accountID == account:
        attentionIDs.insert(attention.id)
      default: break
      }
    }
    self.digestIDs = digestIDs
    self.attentionIDs = attentionIDs
  }
}

extension AppSnapshot {
  /// 只更新调用时指定的本地记录。账号、摘要成功标记和 Alpha 未读数保持独立。
  public mutating func markViewed(account: String, digestIDs: Set<UUID> = [],
                                  attentionIDs: Set<String> = [], now: Date = Date()) {
    for index in digests.indices where digests[index].accountID == account && digestIDs.contains(digests[index].id) {
      if digests[index].attentionReadAt == nil { digests[index].attentionReadAt = now }
    }
    for index in attentions.indices where attentions[index].message.accountID == account && attentionIDs.contains(attentions[index].id) {
      attentions[index].status = "done"
      attentions[index].remindAt = nil
    }
  }
}
