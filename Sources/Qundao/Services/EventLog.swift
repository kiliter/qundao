import CryptoKit
import Foundation
import QundaoCore

final class EventLog: @unchecked Sendable {
  static let shared = EventLog()
  let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
    0
  ].appendingPathComponent("Qundao/Logs", isDirectory: true)
  let diagnostics = DiagnosticLogStore(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Qundao/Logs/Diagnostics", isDirectory: true))
  func record(_ item: DiagnosticRecord) {
    do { try diagnostics.append(item) }
    catch { NSLog("群岛诊断日志写入失败：%@", error.localizedDescription) }
  }
  func localDecision(_ message: Message, preferences: Preferences, selfID: String,
                     match: RuleMatch, semantic: Bool, action: String, elapsed: TimeInterval) {
    let reason: String
    switch match {
    case .definite(let value), .candidate(let value): reason = value
    case .none: reason = semantic ? "本地语义命中" : "未命中本地规则"
    }
    let input: [String: Any] = ["消息": ["账号": message.accountID, "群": message.groupID, "消息ID": message.id,
      "发送人ID": message.senderID, "发送人": message.sender, "正文": message.text, "提及": message.mentions],
      "当前用户": selfID, "称呼": preferences.names, "关键词": preferences.keywords,
      "启用语义": preferences.semanticEnabled, "判断方式": preferences.usesJev ? "Jev" : "本地"]
    let output: [String: Any] = ["本地相关": match != .none || semantic, "语义命中": semantic,
      "依据": reason, "后续动作": action]
    record(DiagnosticRecord(category: .local, event: action, scope: message.groupID,
      input: DiagnosticRecord.safeText(try? JSONSerialization.data(withJSONObject: input)),
      output: DiagnosticRecord.safeText(try? JSONSerialization.data(withJSONObject: output)),
      durationMS: Int(elapsed * 1000)))
  }
  private let lock = NSLock()
  private let formatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()
  func write(_ level: String = "信息", _ event: String, _ detail: String = "") {
    record(DiagnosticRecord(category: .runtime, event: event, output: detail, error: level == "错误" ? detail : ""))
    lock.lock()
    defer { lock.unlock() }
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let stamp = formatter.string(from: Date())
      let day = DateFormatter()
      day.dateFormat = "yyyy-MM-dd"
      day.locale = Locale(identifier: "en_US_POSIX")
      let url = directory.appendingPathComponent("群岛-\(day.string(from:Date())).jsonl")
      let data = try JSONSerialization.data(
        withJSONObject: ["时间": stamp, "级别": level, "事件": event, "详情": detail],
        options: [.sortedKeys])
      if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(
          atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
      }
      let handle = try FileHandle(forWritingTo: url)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: data + Data([10]))
      try handle.synchronize()
      // 单文件 10 MB 滚动归档，历史不自动删除。
      if (try handle.offset()) > 10 * 1024 * 1024 {
        try handle.close()
        try FileManager.default.moveItem(
          at: url,
          to: directory.appendingPathComponent(
            "群岛-\(day.string(from:Date()))-\(Int(Date().timeIntervalSince1970)).jsonl"))
      }
    } catch { NSLog("群岛日志写入失败：%@", error.localizedDescription) }
  }
  func recent() -> String {
    lock.lock()
    defer { lock.unlock() }
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
      ).filter({ $0.pathExtension == "jsonl" }).sorted(by: {
        $0.lastPathComponent > $1.lastPathComponent
      }), let file = files.first, let handle = try? FileHandle(forReadingFrom: file)
    else { return "暂无日志。连接或开始监听后会写入本地日志文件。" }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    try? handle.seek(toOffset: size > 128000 ? size - 128000 : 0)
    let data = (try? handle.readToEnd()) ?? Data()
    return String(data: data, encoding: .utf8) ?? "日志正在写入，请刷新。"
  }
  static func ref(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
  }
}
