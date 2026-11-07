import UIKit

/// LAN shares the production picker, paste and camera flows. Only the total
/// attachment budget differs from Cloud; rejecting a send retains the draft.
@MainActor
enum LanComposerPolicy {
  static var isLAN: Bool { AuthSession.shared.snapshot.account?.lan != nil }

  static func apply(to view: UIView, lan: @escaping @MainActor () -> Bool = { isLAN }) {
    if let composer = view as? ChatComposerView {
      composer.attachmentLimit = { lan() ? 8 : 16 }
      composer.attachmentImportIdentity = {
        AttachmentUIIdentity.current
      }
    }
    for child in view.subviews {
      if child.accessibilityIdentifier == "session-attach" { child.isHidden = false }
      apply(to: child, lan: lan)
    }
  }

  static func rejects(_ payload: [String: Any], lan: Bool? = nil) -> Bool {
    guard lan ?? isLAN, let attachments = payload["attachments"] as? [Any], attachments.count > 8 else { return false }
    unavailable()
    return true
  }

  static func unavailable() {
    LodyToastOverlay.shared.show(message: String(localized: "native.attachment.error.lanLimit", bundle: .lody), kind: "info")
  }
}

/// App-owned selection resolves the workspace; LodyData only receives an
/// explicit workspace and never imports UIKit or SessionSource.live.
@MainActor
enum AttachmentUIIdentity {
  static var current: String {
    AuthSession.shared.attachmentIdentity(workspace: SessionSource.live.state.workspaceId) ?? "signed-out"
  }
}
