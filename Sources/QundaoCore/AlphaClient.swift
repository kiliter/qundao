import Foundation

/// Alpha 固定 REST 接口；不使用 MCP，也不在请求 URL 中携带令牌。
public struct AlphaClient {
  public let token: String
  private let session: URLSession
  public init(token: String, session: URLSession = .shared) { self.token = token; self.session = session }

  private func get(_ path: String, query: [String: String] = [:]) async throws -> [String: Any] {
    var url = URLComponents(string: "http://127.0.0.1:9527\(path)")!
    url.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
    var request = URLRequest(url: url.url!, cachePolicy: .reloadIgnoringLocalCacheData)
    request.timeoutInterval = 150
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      // 不把服务端原始错误正文写入日志，避免夹带聊天原文或鉴权信息。
      throw AppFailure.message("Alpha REST 请求失败（\((response as? HTTPURLResponse)?.statusCode ?? 0)）：\(path)")
    }
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          value["error"] == nil, value["success"] as? Bool != false,
          value["status"] as? String == "ok" else {
      throw AppFailure.message("Alpha REST 返回无效状态：\(path)")
    }
    return value
  }

  public func accounts() async throws -> [Account] {
    let data = try await get("/api/v1/accounts")
    guard let accounts = data["accounts"] as? [[String: Any]] else { throw AppFailure.message("Alpha REST 缺少账号列表") }
    return try accounts.filter { $0["usable"] as? Bool != false }.map {
      guard !$0.string("id").isEmpty else { throw AppFailure.message("Alpha REST 账号标识缺失") }
      return Account(id: $0.string("id"), name: $0.string("display_name"), subjectID: $0.string("subject_id"))
    }
  }

  public func groups(account: String) async throws -> [ChatGroup] {
    var groups: [ChatGroup] = [], seen: Set<String> = []
    var offset = 0
    while offset < 50_000 {
      try Task.checkCancellation()
      let data = try await get("/api/v1/sessions", query: ["account": account, "limit": "200", "offset": "\(offset)"])
      guard data.string("account_id") == account, let page = data["items"] as? [[String: Any]],
            data["scanComplete"] as? Bool != false else {
        throw AppFailure.message("Alpha REST 会话账号不匹配或分页不完整")
      }
      for row in page where row.string("id").hasSuffix("@chatroom") {
        guard let unread = Self.integer(row["unread_count"]), unread >= 0 else {
          throw AppFailure.message("Alpha 群会话缺少有效未读数，保留上次状态")
        }
        let id = row.string("id")
        guard seen.insert(id).inserted else { throw AppFailure.message("Alpha REST 会话分页重复，保留上次状态") }
        groups.append(ChatGroup(id: id, name: row.string("display_name"), unread: unread,
                                lastActivityTimestamp: Int64(row.string("last_activity_unix_ms"))))
      }
      guard let next = try Self.nextOffset(data, offset: offset, pageCount: page.count) else { return groups }
      offset = next
    }
    throw AppFailure.message("会话数量超过本次读取上限")
  }

  public func messages(account: String, group: String, after: Int64?, before: Int64?, cursor: String?,
                       limit: Int = 200, order: String = "asc") async throws -> (messages: [Message], cursor: String?) {
    guard group.hasSuffix("@chatroom"), ["asc", "desc"].contains(order), limit > 0, limit <= 200,
          after == nil || after! >= 0, before == nil || before! > 0 else {
      throw AppFailure.message("Alpha REST 消息查询范围无效")
    }
    var position = RESTMessagePosition(account: account, group: group, after: after, before: before, order: order)
    if let cursor {
      guard let saved = RESTMessagePosition.decode(cursor), saved.sameRange(as: position), saved.offset > 0 else {
        throw AppFailure.message("Alpha REST 分页游标与查询范围不匹配")
      }
      position = saved
    }
    // REST 时间参数为包含边界的 Unix 秒。扩大到整秒读取，再按调用方的毫秒范围精确过滤。
    for _ in 0..<250 {
      try Task.checkCancellation()
      var query = ["account": account, "username": group, "limit": "\(limit)", "offset": "\(position.offset)", "order": order]
      if let after { query["start"] = "\(after / 1000)" }
      if let before { query["end"] = "\((before - 1) / 1000)" }
      let data = try await get("/api/v1/messages", query: query)
      guard data.string("account_id") == account, data.string("talker") == group,
            let page = data["messages"] as? [[String: Any]], data["scanComplete"] as? Bool != false else {
        throw AppFailure.message("Alpha REST 消息账号、群聊不匹配或分页不完整")
      }
      let messages = try page.map { row -> Message in
        let serverID = row.string("server_id")
        let id = serverID.isEmpty || serverID == "0" ? row.string("id") : serverID
        guard !id.isEmpty, row.string("conversation_id") == group,
              let timestamp = Int64(row.string("sent_at_unix_ms")), timestamp > 0 else {
          throw AppFailure.message("Alpha REST 消息字段不完整，保留进度等待重试")
        }
        return Message(id: id, accountID: account, groupID: group, senderID: row.string("sender_id"),
                       sender: row.string("sender_name"), text: row.string("text"), timestamp: timestamp,
                       mentions: row["mention_usernames"] as? [String] ?? [])
      }
      let filtered = messages.filter { (after == nil || $0.timestamp >= after!) && (before == nil || $0.timestamp < before!) }
      let next = try Self.nextOffset(data, offset: position.offset, pageCount: page.count)
      if let next { position.offset = next }
      // 边界整秒内可能出现一整页被过滤的消息，继续翻页，不能把它误当作读取结束。
      if !filtered.isEmpty || next == nil { return (filtered, next == nil ? nil : try position.encode()) }
    }
    throw AppFailure.message("Alpha REST 时间边界分页超过上限，保留任务重试")
  }

  private static func integer(_ value: Any?) -> Int? {
    if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return Int(number.stringValue) }
    if let value = value as? String { return Int(value) }
    return nil
  }
  private static func nextOffset(_ data: [String: Any], offset: Int, pageCount: Int) throws -> Int? {
    guard let more = data["hasMore"] as? Bool, integer(data["offset"]) == offset else {
      throw AppFailure.message("Alpha REST 缺少有效分页状态")
    }
    if !more { return nil }
    guard pageCount > 0, let next = integer(data["nextOffset"]), next == offset + pageCount else {
      throw AppFailure.message("Alpha REST 分页未推进或跳过记录")
    }
    return next
  }

  public func stream(account: String, onEvent: @escaping (SSEEvent) async -> Void) async throws {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:9527/api/v1/push/messages")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 3600
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["accountId": account])
    let (bytes, response) = try await session.bytes(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw AppFailure.message("推送不可用，已使用定时补查；请在 Alpha 开启消息推送")
    }
    await onEvent(SSEEvent(event: "connected", data: "", id: nil))
    var parser = SSEParser()
    for try await line in bytes.lines {
      try Task.checkCancellation()
      if let event = parser.consume(line) { await onEvent(event) }
    }
    throw AppFailure.message("消息推送连接已关闭，正在重连")
  }
}

/// REST 只提供 offset；持久化游标绑定查询范围，禁止跨账号、群或时间范围复用。
private struct RESTMessagePosition: Codable {
  let account: String
  let group: String
  let after: Int64?
  let before: Int64?
  let order: String
  var offset = 0
  func sameRange(as other: Self) -> Bool {
    account == other.account && group == other.group && after == other.after && before == other.before && order == other.order
  }
  func encode() throws -> String { "rest-v1:" + (try JSONEncoder().encode(self)).base64EncodedString() }
  static func decode(_ cursor: String) -> Self? {
    guard cursor.hasPrefix("rest-v1:"), let data = Data(base64Encoded: String(cursor.dropFirst(8))) else { return nil }
    return try? JSONDecoder().decode(Self.self, from: data)
  }
}
