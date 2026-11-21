import UIKit

@MainActor
final class InboxController: UIViewController {
  let list = SessionListView()
  let source: SessionSource
  private let chrome = InboxChrome()
  private lazy var actions = SessionActions(source: source)
  private lazy var status = StatusViewActions(source: source)
  private var query = ""
  /// Settled shows every conversation; not persisted, so it opens folded.
  private var settledExpanded = false
  /// A dropped row's order, held until the catalog reads the move back.
  private var hold: (key: String, generation: Int, value: StatusViewHold)?
  private var holdGeneration = 0
  /// The layout the list shows (hold applied); drag, drop and accessibility moves resolve against it.
  private var shownLayout: StatusViewLayout?
  /// Re-renders Later countdowns each minute while any are listed.
  private var countdownTimer: Timer?
  private var search: (key: String, catalog: SessionCatalog, hits: InboxSearchHits)?
  private var requested: (key: String, catalog: SessionCatalog)?
  private var searchTask: Task<Void, Never>?
  private var views: [String: Double] = [:]
  private var viewsKey = ""
  private var viewsLoad = 0
  private var members: [String: WorkspaceMember] = [:]
  private var memberScope = ""
  private var memberTask: Task<Void, Never>?
  private var observers: [NSObjectProtocol] = []
  private var renderedInput: (userId: String, workspaceId: String, catalog: SessionCatalog)?
  /// Account/workspace whose catalog has loaded empty once; later resyncs or reconnects keep the guide.
  private var onboardingSettledKey: String?
  private var leaving = false

  init(source: SessionSource = .live) {
    self.source = source
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  isolated deinit {
    searchTask?.cancel()
    memberTask?.cancel()
    countdownTimer?.invalidate()
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    list.frame = view.bounds
    list.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    list.accessibilityIdentifier = "ipad-inbox-list"
    list.forwarded = { [weak self] name, body in self?.event(name, body) }
    status.runMove = { [weak self] command in self?.runMove(command) }
    list.shareOnboarding = { [weak self] items, source in
      let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
      sheet.popoverPresentationController?.sourceView = source
      self?.present(sheet, animated: true)
    }
    view.addSubview(list)
    wireChrome()
    observers = (source.changes + [UIApplication.didBecomeActiveNotification, .lodyHomeGroupingChanged, .lodyProjectGroupsDidChange, .lodyWorkspaceRoleDidChange]).map { name in
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.render(onlyIfContentChanged: name == .lodyCatalogDidChange || name == .lodySessionCatalogPreviewDidChange)
          if name == UIApplication.didBecomeActiveNotification, self?.source === SessionSource.live,
             self?.source.state.workspace?.resolvedMode == .unknown {
            Task { await AuthSession.shared.refreshWorkspaceModes() }
          }
        }
      }
    }
    lodyObserveTraitChanges([.userInterfaceStyle, .horizontalSizeClass]) { (view: InboxController, _: UITraitCollection) in view.render() }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    leaving = false
    list.deselectOnReturn(animated: animated, coordinator: transitionCoordinator)
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    leaving = true
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    LodyScrollEdges.bind(list.scrollView, to: self)
    chrome.layout()
  }

  override func didMove(toParent parent: UIViewController?) {
    super.didMove(toParent: parent)
    if let parent {
      chrome.attach(to: parent, content: self, scrollView: list.scrollView)
      render()
    } else {
      chrome.detach()
    }
  }

  func render(onlyIfContentChanged: Bool = false) {
    guard isViewLoaded else { return }
    let state = source.state
    let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if source === SessionSource.live {
      ProjectGroupStore.shared.ensure(userId: state.userId, workspaceId: state.workspaceId, catalog: state.catalog)
    }
    if state.userId.isEmpty {
      chrome.update(nil)
      list.setPlaceholder("")
      list.setRetry(nil)
    } else {
      chrome.update(InboxChrome.Model(
        accountEmail: state.accountEmail,
        workspaces: state.workspaces, selected: state.workspace,
        devices: InboxDevices(catalog: state.catalog, presence: state.presence),
        connection: syncState(state)
      ))
      if term.isEmpty { list.setPlaceholder(listPlaceholder(state)) }
      let unknown = source === SessionSource.live && state.workspace?.resolvedMode == .unknown
      list.setRetry(unknown && term.isEmpty ? { Task { await AuthSession.shared.refreshWorkspaceModes() } } : nil)
    }
    // The guide follows loading / connection too, so it is set before the content-only guard.
    if list.setOnboarding(term.isEmpty && showsOnboarding(state)) {
      LodyScrollEdges.bind(list.scrollView, to: self)
      chrome.attachScrollEdge(list.scrollView)
    }
    // Presence and connection updates still refresh chrome, but cannot change rows.
    // Explicit renders bypass this guard for search results, identities and watermarks.
    if onlyIfContentChanged, let renderedInput,
      renderedInput.userId == state.userId, renderedInput.workspaceId == state.workspaceId,
      renderedInput.catalog == state.catalog { return }
    renderedInput = (state.userId, state.workspaceId, state.catalog)
    if memberScope != state.key {
      memberTask?.cancel()
      memberScope = state.key
      members = [:]
      if source === SessionSource.live, !LodyUIVerify.enabled, !state.key.isEmpty {
        memberTask = Task { [weak self] in
          await WorkspaceMembers.load(userId: state.userId, workspaceId: state.workspaceId) { [weak self] members in
            guard let self, self.source.state.key == state.key else { return }
            self.members = members
            self.render()
          }
        }
      }
    }
    var identities = members
    if let me = AuthSession.shared.snapshot.account?.user, me.id == state.userId {
      identities[me.id] = identities[me.id] ?? WorkspaceMember(id: me.id, name: me.name, image: me.image)
    }
    let owners: [String: WorkspaceMember] = HomeScope.stored == .team ? Dictionary(state.catalog.sessions.map { session in
      (session.id, identities[session.userId ?? ""] ?? WorkspaceMember(id: session.userId ?? "", name: "", image: nil))
    }, uniquingKeysWith: { _, new in new }) : [:]
    list.setOwners(owners)
    loadViews(state)
    list.setProjectIndexEnabled(!state.userId.isEmpty && !HomeArchive.shown && term.isEmpty && HomeGrouping.stored == .project)
    guard !state.userId.isEmpty else {
      list.setSections([])
      return
    }
    let archived = HomeArchive.shown
    list.setArchivedStyle(archived)
    var catalog = state.catalog.viewed(views)
    // The Archived switch narrows every view, search included, to archived chats.
    if archived { catalog.sessions = catalog.sessions.filter(\.archived) }
    list.setPinsGroupLabels(term.isEmpty)
    let layout = statusLayout(state)
    shownLayout = term.isEmpty && !archived ? layout : nil
    list.setStatusHooks(shownLayout == nil ? nil : statusHooks)
    scheduleCountdown(shownLayout)
    guard term.isEmpty else {
      renderSearch(term, state: state, catalog: catalog)
      return
    }
    if archived {
      list.setSections(InboxSections.archived(catalog, owner: HomeScope.stored == .mine ? state.userId : nil))
      return
    }
    // Every size class groups by the view menu's choice (time / project / status).
    let owner = HomeScope.stored == .mine ? state.userId : nil
    // Layout times are on the server clock, so its rows age and count down against it.
    list.setSections(InboxSections.home(
      catalog, grouping: HomeGrouping.stored, owner: owner, layout: layout, settledExpanded: settledExpanded,
      now: layout == nil ? LodyRelativeTime.now() : StatusViewActions.now
    ))
  }

  // MARK: Status view

  /// The runtime layout for the current scope, with a held drop applied until it reads back.
  private func statusLayout(_ state: SessionListState) -> StatusViewLayout? {
    if let nowMs = state.catalog.statusView?.nowMs {
      StatusViewActions.clock.observe(serverNow: nowMs, deviceNow: LodyRelativeTime.now())
    }
    guard let published = state.catalog.statusView?.layout(team: HomeScope.stored == .team, readOnly: StatusViewActions.readOnly(state)) else {
      hold = nil
      return nil
    }
    guard let current = hold else { return published }
    if current.key != state.key + HomeScope.stored.rawValue || current.value.released(by: published) {
      hold = nil
      return published
    }
    return current.value.apply(to: published)
  }

  private lazy var statusHooks = ChatListStatusHooks(
    menu: { [weak self] id in
      guard let self else { return [] }
      return self.status.menu(id, from: self)
    },
    canDrag: { [weak self] id in
      guard let row = self?.shownLayout?.index[id] else { return false }
      return row.tier == .pinned ? row.canPrefer : row.canManage || row.canPrefer
    },
    drop: { [weak self] id, sectionId, beforeId in
      guard let row = self?.shownLayout?.index[id], let area = StatusViewArea(sectionId: sectionId) else { return nil }
      return StatusViewPlanning.drop(row, into: area, beforeId: beforeId)
    },
    moveDirections: { [weak self] in
      self?.shownLayout.map { StatusViewPlanning.moveDirections(in: $0) } ?? [:]
    },
    step: { [weak self] id, up in
      self?.shownLayout.flatMap { StatusViewPlanning.step(id, up: up, in: $0) }
    },
    perform: { [weak self] command in self?.runMove(command) }
  )

  /// Drops, Move to section, Move to top and accessibility moves: the list shows the new order at
  /// once and keeps it until the catalog reads the write back (or the write fails).
  private func runMove(_ command: StatusViewCommand) {
    let state = source.state
    guard let base = state.catalog.statusView?.layout(team: HomeScope.stored == .team, readOnly: StatusViewActions.readOnly(state)),
      let value = StatusViewHold(command, base: base)
    else {
      status.run(command)
      return
    }
    // Dropped where it already was: nothing to write, but the list must settle again.
    guard !value.landed(in: base) else {
      render()
      return
    }
    holdGeneration += 1
    let generation = holdGeneration
    hold = (state.key + HomeScope.stored.rawValue, generation, value)
    render()
    Task { [weak self] in
      guard let self else { return }
      let writes = await self.status.perform(command)
      guard self.hold?.generation == generation else { return }
      // 0 writes: the planner refused the move or it changed nothing, so no read-back will come.
      if let writes, writes > 0 { self.hold?.value.acknowledged = true } else { self.hold?.value.failed = true }
      self.render()
    }
  }

  private func scheduleCountdown(_ layout: StatusViewLayout?) {
    let needed = HomeGrouping.stored == .status && !(layout?.later.isEmpty ?? true)
    guard needed != (countdownTimer != nil) else { return }
    countdownTimer?.invalidate()
    countdownTimer = needed
      ? Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.render() }
      }
      : nil
  }

  private func wireChrome() {
    chrome.selectWorkspace = { [weak self] id in self?.selectWorkspace(id) }
    // The application shell owns these presentations so external links can dismiss them.
    chrome.openSettings = { [weak self] in
      LodyShell.shared.openPage("settings", options: ["present": true], from: self?.parent)
    }
    chrome.openDebug = { [weak self] in LodyShell.shared.openPage("debug", from: self?.parent) }
    // While Schedules fills the regular-width detail column, the list's create action adds a schedule.
    chrome.newSession = { [weak self] in
      guard let self else { return }
      if self.chrome.destination == .schedules { HomeController.current?.newSchedule() } else { self.newSession() }
    }
    chrome.selectDestination = { HomeController.current?.selectTab($0) }
    chrome.searchChanged = { [weak self] text in
      guard let self, text != self.query else { return }
      self.query = text
      self.render()
    }
  }

  private func renderSearch(_ term: String, state: SessionListState, catalog: SessionCatalog) {
    let key = [state.userId, state.workspaceId, term].joined(separator: "\0")
    if requested?.key != key || requested?.catalog != catalog { requestSearch(term, key: key, state: state, catalog: catalog) }
    let current = search.flatMap { $0.key == key && $0.catalog == catalog ? $0 : nil }
    list.setPlaceholder(String(localized: String.LocalizationValue(current == nil ? "search.placeholder.loading" : "search.placeholder.noMatch"), bundle: .lody))
    list.setSections(InboxSections.search(catalog, hits: current?.hits ?? InboxSearchHits(), query: term))
  }

  private func requestSearch(_ term: String, key: String, state: SessionListState, catalog: SessionCatalog) {
    requested = (key, catalog)
    searchTask?.cancel()
    guard !state.workspaceId.isEmpty else { return }
    let (user, workspace) = (state.userId, state.workspaceId)
    searchTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(120))
      guard !Task.isCancelled else { return }
      let result: Result<InboxSearchHits, Error> = await withCheckedContinuation { done in
        LocalStore.queue.async {
          done.resume(returning: Result {
            Self.hits(try LocalStore.shared.searchInbox(userID: user, workspaceID: workspace, query: term))
          })
        }
      }
      guard let self, !Task.isCancelled, self.requested?.key == key else { return }
      switch result {
      case .success(let hits):
        self.search = (key, catalog, hits)
      case .failure:
        LodyToastOverlay.shared.show(message: String(localized: "search.toast.failed", bundle: .lody), kind: .error)
        self.search = (key, catalog, InboxSections.match(catalog, keyword: term))
      }
      self.render()
    }
  }

  private nonisolated static func hits(_ raw: [String: Any]) -> InboxSearchHits {
    let sessions = (raw["sessions"] as? [[String: Any]] ?? []).compactMap { item -> (id: String, snippet: String?)? in
      guard let id = item["id"] as? String else { return nil }
      return (id, item["snippet"] as? String)
    }
    return InboxSearchHits(projectIds: raw["projectIds"] as? [String] ?? [], sessions: sessions)
  }

  private func syncState(_ state: SessionListState) -> HomeSyncState {
    if !state.connected { return .connecting }
    return state.loading ? .syncing : .live
  }

  /// Web mobile Home's first-run guide: a signed-in plaintext workspace, outside Archived,
  /// with neither a computer nor a conversation. Like web it waits only for the first
  /// loaded, connected catalog of that account/workspace; a later foreground resync or
  /// reconnect keeps it until a computer or conversation appears. Search is excluded by the caller.
  private func showsOnboarding(_ state: SessionListState) -> Bool {
    let empty = state.catalog.machineIds.isEmpty && state.catalog.sessions.isEmpty
    if !empty || state.key.isEmpty {
      onboardingSettledKey = nil
    } else if !state.loading, state.connected {
      onboardingSettledKey = state.key
    }
    guard empty, !state.userId.isEmpty, !HomeArchive.shown, state.workspace?.resolvedMode == .plaintext else { return false }
    return onboardingSettledKey == state.key
  }

  private func listPlaceholder(_ state: SessionListState) -> String {
    if source === SessionSource.live, let workspace = AuthSession.shared.snapshot.account?.workspaces.first(where: { $0.id == state.workspaceId }) {
      switch workspace.resolvedMode {
      case .e2ee: return String(localized: "workspace.e2ee.unsupported", bundle: .lody)
      case .unknown: return String(localized: "workspace.mode.unknown", bundle: .lody)
      case .plaintext: break
      }
    }
    if state.loading { return String(localized: "sessions.placeholder.loading", bundle: .lody) }
    if !state.connected { return String(localized: "sessions.placeholder.offline", bundle: .lody) }
    let empty = HomeArchive.shown ? "home.archived.empty" : "sessions.placeholder.empty"
    return String(localized: String.LocalizationValue(empty), bundle: .lody)
  }

  private func loadViews(_ state: SessionListState) {
    if state.key != viewsKey {
      viewsKey = state.key
      views = [:]
    }
    viewsLoad += 1
    let load = viewsLoad
    Task { [weak self] in
      let next = await SessionSource.views(userId: state.userId, workspaceId: state.workspaceId)
      guard let self, self.viewsLoad == load, next != self.views else { return }
      self.views = next
      self.render()
    }
  }

  private func event(_ name: String, _ body: [String: Any]) {
    guard let id = body["id"] as? String else { return }
    switch name {
    case "rowPress":
      if consume(id) { return }
      let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
      actions.open(id, findQuery: term.isEmpty ? nil : term, from: self)
      // A row stays selected only while its page covers the list; split columns and refusals clear it.
      DispatchQueue.main.async { [weak self] in
        guard let self, !self.leaving else { return }
        self.list.clearSelection()
      }
    case "rowAction":
      guard let action = body["actionId"] as? String else { return }
      if status.perform(action, row: id, from: self) { return }
      actions.perform(action, row: id, from: self)
    case "sectionAction":
      guard let action = body["actionId"] as? String else { return }
      status.performSection(action, section: id, from: self)
    default:
      break
    }
  }

  private func consume(_ id: String) -> Bool {
    // The Chats pseudo-project and the "hidden in this view" lines have no page of their own.
    if id.hasPrefix(InboxSections.hiddenRowPrefix) { return true }
    guard id == InboxSections.settledMoreId else { return InboxSections.isChatRow(id) }
    settledExpanded.toggle()
    render()
    return true
  }

  private func selectWorkspace(_ id: String) {
    guard NativeHomeFixture.active else {
      CatalogSession.shared.selectWorkspace(id)
      return
    }
    Task { try? await NativeHomeFixture.request("selectWorkspace", ["workspaceId": id]) }
  }

  /// Regular width: which Home destination the detail column shows (the bottom bar's selection).
  func setDestination(_ tab: HomeTab) { chrome.destination = tab }

  func newSession() {
    let state = source.state
    guard state.workspace?.resolvedMode == .plaintext else {
      LodyToastOverlay.shared.show(message: String(localized: "tabs.toast.signInFirst", bundle: .lody), kind: .neutral)
      return
    }
    SessionActions.create(["workspaceId": state.workspaceId, "zoomSourceLabel": String(localized: "tabs.newSession", bundle: .lody)])
  }
}
