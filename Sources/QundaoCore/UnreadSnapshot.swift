import Foundation

public struct UnreadHead: Equatable {
  public let count: Int
  public let lastID: String
  public let timestamp: Int64
  public init(count: Int, lastID: String, timestamp: Int64) {
    self.count = count; self.lastID = lastID; self.timestamp = timestamp
  }
}
public struct UnreadSnapshot {
  public let scope: ConversationScope
  public let groupName: String
  public let messages: [Message]
  public let capturedAt: Date
  public init(scope: ConversationScope, groupName: String, messages: [Message], capturedAt: Date = Date()) {
    self.scope = scope; self.groupName = groupName; self.messages = messages; self.capturedAt = capturedAt
  }
}
public struct MessagePage {
  public let messages: [Message]
  public let cursor: String?
  public init(messages: [Message], cursor: String?) { self.messages = messages; self.cursor = cursor }
}
public protocol UnreadSource {
  func unreadGroup(_ scope: ConversationScope) async throws -> ChatGroup
  func unreadPage(_ scope: ConversationScope, before: Int64?, cursor: String?, limit: Int) async throws -> MessagePage
}

/// Alpha 暂无原子未读快照接口。以未读数量和末条双重校验固定边界，游标分页读取；
/// 读取期间已读位置或末条变化时重取，不能把部分页提交为成功摘要。
public struct UnreadSnapshotLoader {
  public let source: any UnreadSource
  public init(source: any UnreadSource) { self.source = source }
  public func head(_ scope: ConversationScope) async throws -> UnreadHead? {
    for _ in 0..<3 {
      try Task.checkCancellation()
      let group = try await source.unreadGroup(scope)
      if group.unread == 0 { return nil }
      let page = try await source.unreadPage(scope, before: nil, cursor: nil, limit: 1)
      let after = try await source.unreadGroup(scope)
      guard group.unread == after.unread else { continue }
      guard let last = page.messages.first else { throw AppFailure.message("Alpha 有未读但没有返回末条消息") }
      return UnreadHead(count: group.unread, lastID: last.id, timestamp: last.timestamp)
    }
    throw AppFailure.message("未读边界持续变化，等待重新读取")
  }
  public func load(_ scope: ConversationScope) async throws -> UnreadSnapshot {
    for _ in 0..<3 {
      try Task.checkCancellation()
      guard let initial = try await head(scope) else {
        return UnreadSnapshot(scope: scope, groupName: scope.group, messages: [])
      }
      var messages: [Message] = [], seen = Set<String>(), cursors = Set<String>(), cursor: String?
      // 毫秒上界固定在末条 + 1，同毫秒的先后顺序交给 Alpha 游标，不用时间戳代替消息 ID。
      let upper = initial.timestamp == Int64.max ? initial.timestamp : initial.timestamp + 1
      var boundaryChanged = false
      repeat {
        try Task.checkCancellation()
        let page = try await source.unreadPage(scope, before: upper, cursor: cursor,
                                               limit: min(200, initial.count - messages.count))
        if messages.isEmpty, page.messages.first?.id != initial.lastID { boundaryChanged = true; break }
        let previousCount = messages.count
        for message in page.messages {
          guard message.accountID == scope.account, message.groupID == scope.group,
                message.timestamp < upper else { throw AppFailure.message("Alpha 分页返回了范围外消息") }
          if seen.insert(message.id).inserted { messages.append(message) }
        }
        guard messages.count <= initial.count else { throw AppFailure.message("Alpha 分页超出请求范围") }
        if messages.count == initial.count { break }
        guard messages.count > previousCount, let next = page.cursor, cursors.insert(next).inserted else {
          throw AppFailure.message("未读分页不完整或游标未推进，保留任务重试")
        }
        cursor = next
      } while messages.count < initial.count
      if boundaryChanged { continue }
      let ending = try await head(scope)
      guard ending == initial else { continue }
      let group = try await source.unreadGroup(scope)
      guard group.unread == initial.count else { continue }
      // 直接反转服务端的降序序列，保留同一时间戳下的稳定先后顺序。
      return UnreadSnapshot(scope: scope, groupName: group.name, messages: messages.reversed())
    }
    throw AppFailure.message("读取期间未读范围发生变化，未提交部分摘要，稍后重试")
  }
}

extension AlphaClient: UnreadSource {
  public func unreadGroup(_ scope: ConversationScope) async throws -> ChatGroup {
    guard let group = try await groups(account: scope.account).first(where: { $0.id == scope.group }) else {
      throw AppFailure.message("Alpha 未返回该群会话，保留任务重试")
    }
    return group
  }
  public func unreadPage(_ scope: ConversationScope, before: Int64?, cursor: String?, limit: Int) async throws -> MessagePage {
    let page = try await messages(account: scope.account, group: scope.group, after: nil, before: before,
                                  cursor: cursor, limit: limit, order: "desc")
    return MessagePage(messages: page.messages, cursor: page.cursor)
  }
}
