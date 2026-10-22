import XCTest
@testable import QundaoCore

final class AppConfigTests: XCTestCase {
  func testRoundTripKeepsAllFieldsIncludingQuotesAndChinese() throws {
    var c = AppConfig()
    c.alphaToken = "tok\"en#1"; c.cpaKey = "sk-test"; c.model = "gpt"; c.reasoning = "medium"; c.concurrency = 4
    c.intervalMinutes = 30; c.jevKey = "jk"; c.decisionMethod = "jev"; c.jevBaseURL = "https://example.com/api"
    c.jevAPI = .systemOne; c.jevModel = "jev-latest"; c.jevThreshold = 0.8
    c.cpaSystemPrompt = "\n摘要 # 保留\n包含 \"\"\"引号\"\"\"、C:\\目录\\文件、回车\r\n末行\t"
    c.jevSystemPrompt = "判断 '相关'，保留 \\n 字面内容\n"
    c.names = ["无纸化", "张三"]; c.keywords = ["签字, 审批"]; c.semanticEnabled = false
    XCTAssertEqual(try AppConfig.parse(c.serialized()), c)
  }
  func testHandWrittenFileWithCommentsAndDefaults() throws {
    let c = try AppConfig.parse("""
    # 注释
    [alpha]
    token = "abc" # 行尾注释
    [rules]
    keywords = ["无纸化", "人证比对",]
    """)
    XCTAssertEqual(c.alphaToken, "abc"); XCTAssertEqual(c.keywords, ["无纸化", "人证比对"])
    XCTAssertEqual(c.decisionMethod, "local"); XCTAssertEqual(c.intervalMinutes, 15); XCTAssertTrue(c.semanticEnabled)
    XCTAssertNil(c.cpaSystemPrompt); XCTAssertNil(c.jevSystemPrompt)
    XCTAssertEqual(ModelPrompts.effectiveSummary(c.cpaSystemPrompt), ModelPrompts.summaryDefault)
    XCTAssertEqual(ModelPrompts.effectiveJev(c.jevSystemPrompt), ModelPrompts.jevDefault)
  }
  func testInvalidValuesAreRejectedInsteadOfSilentlyCleared() {
    XCTAssertThrowsError(try AppConfig.parse("[jev]\nmethod = \"remote\""))
    XCTAssertThrowsError(try AppConfig.parse("[alpha]\ntoken = abc"))
    XCTAssertThrowsError(try AppConfig.parse("[alpha\ntoken = \"a\""))
  }
  func testExistingDottedKeysRemainSupported() throws {
    let config = try AppConfig.parse(#"""
    cpa.model = "demo"
    cpa.api_key = "synthetic"
    cpa . system_prompt = "摘要规则"
    jev.system_prompt = '判断规则'
    """#)
    XCTAssertEqual(config.model, "demo"); XCTAssertEqual(config.cpaKey, "synthetic")
    XCTAssertEqual(config.cpaSystemPrompt, "摘要规则"); XCTAssertEqual(config.jevSystemPrompt, "判断规则")
  }
  func testFileIsPrivate() throws {
    let url = URL(fileURLWithPath: "/tmp/qundao-config-\(UUID().uuidString)/config.toml")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    var c = AppConfig(); c.cpaKey = "k"
    try AppConfigFile(url: url).save(c)
    let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! Int
    XCTAssertEqual(mode & 0o777, 0o600)
    XCTAssertEqual(try AppConfigFile(url: url).load(), c)
  }

  func testMultilinePromptsKeepCommentsQuotesAndLiteralBackslashes() throws {
    let config = try AppConfig.parse(#"""
    [cpa]
    system_prompt = """
    第一行 # 这是正文
    "引用" 和 ""双引号""，路径 C:\\rules
    """ # 这是注释
    [jev]
    system_prompt = '''
    只判断 '相关' 和 ''回应'' # 也是正文
    路径 C:\rules，\n 保留字面内容
    ''' # 结束注释
    [rules]
    names = ['名字#1', "名字\"2"]
    """#)
    XCTAssertEqual(config.cpaSystemPrompt, "第一行 # 这是正文\n\"引用\" 和 \"\"双引号\"\"，路径 C:\\rules\n")
    XCTAssertEqual(config.jevSystemPrompt, "只判断 '相关' 和 ''回应'' # 也是正文\n路径 C:\\rules，\\n 保留字面内容\n")
    XCTAssertEqual(config.names, ["名字#1", "名字\"2"])
    XCTAssertEqual(try AppConfig.parse(config.serialized()), config)
    XCTAssertTrue(config.serialized().contains("system_prompt = \"\"\"\n第一行"))
  }

  func testBasicStringEscapesAndUnicodeAreDecoded() throws {
    let config = try AppConfig.parse(#"""
    [cpa]
    system_prompt = "\u4E2D\u6587\U0001F30A\t\r\n\b\f\\\""
    [jev]
    system_prompt = """\u4E2D\u6587\U0001F30A\t\r\n\b\f\\\""""
    """#)
    let expected = "中文🌊\t\r\n\u{08}\u{0C}\\\""
    XCTAssertEqual(config.cpaSystemPrompt, expected)
    XCTAssertEqual(config.jevSystemPrompt, expected)
    XCTAssertEqual(try AppConfig.parse(config.serialized()), config)
  }

  func testMultilineInitialNewlineCRLFAndContinuation() throws {
    let source = #"""
    [cpa]
    system_prompt = """
    第一行\

        第二行
    第三行"""
    [jev]
    system_prompt = '''

    第二行'''
    """#
    let config = try AppConfig.parse(source.replacingOccurrences(of: "\n", with: "\r\n"))
    XCTAssertEqual(config.cpaSystemPrompt, "第一行第二行\n第三行")
    XCTAssertEqual(config.jevSystemPrompt, "\n第二行")
    XCTAssertEqual(try AppConfig.parse(config.serialized()), config)
  }

  func testMultilineClosingQuotesAndEmptyStrings() throws {
    for (source, expected) in [
      (String(repeating: "\"", count: 6), ""),
      ("\"\"\"引用\"\"\"\"", "引用\""),
      ("\"\"\"引用\"\"\"\"\"", "引用\"\""),
      ("''''''", ""), ("'''引用''''", "引用'"), ("'''引用'''''", "引用''")
    ] {
      let config = try AppConfig.parse("[cpa]\nsystem_prompt = " + source)
      XCTAssertEqual(config.cpaSystemPrompt, expected, source)
    }
  }

  func testSerializationEscapesAllControlCharacters() throws {
    var config = AppConfig()
    let controls = String(String.UnicodeScalarView((0..<32).compactMap(Unicode.Scalar.init))) + "\u{7F}"
    config.cpaSystemPrompt = "控制字符：" + controls
    config.jevSystemPrompt = "\\\"\"\"\n结束\\"
    config.names = [controls]; config.alphaToken = "包含回车\r与反斜线\\"
    XCTAssertEqual(try AppConfig.parse(config.serialized()), config)
  }

  func testInvalidPromptTypeAndMalformedStringsAreRejected() {
    let invalidValues = [
      "123", "true", "[\"不能用数组\"]", "\"未闭合", "'''未闭合", "\"\"\"未闭合",
      #""无效\q""#, #""无效\uD800""#, #""无效\U00110000""#,
      "\"裸回车\r不允许\"", "\"裸换行\n不允许\"", "\"控制\u{01}\"",
      "\"完成\" 多余内容", "\"\"\"完成\"\"\" 多余内容"
    ]
    for section in ["cpa", "jev"] {
      for value in invalidValues {
        XCTAssertThrowsError(try AppConfig.parse("[\(section)]\nsystem_prompt = " + value), "\(section): \(value)")
      }
    }
  }

  func testPromptLengthValidationUsesUTF8Bytes() throws {
    for section in ["cpa", "jev"] {
      XCTAssertThrowsError(try AppConfig.parse("[\(section)]\nsystem_prompt = \"\(String(repeating: "中", count: 5_334))\""))
      _ = try AppConfig.parse("[\(section)]\nsystem_prompt = \"\(String(repeating: "a", count: 16_000))\"")
    }
    let config = try AppConfig.parse("[cpa]\nsystem_prompt = \"  \\n\\t\"\n[jev]\nsystem_prompt = ''")
    XCTAssertEqual(ModelPrompts.effectiveSummary(config.cpaSystemPrompt), ModelPrompts.summaryDefault)
    XCTAssertEqual(ModelPrompts.effectiveJev(config.jevSystemPrompt), ModelPrompts.jevDefault)
  }

  func testOldPreferencesDecodeWithoutPromptKeys() throws {
    var preferences = Preferences()
    preferences.cpaSystemPrompt = "新版摘要提示词"; preferences.jevSystemPrompt = "新版相关性提示词"
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
    object.removeValue(forKey: "cpaSystemPrompt"); object.removeValue(forKey: "jevSystemPrompt")
    let old = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertNil(old.cpaSystemPrompt); XCTAssertNil(old.jevSystemPrompt)
    XCTAssertEqual(old.model, preferences.model); XCTAssertEqual(old.selectedGroups, preferences.selectedGroups)
  }

  func testMigrationAndApplyPreserveBothPrompts() throws {
    var preferences = Preferences()
    preferences.cpaSystemPrompt = "摘要规则\n第二行"; preferences.jevSystemPrompt = "判断规则 # 保留"
    preferences.accountID = "synthetic-account"; preferences.selectedGroups = ["synthetic-group"]
    var config = AppConfig(preferences: preferences, alpha: "synthetic-alpha", cpa: "synthetic-cpa", jev: "synthetic-jev")
    XCTAssertEqual(config.cpaSystemPrompt, preferences.cpaSystemPrompt)
    XCTAssertEqual(config.jevSystemPrompt, preferences.jevSystemPrompt)
    config = try AppConfig.parse(config.serialized())
    config.cpaSystemPrompt = "修改后的摘要规则"; config.jevSystemPrompt = nil
    config.apply(to: &preferences)
    XCTAssertEqual(preferences.cpaSystemPrompt, "修改后的摘要规则"); XCTAssertNil(preferences.jevSystemPrompt)
    XCTAssertEqual(preferences.accountID, "synthetic-account"); XCTAssertEqual(preferences.selectedGroups, ["synthetic-group"])
    XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences)), preferences)
  }

  func testInvalidPromptSaveKeepsExistingFile() throws {
    let url = URL(fileURLWithPath: "/tmp/qundao-config-\(UUID().uuidString)/config.toml")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let file = AppConfigFile(url: url)
    var config = AppConfig(); config.cpaSystemPrompt = "已保存的有效规则"
    try file.save(config)
    var invalid = config; invalid.jevSystemPrompt = String(repeating: "a", count: 16_001)
    XCTAssertThrowsError(try file.save(invalid))
    XCTAssertEqual(try file.load(), config)
  }
}
