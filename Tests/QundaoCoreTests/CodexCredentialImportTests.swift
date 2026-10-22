import XCTest
@testable import QundaoCore

final class CodexCredentialImportTests: XCTestCase {
  private let authentication = Data(#"{"auth_mode":"apikey","OPENAI_API_KEY":"synthetic-cpa-key","tokens":null}"#.utf8)
  private func configuration(provider: String = "custom-cpa", endpoint: String = "https://cpa.bgp.kiliter.cn/v1",
                             root: String = "", providerFields: String = "") -> String {
    """
    model_provider = "\(provider)"
    cli_auth_credentials_store = "file"
    \(root)
    [model_providers.\(provider)]
    name = "合成自定义服务"
    base_url = "\(endpoint)"
    requires_openai_auth = true
    \(providerFields)
    """
  }

  func testExplicitCustomCPAProviderImportsOnlyAPIKey() throws {
    let importer = try CodexCredentialImport(configuration: configuration())
    XCTAssertEqual(try importer.apiKey(from: authentication), "synthetic-cpa-key")
    let trailingSlash = try CodexCredentialImport(configuration: configuration(endpoint: "https://cpa.bgp.kiliter.cn/v1/"))
    XCTAssertEqual(try trailingSlash.apiKey(from: authentication), "synthetic-cpa-key")
  }

  func testInactiveCPAProviderAndCommentCannotAuthorizeImport() {
    let inactive = configuration(provider: "other", endpoint: "https://example.invalid/v1") + """

    [model_providers.cpa]
    base_url = "https://cpa.bgp.kiliter.cn/v1"
    requires_openai_auth = true
    """
    XCTAssertThrowsError(try CodexCredentialImport(configuration: inactive))
    let commentOnly = """
    model_provider = "openai"
    cli_auth_credentials_store = "file"
    # base_url = "https://cpa.bgp.kiliter.cn/v1"
    """
    XCTAssertThrowsError(try CodexCredentialImport(configuration: commentOnly))
  }

  func testMultilineStringCannotSpoofAProviderTable() {
    let config = #"""
    model_provider = "openai"
    cli_auth_credentials_store = "file"
    model_instructions = '''
    model_provider = "cpa"
    [model_providers.cpa]
    base_url = "https://cpa.bgp.kiliter.cn/v1"
    requires_openai_auth = true
    '''
    """#
    XCTAssertThrowsError(try CodexCredentialImport(configuration: config))
  }

  func testEnvironmentAndCommandAuthenticationAreNeverReadFromAuthFile() {
    for fields in [
      "env_key = \"CUSTOM_CPA_KEY\"",
      "env_key = \"OPENAI_API_KEY\"",
      "experimental_bearer_token = \"synthetic-other-key\"",
      "[model_providers.custom-cpa.auth]\ncommand = \"never-run-this\"",
      "[model_providers.custom-cpa.http_headers]\nAuthorization = \"synthetic-header\"",
      "[model_providers.custom-cpa.env_http_headers]\nAuthorization = \"CUSTOM_AUTH\"",
    ] {
      XCTAssertThrowsError(try CodexCredentialImport(configuration: configuration(providerFields: fields)))
    }
  }

  func testAmbiguousStoresProfilesAndDefaultAuthenticationAreRejected() {
    for store in ["auto", "keyring", "ephemeral"] {
      XCTAssertThrowsError(try CodexCredentialImport(configuration:
        configuration().replacingOccurrences(of: "cli_auth_credentials_store = \"file\"", with: "cli_auth_credentials_store = \"\(store)\"")))
    }
    XCTAssertThrowsError(try CodexCredentialImport(configuration:
      configuration().replacingOccurrences(of: "cli_auth_credentials_store = \"file\"", with: "")))
    XCTAssertThrowsError(try CodexCredentialImport(configuration:
      configuration().replacingOccurrences(of: "requires_openai_auth = true", with: "")))
    XCTAssertThrowsError(try CodexCredentialImport(configuration: configuration(root: "profile = \"another-service\"")))
    XCTAssertThrowsError(try CodexCredentialImport(configuration: configuration(root: "forced_login_method = \"chatgpt\"")))
  }

  func testUnrecognizedSyntaxDuplicateKeysAndEndpointLookalikesFailClosed() {
    for endpoint in ["https://cpa.bgp.kiliter.cn.evil.invalid/v1", "https://example.invalid/#https://cpa.bgp.kiliter.cn/v1",
                     "https://cpa.bgp.kiliter.cn/v1?api_key=synthetic", "http://cpa.bgp.kiliter.cn/v1"] {
      XCTAssertThrowsError(try CodexCredentialImport(configuration: configuration(endpoint: endpoint)))
    }
    XCTAssertThrowsError(try CodexCredentialImport(configuration: configuration(root: "model_provider = \"other\"")))
    XCTAssertThrowsError(try CodexCredentialImport(configuration: configuration(providerFields: "http_headers = { X-Test = \"value\" }")))
    XCTAssertThrowsError(try CodexCredentialImport(configuration:
      configuration(providerFields: "[model_providers.\"custom-cpa\"]\nenv_key = \"OTHER_KEY\"")))
    XCTAssertThrowsError(try CodexCredentialImport(configuration:
      configuration(providerFields: "[model_providers . custom-cpa]\nenv_key = \"OTHER_KEY\"")))
  }

  func testOAuthTokensUnknownModesAndMissingKeysCannotBeImported() throws {
    let importer = try CodexCredentialImport(configuration: configuration())
    for json in [
      #"{"auth_mode":"chatgpt","OPENAI_API_KEY":"synthetic-other-key"}"#,
      #"{"auth_mode":"apikey","OPENAI_API_KEY":"synthetic-key","tokens":{"access_token":"synthetic-token"}}"#,
      #"{"OPENAI_API_KEY":"  "}"#,
      #"{"tokens":{"access_token":"synthetic-token"}}"#,
      #"{"auth_mode":"unknown","OPENAI_API_KEY":"synthetic-key"}"#,
      "invalid-json",
    ] {
      XCTAssertThrowsError(try importer.apiKey(from: Data(json.utf8))) { error in
        XCTAssertTrue(error.localizedDescription.contains("请手动填写"))
        XCTAssertFalse(error.localizedDescription.contains("synthetic-"))
      }
    }
  }
}
