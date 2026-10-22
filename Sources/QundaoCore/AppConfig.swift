import Foundation

/// 用户可直接编辑的 ~/.config/qundao/config.toml。包含连接密钥、模型与识别规则；
/// 白名单、摘要标记等运行状态在 Application Support 的 qundao.sqlite。
public struct AppConfig: Equatable {
  public var alphaToken = ""
  public var cpaKey = ""
  public var model = ""
  public var reasoning = "low"
  public var cpaSystemPrompt: String?
  public var jevSystemPrompt: String?
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
    cpaSystemPrompt = p.cpaSystemPrompt; jevSystemPrompt = p.jevSystemPrompt
    decisionMethod = p.decisionMethod ?? "local"; jevBaseURL = p.jevBaseURL; jevAPI = p.jevAPI; jevModel = p.jevModel
    jevThreshold = p.jevThreshold; names = p.names; keywords = p.keywords; semanticEnabled = p.semanticEnabled
  }
  public func apply(to p: inout Preferences) {
    p.model = model; p.reasoning = reasoning; p.summaryConcurrency = concurrency; p.intervalMinutes = intervalMinutes
    p.cpaSystemPrompt = cpaSystemPrompt; p.jevSystemPrompt = jevSystemPrompt
    p.decisionMethod = decisionMethod; p.jevBaseURL = jevBaseURL; p.jevAPI = jevAPI; p.jevModel = jevModel
    p.jevThreshold = jevThreshold; p.names = names; p.keywords = keywords; p.semanticEnabled = semanticEnabled
  }

  // MARK: TOML（本文件需要的子集，字符串支持 basic/literal 单行及多行形式）

  public static func parse(_ text: String) throws -> AppConfig {
    var parser = TOMLParser(text)
    let values = try parser.parse()
    // 已知字段写错类型必须整份拒绝，不能用默认值清空密钥或改变正在生效的规则。
    let stringKeys = ["alpha.token", "cpa.api_key", "cpa.model", "cpa.reasoning", "cpa.system_prompt",
      "jev.api_key", "jev.method", "jev.base_url", "jev.api", "jev.model", "jev.system_prompt"]
    for key in stringKeys where values[key] != nil && values[key]?.string == nil {
      throw AppFailure.message("\(key) 必须是字符串")
    }
    for key in ["cpa.concurrency", "cpa.interval_minutes"] where values[key] != nil && values[key]?.int == nil {
      throw AppFailure.message("\(key) 必须是整数")
    }
    for key in ["rules.names", "rules.keywords"] where values[key] != nil && values[key]?.strings == nil {
      throw AppFailure.message("\(key) 必须是字符串数组")
    }
    if values["rules.semantic"] != nil, values["rules.semantic"]?.bool == nil {
      throw AppFailure.message("rules.semantic 必须是布尔值")
    }
    if values["jev.threshold"] != nil, values["jev.threshold"]?.double == nil {
      throw AppFailure.message("jev.threshold 必须是数值")
    }
    var c = AppConfig()
    func s(_ k: String) -> String? { values[k]?.string }
    c.alphaToken = s("alpha.token") ?? ""
    c.cpaKey = s("cpa.api_key") ?? ""
    c.model = s("cpa.model") ?? ""
    c.reasoning = s("cpa.reasoning") ?? "low"
    c.cpaSystemPrompt = s("cpa.system_prompt")
    c.jevSystemPrompt = s("jev.system_prompt")
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
    try c.validate()
    return c
  }

  public func validate() throws {
    try ModelPrompts.validate(summary: cpaSystemPrompt, jev: jevSystemPrompt)
    if let concurrency, !(1...8).contains(concurrency) { throw AppFailure.message("cpa.concurrency 必须为 1 至 8") }
    guard intervalMinutes > 0 else { throw AppFailure.message("cpa.interval_minutes 必须是正整数") }
    if let jevThreshold, !jevThreshold.isFinite || !(0.5...0.95).contains(jevThreshold) {
      throw AppFailure.message("jev.threshold 必须是 0.5 至 0.95 之间的有限数值")
    }
  }

  public func serialized() -> String {
    func escaped(_ v: String, multiline: Bool) -> String {
      var result = ""
      for scalar in v.unicodeScalars {
        switch scalar {
        case "\\": result += "\\\\"
        case "\"": result += "\\\""
        case "\n": result += multiline ? "\n" : "\\n"
        case "\r": result += "\\r"
        case "\t": result += "\\t"
        case "\u{08}": result += "\\b"
        case "\u{0C}": result += "\\f"
        default:
          if scalar.value < 0x20 || scalar.value == 0x7F {
            result += String(format: "\\u%04X", scalar.value)
          } else { result.unicodeScalars.append(scalar) }
        }
      }
      return result
    }
    func q(_ v: String) -> String { "\"" + escaped(v, multiline: false) + "\"" }
    func prompt(_ v: String) -> String { "\"\"\"\n" + escaped(v, multiline: true) + "\"\"\"" }
    func a(_ v: [String]) -> String { "[" + v.map(q).joined(separator: ", ") + "]" }
    var lines = ["# 群岛配置。保存后应用自动重新加载；应用内修改也会写回此文件。",
                 "# 本文件包含密钥，权限保持 600，不要提交到仓库或分享。", "",
                 "[alpha]", "token = \(q(alphaToken))", "",
                 "[cpa]", "api_key = \(q(cpaKey))", "model = \(q(model))", "reasoning = \(q(reasoning))"]
    if let cpaSystemPrompt { lines.append("system_prompt = \(prompt(cpaSystemPrompt))") }
    if let concurrency { lines.append("concurrency = \(concurrency)") }
    lines += ["interval_minutes = \(intervalMinutes)", "",
              "[jev]", "# local：本地识别；jev：使用 Jev 判断", "method = \(q(decisionMethod))", "api_key = \(q(jevKey))"]
    if let jevSystemPrompt { lines.append("system_prompt = \(prompt(jevSystemPrompt))") }
    if let jevBaseURL { lines.append("base_url = \(q(jevBaseURL))") }
    if let jevAPI { lines.append("api = \(q(jevAPI.rawValue))") }
    if let jevModel { lines.append("model = \(q(jevModel))") }
    if let jevThreshold { lines.append("threshold = \(jevThreshold)") }
    lines += ["", "[rules]", "names = \(a(names))", "keywords = \(a(keywords))", "semantic = \(semanticEnabled)", ""]
    return lines.joined(separator: "\n")
  }

}

/// 写入时保证目录 700、文件 600，并通过同目录临时文件原子替换。
public struct AppConfigFile {
  public let url: URL
  public init(url: URL = AppConfig.defaultURL) { self.url = url }
  public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
  public func load() throws -> AppConfig { try AppConfig.parse(String(contentsOf: url, encoding: .utf8)) }
  public func save(_ config: AppConfig) throws {
    try config.validate()
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
