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
    var c = AppConfig()
    func s(_ k: String) -> String? { values[k]?.string }
    c.alphaToken = s("alpha.token") ?? ""
    c.cpaKey = s("cpa.api_key") ?? ""
    c.model = s("cpa.model") ?? ""
    c.reasoning = s("cpa.reasoning") ?? "low"
    for key in ["cpa.system_prompt", "jev.system_prompt"] {
      if let value = values[key], value.string == nil {
        throw AppFailure.message("\(key) 必须是字符串")
      }
    }
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
    try ModelPrompts.validate(summary: c.cpaSystemPrompt, jev: c.jevSystemPrompt)
    return c
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

private enum TOMLValue {
  case string(String), int(Int), double(Double), bool(Bool), array([String])
  var string: String? { if case .string(let v) = self { return v }; return nil }
  var int: Int? { switch self { case .int(let v): return v; default: return nil } }
  var double: Double? { switch self { case .double(let v): return v; case .int(let v): return Double(v); default: return nil } }
  var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
  var strings: [String]? { if case .array(let v) = self { return v }; return nil }

}

/// 按字符扫描，避免把多行提示词中的 #、表名或换行误认为配置结构。
private struct TOMLParser {
  private let input: [Unicode.Scalar]
  private var offset = 0
  private var line = 1

  init(_ text: String) {
    // TOML 多行字符串允许 LF 和 CRLF，并将后者规范化为 LF；裸 CR 仍按非法字符拒绝。
    input = Array(text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars)
  }
  private var current: Unicode.Scalar? { offset < input.count ? input[offset] : nil }
  private mutating func advance() {
    if current == "\n" { line += 1 }
    offset += 1
  }
  private func failure(_ reason: String) -> AppFailure {
    .message("config.toml 第 \(line) 行\(reason)")
  }
  private mutating func horizontalSpace() {
    while current == " " || current == "\t" { advance() }
  }
  private mutating func comment() {
    if current == "#" { while let ch = current, ch != "\n" { advance() } }
  }
  private mutating func whitespaceAndComments() {
    while true {
      horizontalSpace(); comment()
      guard current == "\n" else { return }
      advance()
    }
  }
  private mutating func endOfLine() throws {
    horizontalSpace(); comment()
    guard current == nil || current == "\n" else { throw failure("的值后存在多余内容") }
    if current == "\n" { advance() }
  }
  private func string(from start: Int) -> String {
    String(String.UnicodeScalarView(input[start..<offset]))
  }

  mutating func parse() throws -> [String: TOMLValue] {
    var table = "", values: [String: TOMLValue] = [:]
    while true {
      whitespaceAndComments()
      guard current != nil else { return values }
      if current == "[" {
        advance()
        let start = offset
        while let ch = current, ch != "]", ch != "\n", ch != "\r" { advance() }
        guard current == "]" else { throw failure("表名格式错误") }
        table = string(from: start).trimmingCharacters(in: .whitespaces)
        guard !table.isEmpty, !table.contains("[") else { throw failure("表名格式错误") }
        advance(); try endOfLine(); continue
      }
      let start = offset
      while let ch = current, ch != "=", ch != "\n", ch != "\r" { advance() }
      guard current == "=" else { throw failure("缺少 =") }
      let keyParts = string(from: start).components(separatedBy: ".").map { $0.trimmingCharacters(in: .whitespaces) }
      guard keyParts.allSatisfy({ part in
        !part.isEmpty && part.unicodeScalars.allSatisfy {
          (48...57).contains($0.value) || (65...90).contains($0.value) || (97...122).contains($0.value) || $0 == "_" || $0 == "-"
        }
      }) else { throw failure("配置项名称格式错误") }
      let key = keyParts.joined(separator: ".")
      advance(); horizontalSpace()
      let value = try readValue()
      let fullKey = table.isEmpty ? key : "\(table).\(key)"
      guard values[fullKey] == nil else { throw failure("存在重复配置项 \(fullKey)") }
      values[fullKey] = value
      try endOfLine()
    }
  }

  private mutating func readValue() throws -> TOMLValue {
    if current == "\"" || current == "'" { return .string(try readString()) }
    if current == "[" {
      advance()
      var items: [String] = []
      while true {
        whitespaceAndComments()
        if current == "]" { advance(); return .array(items) }
        guard current == "\"" || current == "'" else { throw failure("字符串数组格式错误") }
        items.append(try readString())
        whitespaceAndComments()
        if current == "]" { advance(); return .array(items) }
        guard current == "," else { throw failure("字符串数组缺少逗号或结束括号") }
        advance()
      }
    }
    let start = offset
    while let ch = current, ch != "#", ch != "\n", ch != "\r" { advance() }
    let raw = string(from: start).trimmingCharacters(in: .whitespaces)
    if raw == "true" { return .bool(true) }
    if raw == "false" { return .bool(false) }
    if let value = Int(raw) { return .int(value) }
    if let value = Double(raw) { return .double(value) }
    throw failure("的值无法识别")
  }

  private mutating func readString() throws -> String {
    guard let quote = current, quote == "\"" || quote == "'" else { throw failure("缺少字符串引号") }
    let multiline = offset + 2 < input.count && input[offset + 1] == quote && input[offset + 2] == quote
    let basic = quote == "\""
    for _ in 0..<(multiline ? 3 : 1) { advance() }
    if multiline && current == "\n" { advance() }
    var result = ""
    while let ch = current {
      if ch == quote {
        if !multiline { advance(); return result }
        var count = 0
        while current == quote { count += 1; advance() }
        guard count <= 5 else { throw failure("多行字符串的连续引号过多") }
        if count >= 3 {
          for _ in 0..<(count - 3) { result.unicodeScalars.append(quote) }
          return result
        }
        for _ in 0..<count { result.unicodeScalars.append(quote) }
        continue
      }
      if basic && ch == "\\" {
        advance()
        // 多行 basic 字符串的行末反斜线折叠后续空白，直至下一个非空白字符。
        if multiline && (current == " " || current == "\t" || current == "\n") {
          horizontalSpace()
          guard current == "\n" else { throw failure("字符串的续行反斜线后必须换行") }
          while current == " " || current == "\t" || current == "\n" { advance() }
          continue
        }
        guard let escaped = current else { throw failure("字符串转义未完成") }
        advance()
        switch escaped {
        case "b": result.append("\u{08}")
        case "t": result.append("\t")
        case "n": result.append("\n")
        case "f": result.append("\u{0C}")
        case "r": result.append("\r")
        case "\"": result.append("\"")
        case "\\": result.append("\\")
        case "u", "U":
          var hex = ""
          for _ in 0..<(escaped == "u" ? 4 : 8) {
            guard let digit = current, (48...57).contains(digit.value) || (65...70).contains(digit.value) || (97...102).contains(digit.value) else {
              throw failure("Unicode 转义格式错误")
            }
            hex.unicodeScalars.append(digit); advance()
          }
          guard let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) else { throw failure("Unicode 转义不是合法字符") }
          result.unicodeScalars.append(scalar)
        default: throw failure("包含无效字符串转义")
        }
        continue
      }
      if ch == "\n" && multiline { result.append("\n"); advance(); continue }
      guard ch == "\t" || (ch.value >= 0x20 && ch.value != 0x7F) else { throw failure("字符串包含非法换行或控制字符") }
      result.unicodeScalars.append(ch); advance()
    }
    throw failure("字符串未闭合")
  }
}

/// 写入时保证目录 700、文件 600，并通过同目录临时文件原子替换。
public struct AppConfigFile {
  public let url: URL
  public init(url: URL = AppConfig.defaultURL) { self.url = url }
  public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
  public func load() throws -> AppConfig { try AppConfig.parse(String(contentsOf: url, encoding: .utf8)) }
  public func save(_ config: AppConfig) throws {
    try ModelPrompts.validate(summary: config.cpaSystemPrompt, jev: config.jevSystemPrompt)
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
