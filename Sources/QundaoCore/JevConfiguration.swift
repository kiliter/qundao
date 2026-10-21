import Foundation

public enum JevAPI: String, Codable, CaseIterable {
  case decisions, systemOne
  public var title: String { self == .decisions ? "Decisions API" : "System One API" }
}

public struct JevConfiguration: Equatable {
  public var baseURL: String
  public var api: JevAPI
  public var model: String
  public static let openRouter = JevConfiguration(baseURL: "https://openrouter.ai/api", api: .decisions, model: "~typesafe/jev-latest")
  public static let typeSafe = JevConfiguration(baseURL: "https://api.typesafe.ai/v1", api: .systemOne, model: "jev-latest")
  public init(baseURL: String, api: JevAPI, model: String) {
    self.baseURL = baseURL; self.api = api; self.model = model
  }
  public func endpoint() throws -> URL {
    let input = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !input.contains(where: { $0.isWhitespace }),
          var url = URLComponents(string: input), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
          let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
          url.query == nil, url.fragment == nil else {
      throw AppFailure.message("请输入有效的 HTTP / HTTPS Base URL，不包含密钥、查询参数或片段")
    }
    guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AppFailure.message("请填写 Jev 模型名称")
    }
    var path = url.path
    while path.hasSuffix("/") { path.removeLast() }
    if path.hasSuffix("/systemone") || path.hasSuffix("/decisions") {
      guard (api == .systemOne && path.hasSuffix("/systemone")) || (api == .decisions && path.hasSuffix("/decisions")) else {
        throw AppFailure.message("完整接口地址与所选协议不一致，请检查协议")
      }
    } else if host.lowercased() == "openrouter.ai", ["", "/api", "/api/v1"].contains(path) {
      path = api == .decisions ? "/api/alpha/decisions" : "/api/v1/systemone"
    } else {
      path += api == .decisions ? "/alpha/decisions" : "/systemone"
    }
    url.path = path
    guard let result = url.url else { throw AppFailure.message("决策服务地址无效") }
    return result
  }
}
