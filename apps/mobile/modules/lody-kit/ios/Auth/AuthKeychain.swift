import Foundation
import Security

enum AuthKeychain {
  static let session = "better-auth-session"
  static let lanHub = "lan-hub"
  private static func query(_ account: String) -> [String: Any] { [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "app.innei.lody.auth",
    kSecAttrAccount as String: account,
  ] }
  static func read(account: String = session) throws -> String? {
    var request = query(account)
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
    return token
  }
  static func save(_ token: String, account: String = session) throws {
    guard !token.isEmpty else { throw NSError(domain: "LodyKit.Auth", code: 1) }
    let values = [kSecValueData as String: Data(token.utf8)]
    var status = SecItemUpdate(query(account) as CFDictionary, values as CFDictionary)
    if status == errSecItemNotFound {
      var item = query(account).merging(values) { _, value in value }
      item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      status = SecItemAdd(item as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
  }
  static func clear(account: String = session) throws {
    let status = SecItemDelete(query(account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
  }
}
