import Foundation

public struct CatalogModel: Codable, Identifiable, Hashable {
  public var id: String
  public var name: String
  public var context: Int?
  public var maxContext: Int?
  public var outputLimit: Int?
  public var effectivePercent: Int
  public var reasoningLevels: [String]
  public var defaultReasoning: String?
  public var native: Bool
  public var inputBudget: Int {
    let window = max(0, context ?? 16384), percent = min(100, max(1, effectivePercent))
    // 目录为外部输入；先除再合并余数，避免超大上下文乘百分比造成整数溢出。
    let effective = window / 100 * percent + (window % 100) * percent / 100
    return max(512, min(24000, effective - min(max(0, outputLimit ?? 4096), 4096) - 2000))
  }
}
public enum ModelCatalog {
  public static let baseURL = URL(string: "https://cpa.bgp.kiliter.cn/v1")!
  public static let catalogURL = URL(string: "https://cpa.bgp.kiliter.cn/v1/models")!
  public static func requestURL(_ url: URL = catalogURL) throws -> URL {
    guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == "https",
      c.host == "cpa.bgp.kiliter.cn"
    else { throw AppFailure.message("模型目录地址无效") }
    var q = (c.queryItems ?? []).filter { $0.name != "client_version" }
    q.append(URLQueryItem(name: "client_version", value: "0.134.0"))
    c.queryItems = q
    guard let result = c.url else { throw AppFailure.message("模型目录地址无效") }
    return result
  }
  public static func parse(_ data: Data) throws -> [CatalogModel] {
    guard data.count < 8 * 1024 * 1024,
      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw AppFailure.message("模型目录过大或格式错误") }
    let native = root["models"] != nil
    guard let rows = (root["models"] ?? root["data"]) as? [[String: Any]] else {
      throw AppFailure.message("模型目录缺少 models 字段")
    }
    var seen = Set<String>()
    let models = rows.compactMap { row -> CatalogModel? in
      let id = native ? row.string("slug") : row.string("id")
      guard !id.isEmpty, row.string("visibility") != "hide", row.string("visibility") != "hidden",
        row["supported_in_api"] as? Bool != false, seen.insert(id).inserted
      else { return nil }
      let context = row.int("context_window")
      let maxContext = row.int("max_context_window")
      let output = row.int("max_tokens")
      let levels = (row["supported_reasoning_levels"] as? [[String: Any]] ?? []).map {
        $0.string("effort")
      }.filter { !$0.isEmpty }
      return CatalogModel(
        id: id, name: row.string("display_name").isEmpty ? id : row.string("display_name"),
        context: context > 0 ? context : nil, maxContext: maxContext > 0 ? maxContext : nil,
        outputLimit: output > 0 ? output : nil,
        effectivePercent: min(100, max(1, row["effective_context_window_percent"] as? Int ?? 95)),
        reasoningLevels: levels, defaultReasoning: row["default_reasoning_level"] as? String,
        native: native)
    }
    guard !models.isEmpty else { throw AppFailure.message("模型目录为空") }
    return models
  }
}
