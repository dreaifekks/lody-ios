import UIKit

/// The owning session supplies catalog context; previews replace only navigation/URL I/O.
@MainActor
struct SessionMessageLinkService {
  var isLAN: () -> Bool
  var openSession: (String, String?, SessionSource, UIViewController) -> Void
  var openURL: (URL) -> Void
  /// Optional override for offline link fixtures; live sessions use `SessionController.openFile`.
  var openFile: (@MainActor (String, String, Int, UIViewController) async -> Void)?
  var notice: (String, UIViewController) -> Void

  static let live = SessionMessageLinkService(
    isLAN: { AuthSession.shared.snapshot.account?.lan != nil },
    openSession: { SessionNavigation.openMessageSession($0, turnId: $1, source: $2, from: $3) },
    openURL: { UIApplication.shared.open($0) },
    openFile: nil,
    notice: { message, _ in
      LodyToastOverlay.shared.show(message: message, kind: .neutral)
    }
  )
}
