import Foundation

/// 用户可直接编辑的 ~/.config/qundao/config.toml。包含连接密钥、模型与识别规则；
/// 白名单、摘要标记等运行状态在 Application Support 的 qundao.sqlite。
public struct AppConfig: Equatable {
  public var alphaToken = ""
  public var cpaKey = ""
  public var model = ""
  public var reasoning = "low"
  public var concurrency: Int?
  public var intervalMinutes = 15
  public var jevKey = ""
  public var decisionMethod = "local"
  public var jevBaseURL: String?
  public var jevAPI: JevAPI?
  public var jevModel: String?
  public var jevThreshold: Double?
  public var names: [String] = []
  public var keywords: [String] = []
  public var semanticEnabled = true
  public init() {}

  public static var defaultURL: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/qundao/config.toml")
  }

  /// 从偏好和现有密钥生成配置，用于首次迁移。
  public init(preferences p: Preferences, alpha: String, cpa: String, jev: String) {
    alphaToken = alpha; cpaKey = cpa; jevKey = jev
    model = p.model; reasoning = p.reasoning; concurrency = p.summaryConcurrency; intervalMinutes = p.intervalMinutes
    decisionMethod = p.decisionMethod ?? "local"; jevBaseURL = p.jevBaseURL; jevAPI = p.jevAPI; jevModel = p.jevModel
    jevThreshold = p.jevThreshold; names = p.names; keywords = p.keywords; semanticEnabled = p.semanticEnabled
  }
  public func apply(to p: inout Preferences) {
    p.model = model; p.reasoning = reasoning; p.summaryConcurrency = concurrency; p.intervalMinutes = intervalMinutes
    p.decisionMethod = decisionMethod; p.jevBaseURL = jevBaseURL; p.jevAPI = jevAPI; p.jevModel = jevModel
    p.jevThreshold = jevThreshold; p.names = names; p.keywords = keywords; p.semanticEnabled = semanticEnabled
  }

  // MARK: TOML（仅支持本文件需要的子集：[表]、字符串、整数、小数、布尔、字符串数组、# 注释）

  public static func parse(_ text: String) throws -> AppConfig {
    var table = "", values: [String: TOMLValue] = [:]
    for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
      let line = stripComment(raw).trimmingCharacters(in: .whitespaces)
      if line.isEmpty { continue }
      if line.hasPrefix("[") {
        guard line.hasSuffix("]") else { throw AppFailure.message("config.toml 第 \(index + 1) 行表名格式错误") }
        table = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces); continue
      }
      guard let eq = line.firstIndex(of: "=") else { throw AppFailure.message("config.toml 第 \(index + 1) 行缺少 =") }
      let key = line[..<eq].trimmingCharacters(in: .whitespaces)
      let rawValue = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
      guard let value = TOMLValue(rawValue) else { throw AppFailure.message("config.toml 第 \(index + 1) 行 \(key) 的值无法识别") }
      values[table.isEmpty ? key : "\(table).\(key)"] = value
    }
    var c = AppConfig()
    func s(_ k: String) -> String? { values[k]?.string }
    c.alphaToken = s("alpha.token") ?? ""
    c.cpaKey = s("cpa.api_key") ?? ""
    c.model = s("cpa.model") ?? ""
    c.reasoning = s("cpa.reasoning") ?? "low"
    c.concurrency = values["cpa.concurrency"]?.int
    c.intervalMinutes = values["cpa.interval_minutes"]?.int ?? 15
    c.jevKey = s("jev.api_key") ?? ""
    c.decisionMethod = s("jev.method") ?? "local"
    guard ["local", "jev"].contains(c.decisionMethod) else { throw AppFailure.message("jev.method 只能是 local 或 jev") }
    c.jevBaseURL = s("jev.base_url").flatMap { $0.isEmpty ? nil : $0 }
    if let api = s("jev.api"), !api.isEmpty {
      guard let value = JevAPI(rawValue: api) else { throw AppFailure.message("jev.api 只能是 decisions 或 systemOne") }
      c.jevAPI = value
    }
    c.jevModel = s("jev.model").flatMap { $0.isEmpty ? nil : $0 }
    c.jevThreshold = values["jev.threshold"]?.double
    c.names = values["rules.names"]?.strings ?? []
    c.keywords = values["rules.keywords"]?.strings ?? []
    c.semanticEnabled = values["rules.semantic"]?.bool ?? true
    return c
  }

  public func serialized() -> String {
    func q(_ v: String) -> String {
      "\"" + v.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t") + "\""
    }
    func a(_ v: [String]) -> String { "[" + v.map(q).joined(separator: ", ") + "]" }
    var lines = ["# 群岛配置。保存后应用自动重新加载；应用内修改也会写回此文件。",
                 "# 本文件包含密钥，权限保持 600，不要提交到仓库或分享。", "",
                 "[alpha]", "token = \(q(alphaToken))", "",
                 "[cpa]", "api_key = \(q(cpaKey))", "model = \(q(model))", "reasoning = \(q(reasoning))"]
    if let concurrency { lines.append("concurrency = \(concurrency)") }
    lines += ["interval_minutes = \(intervalMinutes)", "",
              "[jev]", "# local：本地识别；jev：使用 Jev 判断", "method = \(q(decisionMethod))", "api_key = \(q(jevKey))"]
    if let jevBaseURL { lines.append("base_url = \(q(jevBaseURL))") }
    if let jevAPI { lines.append("api = \(q(jevAPI.rawValue))") }
    if let jevModel { lines.append("model = \(q(jevModel))") }
    if let jevThreshold { lines.append("threshold = \(jevThreshold)") }
    lines += ["", "[rules]", "names = \(a(names))", "keywords = \(a(keywords))", "semantic = \(semanticEnabled)", ""]
    return lines.joined(separator: "\n")
  }

  private static func stripComment(_ line: String) -> String {
    var inString = false, escaped = false, result = ""
    for ch in line {
      if inString {
        if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
      } else if ch == "\"" { inString = true } else if ch == "#" { break }
      result.append(ch)
    }
    return result
  }
}

enum TOMLValue {
  case string(String), int(Int), double(Double), bool(Bool), array([String])
  var string: String? { if case .string(let v) = self { return v }; return nil }
  var int: Int? { switch self { case .int(let v): return v; default: return nil } }
  var double: Double? { switch self { case .double(let v): return v; case .int(let v): return Double(v); default: return nil } }
  var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
  var strings: [String]? { if case .array(let v) = self { return v }; return nil }

  init?(_ raw: String) {
    if raw == "true" { self = .bool(true); return }
    if raw == "false" { self = .bool(false); return }
    if raw.hasPrefix("\"") {
      var rest = Substring(raw)
      guard let value = TOMLValue.readString(&rest), rest.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
      self = .string(value); return
    }
    if raw.hasPrefix("[") {
      guard raw.hasSuffix("]") else { return nil }
      var rest = Substring(raw.dropFirst().dropLast())
      var items: [String] = []
      while true {
        rest = rest.drop(while: { $0.isWhitespace || $0 == "," })
        if rest.isEmpty { break }
        guard let item = TOMLValue.readString(&rest) else { return nil }
        items.append(item)
        rest = rest.drop(while: { $0.isWhitespace })
        guard rest.isEmpty || rest.first == "," else { return nil }
      }
      self = .array(items); return
    }
    if let v = Int(raw) { self = .int(v); return }
    if let v = Double(raw) { self = .double(v); return }
    return nil
  }
  private static func readString(_ s: inout Substring) -> String? {
    guard s.first == "\"" else { return nil }
    s = s.dropFirst()
    var out = "", escaped = false
    while let ch = s.first {
      s = s.dropFirst()
      if escaped {
        switch ch { case "n": out.append("\n"); case "t": out.append("\t"); default: out.append(ch) }
        escaped = false
      } else if ch == "\\" { escaped = true }
      else if ch == "\"" { return out }
      else { out.append(ch) }
    }
    return nil
  }
}

/// 写入时保证目录 700、文件 600，并通过同目录临时文件原子替换。
public struct AppConfigFile {
  public let url: URL
  public init(url: URL = AppConfig.defaultURL) { self.url = url }
  public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
  public func load() throws -> AppConfig { try AppConfig.parse(String(contentsOf: url, encoding: .utf8)) }
  public func save(_ config: AppConfig) throws {
    let dir = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    let temp = dir.appendingPathComponent(".config-\(UUID().uuidString).tmp")
    guard FileManager.default.createFile(atPath: temp.path, contents: Data(config.serialized().utf8),
                                         attributes: [.posixPermissions: 0o600]) else {
      throw AppFailure.message("配置文件写入失败：\(url.path)")
    }
    guard rename(temp.path, url.path) == 0 else {
      try? FileManager.default.removeItem(at: temp)
      throw AppFailure.message("配置文件替换失败：\(url.path)")
    }
  }
}
