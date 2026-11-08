import UIKit

/// The owning session supplies catalog context; previews replace only navigation/URL I/O.
@MainActor
struct SessionMessageLinkService {
  var isLAN: () -> Bool
  var openSession: (String, SessionSource, UIViewController) -> Void
  var openURL: (URL) -> Void
  var openFile: @MainActor (String, String, Int, UIViewController) async -> Void
  var notice: (String, UIViewController) -> Void

  static let live = SessionMessageLinkService(
    isLAN: { AuthSession.shared.snapshot.account?.lan != nil },
    openSession: { SessionNavigation.openMessageSession($0, source: $1, from: $2) },
    openURL: { UIApplication.shared.open($0) },
    openFile: { sessionId, path, line, controller in
      if let runtime = DataRuntime.current,
         await FilePreviewCoordinator.open(sessionId: sessionId, path: path, line: line, runtime: runtime, from: controller) { return }
      guard controller.view.window != nil else { return }
      let content = PageFactory.make("file-content", params: SessionController.json(["sessionId": sessionId, "path": path, "line": line]))!
      LodyShell.shared.presentDetail(content, title: content.title ?? "", from: controller, push: false, detents: [1])
    },
    notice: { message, controller in
      LodyToastOverlay.shared.show(message: message, kind: "info", below: controller.navigationController?.navigationBar)
    }
  )
}
