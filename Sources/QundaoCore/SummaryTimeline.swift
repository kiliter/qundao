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
    return Dictionary(grouping: scoped, by: \.groupID).map { id, values in
      let ordered = values.sorted {
        if $0.messageDate != $1.messageDate { return $0.messageDate > $1.messageDate }
        if $0.date != $1.date { return $0.date > $1.date }
        return $0.id.uuidString < $1.id.uuidString
      }
      let group = groups.first { $0.id == id }
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
