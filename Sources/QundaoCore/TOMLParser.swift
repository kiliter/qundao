import Foundation

enum TOMLValue {
  case string(String), int(Int), double(Double), bool(Bool), array([String])
  var string: String? { if case .string(let v) = self { return v }; return nil }
  var int: Int? { switch self { case .int(let v): return v; default: return nil } }
  var double: Double? { switch self { case .double(let v): return v; case .int(let v): return Double(v); default: return nil } }
  var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
  var strings: [String]? { if case .array(let v) = self { return v }; return nil }

}

/// 按字符扫描，避免把多行提示词中的 #、表名或换行误认为配置结构。
struct TOMLParser {
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
