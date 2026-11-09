import LodyCore
import Foundation

/// Fixture scenes require `--ui-verify`. Offline behavior also accepts
/// `--lody-offline` or the explicit verification environment flag so a system
/// cold launch can stay offline without enabling fixture scenes.
public enum LodyUIVerify: Sendable {
  public static var enabled: Bool { has("--ui-verify") }
  public static var offline: Bool { enabled || has("--lody-offline") || environmentOffline }
  private static let environmentOffline: Bool = {
    guard ProcessInfo.processInfo.environment["LODY_VERIFY_OFFLINE"] == "1" else { return false }
    // One process-scoped observation for cold-launch acceptance; no credentials.
    NSLog("LodyUIVerify environment offline enabled")
    return true
  }()
  public static var home: Bool { enabled && has("--ui-verify-home") }
  public static var mentions: Bool { enabled && has("--ui-verify-mentions") }
  public static var throwProbe: Bool { enabled && has("--ui-verify-throw") }
  public static var offscreen: Bool { enabled && has("--ui-verify-offscreen") }
  public static var scroll: Bool {
    enabled && (has("--ui-verify-scroll") || has("--ui-verify-opening"))
  }

  public static func has(_ flag: String) -> Bool {
    ProcessInfo.processInfo.arguments.contains(flag)
  }
}
