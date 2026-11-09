import Foundation

// Isolated dependencies for AuthSession's state-machine check. This executable
// never reads the user's Keychain, disk cache, browser, credentials or network.
public enum AuthKeychain {
  public static let lanHub = "lan-hub"
  private static let lock = NSLock()
  nonisolated(unsafe) private static var values: [String: String] = [:]
  public static func read(account: String = "cloud") throws -> String? { lock.withLock { values[account] } }
  nonisolated(unsafe) private static var failingAccount: String?
  public static func failNextSave(account: String) { lock.withLock { failingAccount = account } }
  public static func save(_ value: String, account: String = "cloud") throws {
    try lock.withLock {
      if failingAccount == account { failingAccount = nil; throw AuthFailure(message: "synthetic_keychain_failure") }
      values[account] = value
    }
  }
  public static func clear(account: String = "cloud") throws { _ = lock.withLock { values.removeValue(forKey: account) } }
}
public enum LodyUIVerify { public static let enabled = false; public static let offline = false }
public struct AuthCatalogScope: Sendable {
  public let account: AuthAccount?
  public let localReady: Bool
  public let initialWorkspace: String
  public let initialCatalog: String?
}
public final class LocalStore: @unchecked Sendable {
  public static let shared = LocalStore()
  public static let queue = DispatchQueue(label: "lan-auth-test-store")
  private let lock = NSLock()
  private var values: [String: String] = [:]
  private var version = 0
  nonisolated(unsafe) public static var failClear = false
  public var generation: Int { lock.withLock { version } }
  public func startup() throws -> [String: String] { lock.withLock { values } }
  public func clear() throws {
    if Self.failClear { throw AuthFailure(message: "synthetic_clear_failure") }
    lock.withLock { values = [:]; version += 1 }
  }
  public func write(_ key: String, _ value: String, generation: Int? = nil) throws {
    lock.withLock {
      guard generation == nil || generation == version else { return }
      values[key] = value
    }
  }
}
