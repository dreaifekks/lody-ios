import UIKit

/// App policy for the shared composer; both app hosts install it without changing
/// the credential-free Share Extension's composer or keyboard ownership.
@MainActor
enum LanComposerPolicy {
  private final class State: NSObject {
    var read: @MainActor () -> Bool = { LanComposerPolicy.isLAN }
  }
  private static let installed = NSMapTable<ChatComposerInput, State>.weakToStrongObjects()

  static var isLAN: Bool { AuthSession.shared.snapshot.account?.lan != nil }

  static func apply(to view: UIView, lan: @escaping @MainActor () -> Bool = { isLAN }) {
    for child in view.subviews {
      if child.accessibilityIdentifier == "session-attach" { child.isHidden = lan() }
      if let input = child as? ChatComposerInput {
        if let state = installed.object(forKey: input) { state.read = lan; continue }
        let state = State()
        state.read = lan
        installed.setObject(state, forKey: input)
        let paste = input.onPasteItems
        let longText = input.onPasteLongText
        input.onPasteItems = { providers in
          if state.read(), ChatAttachment.canPaste(providers) {
            unavailable()
            return true
          }
          return paste?(providers) ?? false
        }
        input.onPasteLongText = { value in
          if state.read() { return false }
          return longText?(value) ?? false
        }
      }
      apply(to: child, lan: lan)
    }
  }

  static func rejects(_ payload: [String: Any], lan: Bool? = nil) -> Bool {
    guard lan ?? isLAN, let attachments = payload["attachments"] as? [Any], !attachments.isEmpty else { return false }
    unavailable()
    return true
  }

  static func unavailable() {
    LodyToastOverlay.shared.show(message: String(localized: "lan.attachments.unavailable", bundle: .lody), kind: "info")
  }
}
