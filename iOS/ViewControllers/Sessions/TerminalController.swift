import LodyData
import UIKit

@MainActor
class TerminalController: UIViewController {
  private let terminal: LodyTerminalView
  private let authorized: @MainActor () -> Bool
  private var ended = false

  /// Source and endpoint come from the current session catalog, never route parameters.
  static func live(state: SessionListState, sessionId: String) -> TerminalController? {
    guard let session = state.catalog.session(sessionId),
          let endpoint = state.catalog.machineTerminals[session.machineId],
          let invite = LanHub.credential(for: state.workspaceId),
          AuthSession.shared.snapshot.account?.lan?.id == invite.id,
          AuthSession.shared.snapshot.account?.user.id == state.userId else { return nil }
    let key = LanTerminalProtocol.key(token: invite.token)
    let authorized: @MainActor () -> Bool = {
      guard let account = AuthSession.shared.snapshot.account,
            account.user.id == state.userId, account.lan?.id == invite.id,
            let current = LanHub.credential(for: state.workspaceId) else { return false }
      return LanTerminalProtocol.key(token: current.token) == key
    }
    return TerminalController(sessionId: sessionId, authorized: authorized) { event, closed in
      guard authorized(), let current = LanHub.credential(for: state.workspaceId) else { return nil }
      return NativeTerminalChannel(endpoint: endpoint, invite: current, machineId: session.machineId,
        event: event, closed: closed)
    }
  }

  /// Used by the terminal's isolated offline fixture as well as live assembly.
  init(sessionId: String, authorized: @escaping @MainActor () -> Bool, factory: @escaping LodyTerminalView.Factory) {
    self.authorized = authorized
    terminal = LodyTerminalView(sessionId: sessionId, factory: factory)
    super.init(nibName: nil, bundle: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(accountChanged), name: .lodyAuthDidChange, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(pageClosed), name: .lodyPageDidClose, object: nil)
  }
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }
  isolated deinit { terminal.end(); NotificationCenter.default.removeObserver(self) }

  override func loadView() { view = terminal }
  override func viewDidLoad() {
    super.viewDidLoad()
    LodyScrollEdges.bind(terminal.scrollView, to: self)
    terminal.onState = { [weak self] state, title in
      guard let self else { return }
      let item = parent?.navigationItem ?? navigationItem
      item.title = title?.isEmpty == false ? title : String(localized: "terminal.menu", bundle: .lody)
      view.accessibilityValue = state.rawValue
    }
  }
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !ended, authorized() else { return finish() }
    terminal.begin()
  }
  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    // UIKit does not call this on a cancelled interactive pop. Do not stop in
    // viewWillDisappear or didMoveToWindow: both run during a cancelled gesture.
    if parent?.isMovingFromParent == true || parent?.isBeingDismissed == true
      || navigationController?.isBeingDismissed == true || parent == nil { finish() }
  }
  @objc private func pageClosed(_ notification: Notification) {
    guard let page = notification.object as? PageContainerController, page === parent else { return }
    finish()
  }
  @objc private func accountChanged() { if !authorized() { finish() } }
  private func finish() { ended = true; terminal.end() }
}
