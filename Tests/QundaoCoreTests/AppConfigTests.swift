import XCTest
@testable import QundaoCore

final class AppConfigTests: XCTestCase {
  func testRoundTripKeepsAllFieldsIncludingQuotesAndChinese() throws {
    var c = AppConfig()
    c.alphaToken = "tok\"en#1"; c.cpaKey = "sk-test"; c.model = "gpt"; c.reasoning = "medium"; c.concurrency = 4
    c.intervalMinutes = 30; c.jevKey = "jk"; c.decisionMethod = "jev"; c.jevBaseURL = "https://example.com/api"
    c.jevAPI = .systemOne; c.jevModel = "jev-latest"; c.jevThreshold = 0.8
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
  }
  func testInvalidValuesAreRejectedInsteadOfSilentlyCleared() {
    XCTAssertThrowsError(try AppConfig.parse("[jev]\nmethod = \"remote\""))
    XCTAssertThrowsError(try AppConfig.parse("[alpha]\ntoken = abc"))
    XCTAssertThrowsError(try AppConfig.parse("[alpha\ntoken = \"a\""))
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
}
