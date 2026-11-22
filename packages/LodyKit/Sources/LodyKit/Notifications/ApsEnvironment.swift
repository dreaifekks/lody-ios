import Foundation

/// The APNs environment a device token belongs to. A token only works against
/// the environment its app was signed for, so the LAN host needs to know it.
enum ApsEnvironment {
  /// Reads `aps-environment` from an `embedded.mobileprovision`; a build
  /// without one (App Store) or without the entitlement uses production.
  static func of(profile: Data?) -> String {
    guard let profile else { return "production" }
    let text = String(decoding: profile, as: UTF8.self)
    guard let key = text.range(of: "<key>aps-environment</key>"),
          let open = text.range(of: "<string>", range: key.upperBound..<text.endIndex),
          let close = text.range(of: "</string>", range: open.upperBound..<text.endIndex) else { return "production" }
    return text[open.upperBound..<close.lowerBound] == "development" ? "development" : "production"
  }

  static let current: String = {
    #if targetEnvironment(simulator)
    return "development"
    #else
    let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
    return of(profile: url.flatMap { try? Data(contentsOf: $0) })
    #endif
  }()
}
