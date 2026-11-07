import Foundation
import Security

public enum AuthKeychain: Sendable {
  public static let lanHub = "lan-hub"
  public static let cloudSession = "better-auth-session"

  private static func query(_ account: String) -> [String: Any] { [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "app.innei.lody.auth",
    kSecAttrAccount as String: account,
  ] }
  public static func read(account: String = cloudSession) throws -> String? {
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
  public static func save(_ token: String, account: String = cloudSession) throws {
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
  public static func clear(account: String = cloudSession) throws {
    let status = SecItemDelete(query(account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
  }
}
