import Foundation

/// 所有消息处理共用的边界：当前账号、真实群标识、显式白名单缺一不可。
public struct MessageAdmission {
  public let account: String
  public let groups: Set<String>
  public init(account: String, groups: Set<String>) { self.account = account; self.groups = groups }
  public func allows(account: String, group: String) -> Bool {
    !self.account.isEmpty && account == self.account && group.hasSuffix("@chatroom") && groups.contains(group)
  }
  public func allows(_ message: Message) -> Bool { allows(account: message.accountID, group: message.groupID) }
  public func allows(_ scope: ConversationScope) -> Bool { allows(account: scope.account, group: scope.group) }
}

extension AppSnapshot {
  /// 在去重、缓存、缓冲之前过滤。拒绝消息不会改变任何持久化字段。
  @discardableResult public mutating func ingestRealtime(_ incoming: [Message], admission: MessageAdmission,
                                                         selfID: String, now: Date = Date()) -> Int {
    var added = 0
    for message in incoming.filter(admission.allows).sorted(by: { $0.timestamp < $1.timestamp }) {
      if seen.contains(message.key) {
        if !message.senderID.isEmpty, let index = messages.firstIndex(where: { $0.key == message.key }),
           messages[index].senderID.isEmpty {
          messages[index] = messages[index].fillingSender(from: message)
          realtimeBuffer?.enrichSender(message)
          for batchIndex in decisionBatches?.indices ?? 0..<0 {
            let enriched = decisionBatches?[batchIndex].messages.map {
              $0.fillingSender(from: message)
            } ?? []
            decisionBatches?[batchIndex].messages = enriched
          }
          if !selfID.isEmpty && message.senderID == selfID { attentions.removeAll { $0.id == message.key } }
        }
        continue
      }
      seen.insert(message.key)
      messages.append(message)
      if realtimeBuffer == nil { realtimeBuffer = RealtimeBuffer() }
      realtimeBuffer?.receive(message, now: now)
      added += 1
    }
    return added
  }

  /// 清理当前账号范围外的处理缓存；既有摘要和历史日志不作为待处理消息重放。
  public mutating func discardExcludedProcessing(admission: MessageAdmission) {
    func retain(_ account: String, _ group: String) -> Bool {
      group.hasSuffix("@chatroom") && (account != admission.account || admission.allows(account: account, group: group))
    }
    let excluded = Set(messages.filter { !retain($0.accountID, $0.groupID) }.map(\.key))
    messages.removeAll { !retain($0.accountID, $0.groupID) }
    seen.subtract(excluded); analyzed.subtract(excluded); pendingAI.subtract(excluded)
    pendingJev?.subtract(excluded); pendingPeriodic?.subtract(excluded)
    realtimeBuffer?.retain(admission: admission)
    decisionBatches = decisionBatches?.filter { batch in
      retain(batch.scope.account, batch.scope.group) && batch.messages.allSatisfy {
        $0.accountID == batch.scope.account && $0.groupID == batch.scope.group
      }
    }
    checkpoints = checkpoints.filter { key, _ in
      let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
      return parts.count == 2 && retain(parts[0], parts[1])
    }
    let jobs = summaryState?.jobs.filter { retain($0.value.scope.account, $0.value.scope.group) } ?? [:]
    summaryState?.jobs = jobs
  }

  public mutating func migrateAlphaREST() {
    guard alphaRESTVersion != 1 else { return }
    // 旧 MCP 游标不能用于 REST offset；重新补查后由消息 ID 去重，成功摘要标记不变。
    checkpoints = [:]
    alphaRESTVersion = 1
  }
}

extension Message {
  /// REST 补齐 SSE 未提供的发送者身份，不改写正文、时间或已经确认的身份。
  func fillingSender(from incoming: Message) -> Message {
    guard key == incoming.key else { return self }
    var enriched = self
    if enriched.senderID.isEmpty { enriched.senderID = incoming.senderID }
    if enriched.sender.isEmpty { enriched.sender = incoming.sender }
    return enriched
  }
}
