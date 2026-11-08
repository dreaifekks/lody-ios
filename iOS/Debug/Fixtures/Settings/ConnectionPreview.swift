import UIKit

@MainActor
enum ConnectionPreview {
  static func make(settings: Bool) -> UIViewController {
    final class Fixture {
      var fail = true
      var synced = false
      let lan = LanHubSummary(LanInvite(url: "http://hub.example.test:8788", token: "offline-fixture", name: "Preview LAN"))
      var state: SettingsState {
        let workspace = AuthWorkspace(id: lan.workspaceId, name: lan.name, slug: nil, image: nil)
        var account = AuthAccount(user: AuthUser(id: lan.userId, name: lan.name, email: "hub.example.test:8788", image: nil), workspaces: [workspace])
        account.lan = lan
        return SettingsState(account: account, workspace: workspace,
          connection: SettingsConnection(state: synced ? "live" : "offline", machines: 2, syncedAt: LodyRelativeTime.now() - 60_000))
      }
    }
    let fixture = Fixture()
    let change = Notification.Name("LodyConnectionPreviewChanged")
    let source = SettingsSource(changes: [change], read: { fixture.state }, refresh: {
      fixture.synced = true
      NotificationCenter.default.post(name: change, object: nil)
    }, logout: {})
    let service = ConnectionService(machines: { _ in
      if fixture.fail {
        fixture.fail = false
        throw SettingsError("fixture")
      }
      return [
        .init(id: "online", name: "mini.local", alias: "Online Mini", os: "macOS", version: "0.109.0-lan.3", online: true),
        .init(id: "offline", name: "nuc.local", alias: "Offline NUC", os: "Linux", version: "0.109.0-lan.2", online: false),
      ]
    }, ping: { _, id in
      if id == "online" { throw SettingsError("no answer") }
      // A successful ping must not promote a member without a fresh heartbeat.
      return 7
    }, latency: { _ in 18 }, presence: { fixture.synced ? "live" : "unknown" })
    if settings { return SettingsController(source: source, connectionService: service) }
    return ConnectionController(source: source, service: service)
  }

  static func joinErrors() -> UIViewController {
    var attempts = 0
    return JoinLanController(join: { _ in
      attempts += 1
      switch attempts {
      case 1: throw LanInvite.Failure.invalidInvite
      case 2: throw LanHub.Failure.unauthorized
      case 3: throw LanHub.Failure.unreachable(nil)
      default: return
      }
    })
  }
}
