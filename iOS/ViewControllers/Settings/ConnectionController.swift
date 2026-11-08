import UIKit

@MainActor
final class ConnectionController: UIViewController {
  private let list = LodyGroupedList(frame: .zero)
  private let source: SettingsSource
  private let service: ConnectionService
  private let hub: HubLatencyObserver
  private var machines: [ConnectionService.Machine] = []
  private var reach: [String: HubLatencyObserver.Value] = [:]
  private var error = false
  private var round = 0
  private var scope = ""
  private var currentScope: String {
    let state = source.state
    return (state.account?.user.id ?? "") + "/" + (state.workspace?.id ?? "")
  }
  private var tasks: [Task<Void, Never>] = []
  private var timer: Task<Void, Never>?
  private var observers: [NSObjectProtocol] = []

  init(source: SettingsSource = .live, service: ConnectionService = .live) {
    self.source = source
    self.service = service
    hub = HubLatencyObserver(service: service)
    super.init(nibName: nil, bundle: nil)
    title = SettingsSections.text("section.connection")
  }
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }
  isolated deinit {
    tasks.forEach { $0.cancel() }
    timer?.cancel()
    observers.forEach(NotificationCenter.default.removeObserver)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    list.frame = view.bounds
    list.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    list.setPlaceholder("")
    list.setRefreshEnabled(true)
    list.forwarded = { [weak self] name, body in
      guard let self else { return }
      if name == "refresh" { self.refresh() }
      if name == "rowPress", let id = body["id"] as? String {
        if id == "retry" { self.refresh() }
        if id == "sync", self.source.state.connection.state == "offline" { self.source.refresh() }
      }
    }
    view.addSubview(list)
    hub.changed = { [weak self] in self?.render() }
    for name in source.changes + [UIApplication.didBecomeActiveNotification] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, self.viewIfLoaded?.window != nil else { return }
          self.hub.start(self.source.state.account?.lan)
          let changed = self.scope != self.currentScope
          self.render()
          if changed || name == UIApplication.didBecomeActiveNotification { self.refresh() }
        }
      })
    }
    render()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    hub.start(source.state.account?.lan)
    refresh()
    timer = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(15))
        guard let self, !Task.isCancelled else { return }
        self.refresh()
      }
    }
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    hub.stop()
    round += 1
    timer?.cancel()
    timer = nil
    tasks.forEach { $0.cancel() }
  }

  private func refresh() {
    guard let workspace = source.state.workspace?.id else { return }
    round += 1
    let generation = round
    let identity = currentScope
    tasks.forEach { $0.cancel() }
    tasks = []
    let task = Task { [weak self, service] in
      do {
        let machines = try await service.machines(workspace)
        guard let self, !Task.isCancelled, self.round == generation, self.currentScope == identity else { return }
        self.machines = machines
        self.error = false
        self.list.setRefreshing(false)
        self.render()
        for machine in machines {
          self.tasks.append(Task { [weak self, service] in
            let ms = try? await service.ping(workspace, machine.id)
            guard let self, !Task.isCancelled, self.round == generation, self.currentScope == identity else { return }
            self.reach[machine.id] = ms.map { .measured(Int($0.rounded())) } ?? .noAnswer
            self.render()
          })
        }
      } catch {
        guard let self, !Task.isCancelled, self.round == generation, self.currentScope == identity else { return }
        self.error = true
        self.list.setRefreshing(false)
        self.render()
      }
    }
    tasks.append(task)
  }

  private func render() {
    let state = source.state
    if scope != currentScope {
      scope = currentScope
      round += 1
      tasks.forEach { $0.cancel() }
      machines = []
      reach = [:]
      error = false
    }
    var sections: [LodyListSection] = []
    if let lan = state.account?.lan {
      var row = LodyListRow()
      row.id = "hub"
      row.title = lan.name
      row.subtitle = lan.url.replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
      row.image = "server.rack"
      row.value = hub.value.text
      row.imageTint = hub.value == .noAnswer ? "danger" : "blue"
      row.accessibilityValue = row.value
      sections.append(section("hub", "connection.hub", [row]))
    }
    var sync = LodyListRow()
    sync.id = "sync"
    sync.title = SettingsSections.text("connection." + state.connection.state)
    sync.image = ["live": "circle.fill", "offline": "xmark.octagon.fill", "syncing": "circle"][state.connection.state] ?? "circle"
    sync.imageTint = ["live": "blue", "offline": "danger", "syncing": "secondary"][state.connection.state] ?? "secondary"
    sync.action = state.connection.state == "offline"
    if sync.action { sync.subtitle = SettingsSections.text("connection.tapToResync") }
    else if let at = state.connection.syncedAt {
      sync.subtitle = String.localizedStringWithFormat(String(localized: "settings.connection.syncedAt", bundle: .lody), LodyRelativeTime.text(at))
    }
    var presence = LodyListRow()
    presence.id = "presence"
    presence.title = SettingsSections.text("connection.presence")
    presence.value = SettingsSections.text("connection.presence." + service.presence())
    presence.image = "waveform.path.ecg"
    presence.imageTint = service.presence() == "live" ? "blue" : "secondary"
    sections.append(section("sync", "connection.sync", [sync, presence]))
    var rows = machines.map { machine in
      var row = LodyListRow()
      row.id = "machine:" + machine.id
      row.title = machine.alias ?? machine.name ?? SettingsSections.text("connection.unnamedMachine")
      var detail: [String] = []
      if machine.alias != nil, let name = machine.name { detail.append(name) }
      if let os = machine.os { detail.append(os) }
      if let version = machine.version { detail.append("v" + version) }
      row.subtitle = detail.joined(separator: " · ")
      row.wrapSubtitle = true
      row.image = "desktopcomputer"
      // Presence is authoritative. Ping only supplies latency and never promotes an offline member.
      switch machine.online {
      case true:
        row.imageTint = "blue"
        row.value = SettingsSections.text("connection.machineOnline")
        if case .measured = reach[machine.id] { row.value += " · " + reach[machine.id]!.text }
      case false:
        row.imageTint = "danger"
        row.value = SettingsSections.text("connection.machineOffline")
      case nil:
        row.imageTint = "secondary"
        row.value = SettingsSections.text("connection.checking")
      }
      row.accessibilityValue = row.value
      return row
    }
    if error {
      var retry = LodyListRow()
      retry.id = "retry"
      retry.title = SettingsSections.text("connection.listFailed")
      retry.subtitle = SettingsSections.text("connection.retry")
      retry.action = true
      retry.image = "exclamationmark.triangle"
      rows.append(retry)
    }
    var group = section("machines", "connection.machines", rows)
    group.footer = SettingsSections.text("connection.footer")
    sections.append(group)
    list.setSections(sections)
  }

  private func section(_ id: String, _ key: String, _ rows: [LodyListRow]) -> LodyListSection {
    var section = LodyListSection()
    section.id = id
    section.header = SettingsSections.text(key)
    section.rows = rows
    return section
  }
}
