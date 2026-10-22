import Foundation

/// 只导入配置明确指向 CPA、且明确使用文件 API Key 的 Codex 配置。
/// 复用严格 TOML 子集解析器；无法识别的语法或认证方式安全失败，不猜测凭据来源。
public struct CodexCredentialImport {
  private static let endpoint = "https://cpa.bgp.kiliter.cn/v1"

  public init(configuration: String) throws {
    let values: [String: TOMLValue]
    do {
      var parser = TOMLParser(configuration)
      values = try parser.parse()
    } catch {
      throw Self.failure("配置包含无法安全解析的 TOML 语法")
    }
    // 现有子集不解码引号表名或表名中的空白。出现这类键路径时不能漏掉认证覆盖项。
    guard values.keys.allSatisfy({ key in
      key.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { Self.isBareName(String($0)) }
    }) else { throw Self.failure("配置包含暂不支持的 TOML 表名") }
    guard let provider = values["model_provider"]?.string, !provider.isEmpty,
          !["openai", "ollama", "lmstudio", "amazon-bedrock"].contains(provider),
          Self.isBareName(provider) else { throw Self.failure("未明确选择可识别的自定义模型服务") }
    guard values["profile"] == nil else {
      throw Self.failure("使用了 profile，无法确认当前模型服务")
    }
    let prefix = "model_providers.\(provider)."
    guard let endpoint = values[prefix + "base_url"]?.string,
          endpoint == Self.endpoint || endpoint == Self.endpoint + "/" else {
      throw Self.failure("当前模型服务并未指向 CPA")
    }
    // env_key 指向进程环境，不能据此读取 auth.json；auto / keyring 也可能选用其他凭据。
    guard values["cli_auth_credentials_store"]?.string == "file",
          values[prefix + "requires_openai_auth"]?.bool == true else {
      throw Self.failure("未明确使用文件中的 API Key 认证")
    }
    if let method = values["forced_login_method"], method.string != "api" {
      throw Self.failure("认证方式不是 API Key")
    }
    let unsupported = ["env_key", "experimental_bearer_token", "auth", "http_headers", "env_http_headers"]
    guard !values.keys.contains(where: { key in
      unsupported.contains { field in key == prefix + field || key.hasPrefix(prefix + field + ".") }
    }) else { throw Self.failure("模型服务配置了其他凭据或自定义请求头") }
  }

  /// 先验证配置，再由调用方读取 auth.json。不会执行认证命令、读环境密钥或访问钥匙串。
  public func apiKey(from authentication: Data) throws -> String {
    guard let object = try? JSONSerialization.jsonObject(with: authentication) as? [String: Any],
          let key = object["OPENAI_API_KEY"] as? String,
          !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw Self.failure("文件中没有可导入的 API Key")
    }
    if let mode = object["auth_mode"], mode as? String != "apikey" {
      throw Self.failure("认证文件当前不是 API Key 模式")
    }
    if let tokens = object["tokens"], !(tokens is NSNull) {
      throw Self.failure("认证文件还包含登录凭据，无法确认密钥来源")
    }
    return key.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func failure(_ reason: String) -> AppFailure {
    .message("无法从 Codex 导入 CPA 密钥：\(reason)。请手动填写 CPA API Key。")
  }

  private static func isBareName(_ value: String) -> Bool {
    !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
      (48...57).contains(scalar.value) || (65...90).contains(scalar.value)
        || (97...122).contains(scalar.value) || scalar == "_" || scalar == "-"
    }
  }
}
