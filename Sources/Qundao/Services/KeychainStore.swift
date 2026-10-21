import Foundation
import QundaoCore
import Security

struct KeychainStore {
  static let service = "cn.kiliter.qundao"
  static func get(_ account: String) -> String {
    let q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: account, kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else { return "" }
    return String(data: data, encoding: .utf8) ?? ""
  }
  static func set(_ value: String, account: String) throws {
    let q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let data = Data(value.utf8)
    let result = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if result == errSecItemNotFound {
      var add = q
      add[kSecValueData as String] = data
      add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let s = SecItemAdd(add as CFDictionary, nil)
      guard s == errSecSuccess else { throw AppFailure.message("钥匙串保存失败（\(s)）") }
    } else if result != errSecSuccess {
      throw AppFailure.message("钥匙串更新失败（\(result)）")
    }
  }
  static func codexCPAKey() throws -> String {
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    // 仅允许用户明确点击导入；从既有 CPA 配置读取，绝不导入 ChatGPT 登录凭据。
    let config = try String(contentsOf: root.appendingPathComponent("config.toml"), encoding: .utf8)
    guard config.contains("https://cpa.bgp.kiliter.cn/v1") else {
      throw AppFailure.message("Codex 中未找到 CPA 配置")
    }
    let data = try Data(contentsOf: root.appendingPathComponent("auth.json"))
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let key = obj["OPENAI_API_KEY"] as? String, !key.isEmpty
    else { throw AppFailure.message("Codex 中没有可导入的 API Key，请手动填写") }
    return key
  }
}
