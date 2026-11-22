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
    // The main page shares the Chats list's design language; inner pages keep the flat settings rows.
    list.setChatStyle(true)
    list.forwarded = { [weak self] name, body in
      guard let self, let id = body["id"] as? String else { return }
      if name == "rowToggle", let value = body["value"] as? Bool {
        switch id {
        case "developer-mode": LodyPreferences.saveDeveloperMode(value)
        case "roost-history": LodyPreferences.saveRoostHistoryExperiment(value)
        default: return
        }
        // Render now so the switch keeps the requested value instead of flicking back until the change notification.
        self.render()
      } else if name == "rowPress" {
        self.open(id)
      }
    }
    view.addSubview(list)
    for name in source.changes + [UIApplication.didBecomeActiveNotification, .lodyPreferencesDidChange] {
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
    #if DEBUG
      let developer = true
    #else
      let developer = LodyUIVerify.enabled
    #endif
    list.setSections(SettingsSections.make(state, developer: developer, hubLatency: value))
  }

  private func open(_ id: String) {
    if state.account?.lan != nil, ["workspace-general", "prompt-shortcuts", "project-visibility", "github-settings", "ai-usage", "published-shares"].contains(id) { return }
    let workspace = state.account == nil ? nil : state.workspace
    let native = [
      "preferences": "preferences", "about": "about",
    ]
    let workspacePages = [
      "agent-roles": "agent-roles", "prompt-shortcuts": "prompt-shortcuts", "project-visibility": "project-visibility",
      "github-settings": "github-settings", "ai-usage": "ai-usage",
    ]
    let remote = ["remote-agent": "agent"]
    if let page = native[id] {
      push(page, title: title(id))
    } else if let page = workspacePages[id], workspace != nil {
      push(page, title: title(id), params: state.scope)
    } else if let kind = remote[id], workspace != nil {
      push("\(kind)-settings", title: text("remote.\(kind)"), params: state.scope)
    } else if id == "workspace-general", let workspace {
      var params: [String: Any] = [
        "workspaceId": workspace.id, "name": workspace.name, "color": LodyAccent.hex(.lodyAccent.resolvedColor(with: traitCollection)),
      ]
      params["image"] = workspace.image
      LodyShell.shared.presentNative(
        WorkspaceEditorController(params: params), title: text("workspace.general"), detents: [0.5]
      )
    } else if id == "account", state.account != nil {
      LodyShell.shared.pushNative(AccountController(source: source, connectionService: connectionService), title: state.account?.lan == nil ? String(localized: "account.title", bundle: .lody) : String(localized: "lan.leave.action", bundle: .lody), from: self)
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
    LodyShell.shared.pushNative(page, title: title, params: params, from: self)
  }

  private func title(_ id: String) -> String {
    let keys = [
      "preferences": "preferences.title", "about": "section.about",
      "agent-roles": "roles.title", "prompt-shortcuts": "shortcuts.title", "project-visibility": "projects.title",
      "github-settings": "github.title", "ai-usage": "aiUsage.title",
    ]
    return keys[id].map(text) ?? ""
  }

  private func text(_ key: String) -> String { SettingsSections.text(key) }
}
