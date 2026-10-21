import XCTest
@testable import QundaoCore

final class JevConfigurationTests: XCTestCase {
  func testOpenRouterBaseAndFullEndpoints() throws {
    for base in ["https://openrouter.ai", "https://openrouter.ai/api", "https://openrouter.ai/api/v1/", "https://openrouter.ai/api/alpha/decisions/"] {
      let config = JevConfiguration(baseURL: base, api: .decisions, model: "~typesafe/jev-latest")
      XCTAssertEqual(try config.endpoint().absoluteString, "https://openrouter.ai/api/alpha/decisions")
    }
    XCTAssertEqual(try JevConfiguration(baseURL: "https://openrouter.ai/api/v1", api: .systemOne, model: "typesafe/jev-1.14").endpoint().absoluteString,
                   "https://openrouter.ai/api/v1/systemone")
  }
  func testCustomProxyPreservesPathAndTypeSafeEndpoint() throws {
    XCTAssertEqual(try JevConfiguration(baseURL: "https://proxy.example/route/v1/", api: .systemOne, model: "custom").endpoint().absoluteString,
                   "https://proxy.example/route/v1/systemone")
    XCTAssertEqual(try JevConfiguration(baseURL: "http://127.0.0.1:9000/api", api: .decisions, model: "custom").endpoint().absoluteString,
                   "http://127.0.0.1:9000/api/alpha/decisions")
    XCTAssertEqual(try JevConfiguration.typeSafe.endpoint().absoluteString, "https://api.typesafe.ai/v1/systemone")
  }
  func testInvalidAddressesDoNotSendCredentials() {
    for base in ["", "openrouter.ai", "ftp://example.org", "https://u:password@example.org", "https://example.org?api_key=secret", "https://example.org/#fragment", "https://bad host/api"] {
      XCTAssertThrowsError(try JevConfiguration(baseURL: base, api: .decisions, model: "jev").endpoint())
    }
    XCTAssertThrowsError(try JevConfiguration(baseURL: "https://openrouter.ai/api/v1/systemone", api: .decisions, model: "jev").endpoint())
  }
  func testConfigurationPersistsAndLegacyModelsKeepTheirProvider() throws {
    var prefs = Preferences()
    XCTAssertEqual(prefs.jevConfiguration, .openRouter)
    prefs.jevModel = "jev-latest"
    XCTAssertEqual(prefs.jevConfiguration, .typeSafe)
    prefs.jevBaseURL = "https://proxy.example/api"
    prefs.jevAPI = .decisions
    prefs.jevModel = "~typesafe/jev-latest"
    let loaded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
    XCTAssertEqual(loaded.jevConfiguration, prefs.jevConfiguration)
  }
}
