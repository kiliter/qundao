import Foundation

public enum DiagnosticCategory: String, Codable, CaseIterable {
  case local = "本地决策", jev = "Jev 决策", cpa = "CPA 摘要", runtime = "运行事件"
}
public struct DiagnosticRecord: Codable, Identifiable {
  public var id = UUID()
  public var date = Date()
  public var category: DiagnosticCategory
  public var event: String
  public var correlationID: String
  public var scope: String
  public var input: String
  public var output: String
  public var error: String
  public var durationMS: Int?
  public var statusCode: Int?
  public init(category: DiagnosticCategory, event: String, correlationID: String = UUID().uuidString,
              scope: String = "", input: String = "", output: String = "", error: String = "",
              durationMS: Int? = nil, statusCode: Int? = nil) {
    self.category = category; self.event = event; self.correlationID = correlationID; self.scope = scope
    self.input = input; self.output = output; self.error = error
    self.durationMS = durationMS; self.statusCode = statusCode
  }
  /// 仅接收请求体，禁止传入鉴权头；递归脱敏服务返回的密钥字段及已知密钥值。
  public static func safeText(_ data: Data?, secrets: [String] = []) -> String {
    guard let data else { return "" }
    func scrub(_ value: Any) -> Any {
      if let object = value as? [String: Any] {
        return object.mapValues { scrub($0) }.map { key, value in
          let normalized = key.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
          return (key, ["authorization", "apikey", "accesstoken", "refreshtoken", "password", "secret"].contains(normalized) ? "[已隐藏]" as Any : value)
        }.reduce(into: [String: Any]()) { $0[$1.0] = $1.1 }
      }
      if let array = value as? [Any] { return array.map(scrub) }
      return value
    }
    var text: String
    if let json = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed),
       let clean = try? JSONSerialization.data(withJSONObject: scrub(json), options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]),
       let string = String(data: clean, encoding: .utf8) { text = string }
    else { text = String(decoding: data, as: UTF8.self) }
    for secret in secrets where !secret.isEmpty { text = text.replacingOccurrences(of: secret, with: "[已隐藏]") }
    text = text.replacingOccurrences(of: "(?i)Bearer\\s+[A-Za-z0-9._~+/-]+", with: "Bearer [已隐藏]", options: .regularExpression)
    return text
  }
  /// 仅在阅读时展开 Responses 的 input/content、output_text 等内嵌 JSON；归档仍保留协议结构。
  public static func readableText(_ text: String) -> String {
    func expand(_ value: Any, depth: Int) -> Any {
      guard depth < 12 else { return value }
      if let object = value as? [String: Any] { return object.mapValues { expand($0, depth: depth + 1) } }
      if let array = value as? [Any] { return array.map { expand($0, depth: depth + 1) } }
      if let string = value as? String, let data = string.data(using: .utf8),
         let json = try? JSONSerialization.jsonObject(with: data), json is [String: Any] || json is [Any] {
        return expand(json, depth: depth + 1)
      }
      return value
    }
    guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
          let data = try? JSONSerialization.data(withJSONObject: expand(json, depth: 0),
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return text }
    return String(decoding: data, as: UTF8.self)
  }
  public static func model(category: DiagnosticCategory, event: String, id: String, endpoint: URL,
                           request: Data?, response: Data? = nil, status: Int? = nil,
                           started: Date, error: String = "", key: String) -> DiagnosticRecord {
    DiagnosticRecord(category: category, event: event, correlationID: id, scope: endpoint.absoluteString,
      input: safeText(request, secrets: [key]), output: safeText(response, secrets: [key]),
      error: safeText(error.data(using: .utf8), secrets: [key]),
      durationMS: Int(Date().timeIntervalSince(started) * 1000), statusCode: status)
  }
}

public struct DiagnosticCursor: Equatable {
  public var filename: String
  public var offset: UInt64
}
public struct DiagnosticPage {
  public var records: [DiagnosticRecord]
  public var next: DiagnosticCursor?
}

/// 按日、大小滚动归档。分页从文件末尾倒读，游标不受新日志追加影响。
public final class DiagnosticLogStore: @unchecked Sendable {
  public let directory: URL
  private let lock = NSLock()
  private let maxFileBytes: UInt64
  private var writes: UInt64 = 0
  private var subscribers: [UUID: AsyncStream<UInt64>.Continuation] = [:]
  public var revision: UInt64 { lock.lock(); defer { lock.unlock() }; return writes }
  public init(directory: URL, maxFileBytes: UInt64 = 10 * 1024 * 1024) {
    self.directory = directory; self.maxFileBytes = maxFileBytes
  }
  /// 订阅后先提供当前版本；高频写入合并为最新版本，不在内存重复保存正文。
  public func updates() -> AsyncStream<UInt64> {
    AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let id = UUID()
      continuation.onTermination = { [weak self] _ in
        guard let self else { return }
        self.lock.lock(); self.subscribers.removeValue(forKey: id); self.lock.unlock()
      }
      lock.lock()
      subscribers[id] = continuation
      continuation.yield(writes)
      lock.unlock()
    }
  }
  public func append(_ record: DiagnosticRecord) throws {
    lock.lock(); defer { lock.unlock() }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                           attributes: [.posixPermissions: 0o700])
    let date = DateFormatter(); date.dateFormat = "yyyy-MM-dd"; date.locale = Locale(identifier: "en_US_POSIX")
    let prefix = "诊断-\(date.string(from: record.date))-"
    let files = try logFiles().filter { $0.lastPathComponent.hasPrefix(prefix) }
    var file = files.first
    if let current = file, let size = try current.resourceValues(forKeys: [.fileSizeKey]).fileSize,
       size >= maxFileBytes { file = nil }
    if file == nil {
      // 保留旧文件路径不变，正在查看旧页的游标不会因滚动归档失效。
      let number = (files.compactMap { Int($0.deletingPathExtension().lastPathComponent.suffix(6)) }.max() ?? 0) + 1
      file = directory.appendingPathComponent(prefix + String(format: "%06d.jsonl", number))
      FileManager.default.createFile(atPath: file!.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
    let handle = try FileHandle(forUpdating: file!)
    defer { try? handle.close() }
    let size = try handle.seekToEnd()
    if size > 0 {
      try handle.seek(toOffset: size - 1)
      let last = try handle.read(upToCount: 1)
      try handle.seekToEnd()
      if last?.last != 10 { try handle.write(contentsOf: Data([10])) }
    }
    try handle.write(contentsOf: JSONEncoder().encode(record) + Data([10]))
    try handle.synchronize()
    writes &+= 1
    // 仅在成功落盘后通知。yield 不等待读取，且保持多线程写入版本的发布顺序。
    for subscriber in subscribers.values { subscriber.yield(writes) }
  }
  public func page(before cursor: DiagnosticCursor? = nil, category: DiagnosticCategory? = nil,
                   limit: Int = 50) throws -> DiagnosticPage {
    // 文件不会重命名；读取时固定长度，不持有写锁，历史扫描不阻塞实时消息入库。
    let files = try logFiles()
    var result: [DiagnosticRecord] = []
    var next: DiagnosticCursor?
    for file in files {
      if let cursor, file.lastPathComponent > cursor.filename { continue }
      let handle = try FileHandle(forReadingFrom: file)
      defer { try? handle.close() }
      let size = try handle.seekToEnd()
      var end = (cursor?.filename == file.lastPathComponent) ? min(cursor!.offset, size) : size
      var carry = Data()
      while end > 0 {
        let start = end > 65536 ? end - 65536 : 0
        try handle.seek(toOffset: start)
        let chunk = try handle.read(upToCount: Int(end - start)) ?? Data()
        var data = chunk + carry
        // 末尾换行不产生一条空日志。
        if data.last == 10 { data.removeLast() }
        var lineEnd = data.count
        var index = data.count
        while index > 0 {
          index -= 1
          if data[index] == 10 {
            let lineStart = index + 1
            if let record = try? JSONDecoder().decode(DiagnosticRecord.self, from: data.subdata(in: lineStart..<lineEnd)),
               category == nil || record.category == category {
              if result.count == max(1, limit) { return DiagnosticPage(records: result, next: next) }
              result.append(record)
              next = DiagnosticCursor(filename: file.lastPathComponent, offset: start + UInt64(lineStart))
            }
            lineEnd = index
          }
        }
        carry = data.subdata(in: 0..<lineEnd)
        end = start
        if start == 0, let record = try? JSONDecoder().decode(DiagnosticRecord.self, from: carry),
           category == nil || record.category == category {
          if result.count == max(1, limit) { return DiagnosticPage(records: result, next: next) }
          result.append(record)
          next = DiagnosticCursor(filename: file.lastPathComponent, offset: 0)
        }
      }
    }
    return DiagnosticPage(records: result, next: nil)
  }
  private func logFiles() throws -> [URL] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
      .filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("诊断-") }
      .sorted { $0.lastPathComponent > $1.lastPathComponent }
  }
}
