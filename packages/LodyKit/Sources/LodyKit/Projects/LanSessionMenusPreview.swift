import UIKit

/// Real project rows and context previews, with a credential-free LAN scope.
@MainActor
final class LanSessionMenusPreview: ProjectController {
  private let activeTools: [UIMenuElement]
  private let archivedTools: [UIMenuElement]

  init() {
    let invite = LanInvite(url: "http://127.0.0.1:8788", token: "offline-session-menus", name: "Offline LAN")
    let account = AuthAccount.lanAccount(invite)
    let sessions = [
      SessionItem(id: "lan-menu-active", title: "LAN cached conversation", status: "idle", projectId: "lan-menu-project", machineId: "lan-menu-machine"),
      SessionItem(id: "lan-menu-archived", title: "Archived LAN conversation", status: "completed", archived: true,
        projectId: "lan-menu-project", machineId: "lan-menu-machine"),
    ]
    let catalog = SessionCatalog(projects: [.init(id: "lan-menu-project", name: "LAN Project")], sessions: sessions,
      machineTerminals: ["lan-menu-machine": .init(host: "127.0.0.1", port: 12345)])
    let state = SessionListState(userId: account.user.id, workspaceId: invite.workspaceId, catalog: catalog)
    let source = SessionSource(changes: [], read: { state }, write: { _, _, _ in })
    activeTools = SessionController(sessionId: "lan-menu-active", source: source).terminalMenu(account: account)
    archivedTools = SessionController(sessionId: "lan-menu-archived", source: source).terminalMenu(account: account)
    precondition(activeTools.count == 1 && archivedTools.isEmpty)
    LocalStore.queue.sync {
      for session in sessions {
        let key = "session:" + String(decoding: try! JSONSerialization.data(withJSONObject: [account.user.id, invite.workspaceId, session.id], options: .withoutEscapingSlashes), as: UTF8.self)
        try! LocalStore.shared.write(key, #"{"v":1,"status":"live","revision":1,"entries":[{"id":"cached-turn","role":"assistant","status":"completed","finished":true,"items":[{"itemId":"cached-answer","type":"text","text":"Cached LAN answer stays available offline."}]}]}"#)
      }
    }
    super.init(projectId: "lan-menu-project", source: source)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func render() {
    super.render()
    let rename = { UIAction(title: String(localized: "session.action.rename", bundle: .lody)) { _ in } }
    let active = UIBarButtonItem(title: "Active tools", menu: UIMenu(children: [rename()] + activeTools))
    active.accessibilityIdentifier = "lan-menu-active-tools"
    let archived = UIBarButtonItem(title: "Archived tools", menu: UIMenu(children: [rename()] + archivedTools))
    archived.accessibilityIdentifier = "lan-menu-archived-tools"
    (parent ?? self).navigationItem.leftBarButtonItems = [active, archived]
  }
}
