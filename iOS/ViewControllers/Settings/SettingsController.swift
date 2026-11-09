import UIKit

@MainActor
class SettingsController: UIViewController {
  let list = LodyGroupedList(frame: .zero)
  let source: SettingsSource
  private let connectionService: ConnectionService
  private let latency: HubLatencyObserver
  private var state = SettingsState()
  private var observers: [NSObjectProtocol] = []

  init(source: SettingsSource = .live, connectionService: ConnectionService = .live) {
    self.source = source
    self.connectionService = connectionService
    latency = HubLatencyObserver(service: connectionService)
    super.init(nibName: nil, bundle: nil)
    title = String(localized: "tabs.settings", bundle: .lody)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  isolated deinit { observers.forEach(NotificationCenter.default.removeObserver) }

  override func viewDidLoad() {
    super.viewDidLoad()
    list.frame = view.bounds
    list.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    list.setPlaceholder("")
    list.forwarded = { [weak self] name, body in
      guard name == "rowPress", let id = body["id"] as? String else { return }
      self?.open(id)
    }
    view.addSubview(list)
    for name in source.changes + [UIApplication.didBecomeActiveNotification] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          if name == UIApplication.didBecomeActiveNotification, self.viewIfLoaded?.window != nil {
            self.latency.stop()
            self.latency.start(self.source.state.account?.lan)
          }
          self.render()
        }
      })
    }
    latency.changed = { [weak self] in self?.render() }
    render()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    latency.start(source.state.account?.lan)
    render()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    latency.stop()
  }

  func render() {
    state = source.state
    if viewIfLoaded?.window != nil { latency.start(state.account?.lan) }
    let value = latency.value == .measuring ? nil : latency.value.text
    list.setSections(SettingsSections.make(state, hubLatency: value))
  }

  private func open(_ id: String) {
    if state.account?.lan != nil, ["workspace-general", "prompt-shortcuts", "project-visibility", "github-settings", "ai-usage", "published-shares"].contains(id) { return }
    let workspace = state.account == nil ? nil : state.workspace
    let pages = [
      "preferences": "preferences", "appearance": "appearance-settings", "about": "about",
    ]
    let workspacePages = [
      "agent-roles": "agent-roles", "prompt-shortcuts": "prompt-shortcuts", "project-visibility": "project-visibility",
      "github-settings": "github-settings", "ai-usage": "ai-usage", "memory-settings": "memory-settings",
      "published-shares": "published-shares",
    ]
    let remote = ["remote-machine": "machine", "remote-agent": "agent", "remote-mcp": "mcp"]
    if let page = pages[id] {
      push(page, title: title(id))
    } else if let page = workspacePages[id], workspace != nil {
      push(page, title: title(id), params: state.scope)
    } else if let kind = remote[id], workspace != nil {
      push("remote-settings", title: text("remote.\(kind)"), params: state.scope.merging(["kind": kind]) { _, new in new })
    } else if id == "workspace-general", let workspace {
      var params: [String: Any] = [
        "workspaceId": workspace.id, "name": workspace.name, "color": LodyAccentChoice.hex(.lodyAccent.resolvedColor(with: traitCollection)),
      ]
      params["image"] = workspace.image
      LodyShell.shared.present(
        WorkspaceEditorController(params: params), title: text("workspace.general"), detents: [0.5]
      )
    } else if id == "account", state.account != nil {
      LodyShell.shared.push(AccountController(source: source, connectionService: connectionService), title: state.account?.lan == nil ? String(localized: "account.title", bundle: .lody) : String(localized: "lan.leave.action", bundle: .lody), from: self)
    } else if id == "archived", workspace != nil {
      push("archived-sessions", title: String(localized: "settings.archived.title", bundle: .lody))
    } else if id == "project-history", workspace != nil {
      push("project-history", title: text("history.title"), params: state.scope)
    } else if id == "diagnostics" {
      push("diagnostics", title: String(localized: "diagnostics.title", bundle: .lody))
    } else if id == "connection", workspace != nil, state.connection.state == "offline" {
      source.refresh()
    } else if id == "debug-open" {
      let sheet = navigationController
      sheet?.presentingViewController?.dismiss(animated: true) {
        LodyShell.shared.openPage("debug", from: nil)
      }
    }
  }

  private func push(_ page: String, title: String, params: [String: Any] = [:]) {
    LodyShell.shared.push(page, title: title, params: params, from: self)
  }

  private func title(_ id: String) -> String {
    let keys = [
      "preferences": "preferences.title", "appearance": "appearance.title", "about": "section.about",
      "agent-roles": "roles.title", "prompt-shortcuts": "shortcuts.title", "project-visibility": "projects.title",
      "github-settings": "github.title", "ai-usage": "aiUsage.title", "memory-settings": "memory.title",
      "published-shares": "shares.title",
    ]
    return keys[id].map(text) ?? ""
  }

  private func text(_ key: String) -> String { SettingsSections.text(key) }
}
