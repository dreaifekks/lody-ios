import UIKit

@MainActor
final class AccountController: UIViewController {
  private let list = LodyGroupedList(frame: .zero)
  private let source: SettingsSource
  private let connectionService: ConnectionService
  private let latency: HubLatencyObserver
  private var observers: [NSObjectProtocol] = []

  init(source: SettingsSource = .live, connectionService: ConnectionService = .live) {
    self.source = source
    self.connectionService = connectionService
    latency = HubLatencyObserver(service: connectionService)
    super.init(nibName: nil, bundle: nil)
    title = String(localized: "account.title", bundle: .lody)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  isolated deinit { observers.forEach(NotificationCenter.default.removeObserver) }

  override func viewDidLoad() {
    super.viewDidLoad()
    list.frame = view.bounds
    list.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    list.setPlaceholder(String(localized: "account.placeholder", bundle: .lody))
    list.forwarded = { [weak self] name, body in
      guard name == "rowPress", let self, let id = body["id"] as? String else { return }
      if id == "logout" { self.confirmLogout() }
      if id == "hub" {
        LodyShell.shared.push(ConnectionController(source: self.source, service: self.connectionService),
          title: SettingsSections.text("section.connection"), from: self)
      }
    }
    view.addSubview(list)
    for name in source.changes {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.render() }
      })
    }
    latency.changed = { [weak self] in self?.render() }
    render()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    latency.start(source.state.account?.lan)
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    latency.stop()
  }

  private func render() {
    let state = source.state
    guard let account = state.account else {
      list.setSections([])
      let page = parent ?? self
      if let navigation = page.navigationController, let index = navigation.viewControllers.firstIndex(of: page), index > 0 {
        navigation.popToViewController(navigation.viewControllers[index - 1], animated: true)
      }
      return
    }
    title = account.lan == nil ? String(localized: "account.title", bundle: .lody) : String(localized: "lan.leave.action", bundle: .lody)
    var user = LodyListRow()
    user.id = "name"
    user.title = account.user.name
    user.subtitle = account.user.email
    user.image = account.user.image ?? "person.crop.circle"
    var logout = LodyListRow()
    logout.id = "logout"
    logout.title = String(localized: String.LocalizationValue(state.busy ? "account.signingOut" : "account.signOut"), bundle: .lody)
    if account.lan != nil { logout.title = String(localized: "lan.leave.action", bundle: .lody) }
    logout.destructive = true
    logout.action = !state.busy
    var profile = LodyListSection()
    profile.id = "account"
    profile.rows = [user]
    var actions = LodyListSection()
    actions.id = "logout"
    actions.footer = state.error ?? ""
    actions.rows = [logout]
    if let lan = account.lan {
      if viewIfLoaded?.window != nil { latency.start(lan) }
      var hub = LodyListRow()
      hub.id = "hub"
      hub.title = lan.name
      hub.subtitle = lan.url.replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
      hub.value = latency.value.text
      hub.image = "server.rack"
      hub.action = true
      hub.disclosure = true
      hub.navigates = true
      profile.rows = [hub]
    }
    list.setSections([profile, actions])
  }

  private func confirmLogout() {
    let lan = source.state.account?.lan != nil
    let alert = UIAlertController(
      title: String(localized: "account.signOutConfirm.title", bundle: .lody), message: String(localized: "account.signOutConfirm.message", bundle: .lody),
      preferredStyle: .alert
    )
    if lan { alert.title = String(localized: "lan.leave.action", bundle: .lody); alert.message = String(localized: "lan.leave.hint", bundle: .lody) }
    alert.addAction(UIAlertAction(title: String(localized: "common.cancel", bundle: .lody), style: .cancel))
    alert.addAction(UIAlertAction(title: lan ? String(localized: "lan.leave.action", bundle: .lody) : String(localized: "account.signOut", bundle: .lody), style: .destructive) { [weak self] _ in
      guard let self else { return }
      Task { await self.source.logout() }
    })
    present(alert, animated: true)
  }
}
