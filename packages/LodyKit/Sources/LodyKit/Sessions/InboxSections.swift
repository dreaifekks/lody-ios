import Foundation

struct InboxSearchHits: Equatable, Sendable {
  var projectIds: [String] = []
  var sessions: [(id: String, snippet: String?)] = []

  static func == (left: InboxSearchHits, right: InboxSearchHits) -> Bool {
    left.projectIds == right.projectIds
      && left.sessions.map(\.id) == right.sessions.map(\.id) && left.sessions.map(\.snippet) == right.sessions.map(\.snippet)
  }
}

enum InboxSort: String, CaseIterable, Sendable {
  case name, activity, urgency
}

enum InboxSections {
  static let chatId = "chat"
  static let pinnedId = StatusViewArea.pinnedId
  private static let groups = ["pinned", "attention", "live", "unread", "today", "yesterday", "week", "month", "older"]
  private static let day = 86_400_000.0

  static func inbox(
    _ catalog: SessionCatalog, keyword: String = "", now: Double = LodyRelativeTime.now()
  ) -> [LodyListSection] {
    let names = projectNames(catalog)
    let term = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let visible = catalog.sessions
      .filter { !$0.archived || !term.isEmpty }
      .filter { term.isEmpty || "\($0.title) \(place($0, names))".lowercased().contains(term) }
      .sorted(by: SessionRows.byActivity)
    var buckets: [String: [SessionItem]] = [:]
    for family in SessionRows.tree(visible, all: catalog.sessions) {
      buckets[group(family.session, now: now), default: []] += [family.session] + family.children
    }
    return groups.compactMap { id in
      let rows = SessionRows.treeRows(buckets[id] ?? [], all: catalog.sessions) { session in
        var row = SessionRows.row(session, projectName: place(session, names), now: now)
        let state = SessionState(session)
        row.diff = [:]
        row.imageTint = state == .live || !state.badge.isEmpty ? state.tint : ""
        return row
      }
      guard !rows.isEmpty else { return nil }
      return section(id, header: String(localized: String.LocalizationValue("inbox.section." + id), bundle: .lody), rows: rows)
    }
  }

  /// Home in the view menu's grouping; archived chats are hidden. With the runtime's Status view
  /// `layout`, the Pinned area (every grouping) and the Status grouping's Focus / Later / Settled
  /// tiers list exactly its sections and rows in its order; only time and project buckets are
  /// grouped here. Without it (a runtime or cache older than the layout) Pinned is the flagged
  /// families and Status falls back to time buckets, since Swift never classifies tiers itself.
  /// - Parameter owner: when set ("My tasks"), time and project buckets list only families with
  ///   chats owned by this user id; the layout is already scoped by the runtime.
  static func home(
    _ catalog: SessionCatalog, grouping: HomeGrouping, owner: String? = nil, layout: StatusViewLayout? = nil,
    settledExpanded: Bool = false, now: Double = LodyRelativeTime.now()
  ) -> [LodyListSection] {
    guard let layout else { return legacyHome(catalog, grouping: grouping, owner: owner, now: now) }
    var home = HomeRows(catalog, now: now)
    let index = layout.index
    let pinnedIds = layout.pinnedIds
    let pinned = pinnedArea(layout, home: home, index: index, sections: catalog.pinSections.map(\.id))
    if let owner {
      home.families = home.families.filter { family in ([family.session] + family.children).contains { $0.userId == owner } }
    }
    let bucketed: [SessionRows.Family] = home.families.compactMap { family in
      guard !pinnedIds.contains(family.session.id) else { return nil }
      return (family.session, family.children.filter { !pinnedIds.contains($0.id) })
    }
    var buckets = home
    buckets.families = bucketed
    var sections: [LodyListSection] = switch grouping {
    case .time: timeline(buckets)
    case .project: byProject(buckets)
    case .machine: byMachine(buckets)
    case .status: tiers(layout, home: home, index: index, pending: bucketed.filter { $0.session.pending && index[$0.session.id] == nil }, settledExpanded: settledExpanded)
    }
    if grouping != .status {
      // Time and project rows keep their native actions, but never offer management the layout withholds.
      sections = sections.map { section in
        var section = section
        section.rows = section.rows.map { row in
          guard let source = index[row.id] else { return row }
          var row = restrict(row, source)
          row.menuActions.removeAll { $0.id == "pin" }
          return row
        }
        return section
      }
    }
    return pinned + sections
  }

  private static func legacyHome(_ catalog: SessionCatalog, grouping: HomeGrouping, owner: String?, now: Double) -> [LodyListSection] {
    var catalog = catalog
    if let owner { catalog.sessions = owned(catalog.sessions, by: owner) }
    var home = HomeRows(catalog, now: now)
    let pinned = home.families.filter { $0.session.pinned || $0.children.contains(where: \.pinned) }
    home.families.removeAll { $0.session.pinned || $0.children.contains(where: \.pinned) }
    let sections: [LodyListSection]
    switch grouping {
    case .project: sections = byProject(home)
    case .machine: sections = byMachine(home)
    case .time, .status: sections = timeline(home)
    }
    guard !pinned.isEmpty else { return sections }
    return [section(pinnedId, header: String(localized: "inbox.section.pinned", bundle: .lody), rows: home.rows(pinned))] + sections
  }

  // MARK: Status view layout

  static let focusId = StatusViewArea.focusId
  static let laterId = "later"
  static let settledId = "settled"
  /// A user pin section's list id; the default section keeps `pinnedId`.
  static let pinSectionPrefix = StatusViewArea.pinSectionPrefix
  /// Later and Settled start collapsed (device-local, `ChatGroupFolds`).
  static let collapsedByDefault: Set<String> = [laterId, settledId]
  /// Settled conversations beyond this many top-level rows fold behind "Show all".
  static let settledLimit = 20
  static let settledMoreId = "view:settled"
  /// The "N hidden in this view" line under a pin section.
  static let hiddenRowPrefix = "view:hidden:"
  /// Section header menu actions (`sectionAction`).
  static let sectionActions = (create: "section:new", rename: "section:rename", up: "section:up", down: "section:down", delete: "section:delete")
  /// Status row actions (`rowAction`); `later` opens the Later sheet.
  static let statusActions = (settle: "status:settle", later: "status:later", focus: "status:focus")

  /// `sections` are the pin section definitions in render order; Move Up / Move Down follow them.
  private static func pinnedArea(
    _ layout: StatusViewLayout, home: HomeRows, index: [String: StatusViewRow], sections: [String]
  ) -> [LodyListSection] {
    let userSections = sections.isEmpty ? layout.pinned.compactMap(\.sectionId) : sections
    let manages = layout.canManageSections
    return layout.pinned.map { pinned in
      let area = StatusViewArea.pinned(pinned.sectionId)
      let header = pinned.sectionId == nil
        ? String(localized: "inbox.section.pinned", bundle: .lody)
        : pinned.name ?? ""
      var rows = layoutRows(pinned.rows, home: home, index: index)
      if pinned.hiddenCount > 0 {
        var hidden = LodyListRow()
        hidden.id = hiddenRowPrefix + area.sectionId
        hidden.title = String.localizedStringWithFormat(String(localized: "home.pins.hidden", bundle: .lody), pinned.hiddenCount)
        rows.append(hidden)
      }
      var result = section(area.sectionId, header: header, rows: rows)
      // Keep the label even when its rows are hidden: an empty user section stays a drop target.
      result.keepsEmpty = pinned.sectionId != nil
      result.headerValue = String(pinned.rows.flatMap(\.family).count)
      if manages { result.headerMenu = sectionMenu(pinned.sectionId, among: userSections) }
      return result
    }
  }

  private static func sectionMenu(_ id: String?, among sections: [String]) -> [LodyListAction] {
    var items = [listAction(sectionActions.create, "home.pins.newSection", "plus")]
    guard let id, let position = sections.firstIndex(of: id) else { return items }
    items.append(listAction(sectionActions.rename, "home.pins.rename", "pencil"))
    if position > 0 { items.append(listAction(sectionActions.up, "home.pins.moveUp", "arrow.up")) }
    if position < sections.count - 1 { items.append(listAction(sectionActions.down, "home.pins.moveDown", "arrow.down")) }
    var delete = listAction(sectionActions.delete, "home.pins.delete", "trash")
    delete.destructive = true
    items.append(delete)
    return items
  }

  private static func tiers(
    _ layout: StatusViewLayout, home: HomeRows, index: [String: StatusViewRow], pending: [SessionRows.Family], settledExpanded: Bool
  ) -> [LodyListSection] {
    func header(_ key: String) -> String { String(localized: String.LocalizationValue("home.status." + key), bundle: .lody) }
    // Creations the catalog has not read back yet have no layout row; they open at the top of Focus.
    var focus = section(focusId, header: header("focus"), rows: home.rows(pending) + layoutRows(layout.focus, home: home, index: index))
    focus.keepsEmpty = true
    focus.headerValue = String(layout.focus.flatMap(\.family).count + pending.count)
    var later = section(laterId, header: header("later"), rows: layoutRows(layout.later, home: home, index: index))
    later.headerValue = String(layout.later.flatMap(\.family).count)
    let roots = layout.settled.count
    var settledRows = layoutRows(layout.settled, home: home, index: index, maxRoots: settledExpanded ? .max : settledLimit)
    if roots > settledLimit {
      var toggle = LodyListRow()
      toggle.id = settledMoreId
      toggle.title = settledExpanded
        ? String(localized: "home.group.showLess", bundle: .lody)
        : String.localizedStringWithFormat(String(localized: "home.group.showAll", bundle: .lody), roots)
      toggle.action = true
      settledRows.append(toggle)
    }
    var settled = section(settledId, header: header("settled"), rows: settledRows)
    settled.headerValue = String(layout.settled.flatMap(\.family).count)
    return [focus, later, settled]
  }

  /// Rows in the layout's order. Session content (title, project, PR, status mark) comes from the
  /// catalog; unread, activity time, the Later countdown and the offered actions come from the
  /// layout row. Rows the catalog does not have are skipped.
  private static func layoutRows(
    _ rows: [StatusViewRow], home: HomeRows, index: [String: StatusViewRow], maxRoots: Int = .max
  ) -> [LodyListRow] {
    let families: [SessionRows.Family] = rows.compactMap { row in
      guard let session = home.sessions[row.id] else { return nil }
      return (session, row.children.flatMap(\.family).compactMap { home.sessions[$0.id] })
    }
    return home.rows(families, maxRoots: maxRoots).map { row in
      guard let source = index[row.id], let session = home.sessions[row.id] else { return row }
      return decorate(row, source, session, now: home.now)
    }
  }

  static func decorate(_ row: LodyListRow, _ source: StatusViewRow, _ session: SessionItem, now: Double) -> LodyListRow {
    var row = row
    // `row.unread` arrives with the conversation's own and its internal Tabs' unread output
    // (`SessionRows.treeRows`); the layout adds a woken snooze. Either keeps the dot.
    let tabsOrOwn = row.unread
    if source.activityAt.isFinite {
      row.value = LodyRelativeTime.compact(source.activityAt, now: now)
      row.accessibilityValue = LodyRelativeTime.text(source.activityAt, now: now)
      // The local viewed watermark clears emphasis before the read receipt syncs, as elsewhere.
      row.unread = tabsOrOwn || (source.unread && (session.lastViewedMessageAt.map { $0 < source.activityAt } ?? true))
    } else {
      row.unread = tabsOrOwn || source.unread
    }
    if source.tier == .later, let until = source.snoozedUntil, let countdown = StatusViewFormat.countdown(until: until, now: now) {
      row.value = countdown
      row.valueSymbol = "clock"
      let date = Date(timeIntervalSince1970: until / 1000).formatted(date: .abbreviated, time: .shortened)
      row.accessibilityValue = String.localizedStringWithFormat(String(localized: "home.status.returns", bundle: .lody), date)
    }
    // An opened child carried under a pinned opener renders in the Pinned area without being pinned.
    row.pinned = source.tier == .pinned && session.pinned
    switch source.tier {
    case .focus, .later:
      row.actions = [listAction(statusActions.settle, "home.status.settle", "checkmark.circle"), listAction(statusActions.later, "home.status.later", "clock")]
    case .settled:
      row.actions = [SessionRows.archive(false)]
    case .pinned:
      break
    }
    // Pin moves into the status menu beside Move to section; the rest of the menu stays.
    row.menuActions.removeAll { $0.id == "pin" }
    return restrict(row, source)
  }

  /// Offers only what the layout row permits: pin and unpin need `canPrefer`; status actions and
  /// session management (Settle, Later, Archive, Rename, Delete) need `canManage`, which a read-only
  /// member or a conversation on a machine the user cannot manage never has. Share and Mark Read stay.
  static func restrict(_ row: LodyListRow, _ source: StatusViewRow) -> LodyListRow {
    var row = row
    row.leadingActions = source.canPrefer ? [SessionRows.pin(row.pinned)] : []
    return restrict(row, canManage: source.canManage, canPrefer: source.canPrefer)
  }

  static func readOnly(_ sections: [LodyListSection]) -> [LodyListSection] {
    sections.map { section in
      var section = section
      section.headerMenu = []
      section.rows = section.rows.map { restrict($0, canManage: false, canPrefer: false) }
      return section
    }
  }

  private static func restrict(_ row: LodyListRow, canManage: Bool, canPrefer: Bool) -> LodyListRow {
    var row = row
    let managed = ["archive", "rename", "delete", statusActions.settle, statusActions.later, statusActions.focus]
    func permits(_ action: LodyListAction) -> Bool {
      action.id == "pin" ? canPrefer : canManage || !managed.contains(action.id)
    }
    row.leadingActions = row.leadingActions.filter(permits)
    row.actions = row.actions.filter(permits)
    row.menuActions = row.menuActions.filter(permits)
    return row
  }

  private static func listAction(_ id: String, _ key: String, _ symbol: String) -> LodyListAction {
    var item = LodyListAction()
    item.id = id
    item.title = String(localized: String.LocalizationValue(key), bundle: .lody)
    item.symbol = symbol
    return item
  }

  /// The view menu's Archived switch: only archived chats, in activity buckets, newest first.
  /// No Pinned group; rows offer unarchive as their swipe action.
  static func archived(_ catalog: SessionCatalog, owner: String? = nil, now: Double = LodyRelativeTime.now()) -> [LodyListSection] {
    var catalog = catalog
    if let owner { catalog.sessions = owned(catalog.sessions, by: owner) }
    return timeline(HomeRows(catalog, now: now, archived: true))
  }

  /// Keep complete families containing the owner's chats, including parent context.
  static func owned(_ sessions: [SessionItem], by owner: String) -> [SessionItem] {
    let indexed = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let included = Set(SessionRows.tree(sessions, indexed: indexed).flatMap { family in
      let members = [family.session] + family.children
      return members.contains { $0.userId == owner } ? members.map(\.id) : []
    })
    return sessions.filter { included.contains(DirectoryTabs.root($0, indexed: indexed)) }
  }

  /// Activity buckets only (no pinned / status groups).
  static func timeline(_ catalog: SessionCatalog, now: Double = LodyRelativeTime.now()) -> [LodyListSection] {
    timeline(HomeRows(catalog, now: now))
  }

  private static func timeline(_ home: HomeRows) -> [LodyListSection] {
    var buckets: [String: [SessionRows.Family]] = [:]
    for family in home.families {
      buckets[activityBucket(family.session.activityAt, now: home.now), default: []].append(family)
    }
    return ["today", "yesterday", "week", "month", "older"].compactMap { id in
      guard let sessions = buckets[id], !sessions.isEmpty else { return nil }
      return section(id, header: String(localized: String.LocalizationValue("inbox.section." + id), bundle: .lody), rows: home.rows(sessions))
    }
  }

  /// One group per project, most recently active first; unassigned chats form the "Chat" group.
  /// The header names the project, so rows drop it from their detail line.
  static func byProject(_ catalog: SessionCatalog, now: Double = LodyRelativeTime.now()) -> [LodyListSection] {
    byProject(HomeRows(catalog, now: now))
  }

  private static func byProject(_ home: HomeRows) -> [LodyListSection] {
    var order: [String] = []
    var groups: [String: [SessionRows.Family]] = [:]
    for family in home.families {
      let key = SessionRows.isChat(family.session.projectId) ? chatId : family.session.projectId
      if groups[key] == nil { order.append(key) }
      groups[key, default: []].append(family)
    }
    return order.map { key in
      let header = key == chatId ? String(localized: "inbox.section.chat", bundle: .lody) : home.names[key] ?? ""
      return section("group:\(key)", header: header, rows: home.rows(groups[key] ?? [], showsPlace: false))
    }
  }

  static func machineSectionId(_ machineId: String) -> String { "machine:\(machineId)" }

  static func isMachineSectionId(_ id: String) -> Bool { id.hasPrefix("machine:") }

  /// One group per computer, most recently active first; rows retain their project label.
  static func byMachine(_ catalog: SessionCatalog, now: Double = LodyRelativeTime.now()) -> [LodyListSection] {
    byMachine(HomeRows(catalog, now: now))
  }

  private static func byMachine(_ home: HomeRows) -> [LodyListSection] {
    var order: [String] = []
    var groups: [String: [SessionRows.Family]] = [:]
    for family in home.families {
      let key = home.machineId(for: family.session)
      if groups[key] == nil { order.append(key) }
      groups[key, default: []].append(family)
    }
    return order.map { key in
      let families = groups[key] ?? []
      var group = section(machineSectionId(key), header: home.machineName(for: key), rows: home.rows(families))
      group.headerValue = String(families.reduce(0) { $0 + 1 + $1.children.count })
      return group
    }
  }

  /// Shared row building for the Home groupings.
  private struct HomeRows {
    let now: Double
    let names: [String: String]
    let machineNames: [String: String]
    let projectMachines: [String: String]
    let repos: Set<String>
    let repositories: [String: String]
    var families: [SessionRows.Family]
    let attention: [String: SessionRows.ListAttention]
    /// Every catalog session by id, archived included.
    let sessions: [String: SessionItem]

    /// `archived` lists only archived chats (the view menu's Archived switch) instead of open ones.
    init(_ catalog: SessionCatalog, now: Double, archived: Bool = false) {
      let indexed = Dictionary(catalog.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      attention = SessionRows.conversationAttention(catalog.sessions, indexed: indexed)
      sessions = indexed
      self.now = now
      names = InboxSections.projectNames(catalog)
      machineNames = catalog.machineNames
      projectMachines = Dictionary(catalog.projects.map { ($0.id, $0.machineId) }, uniquingKeysWith: { first, _ in first })
      repositories = Dictionary(catalog.projects.compactMap { project in project.repoFullName.map { (project.id, $0) } }, uniquingKeysWith: { first, _ in first })
      repos = Set(catalog.projects.filter { !($0.repoFullName ?? "").isEmpty }.map(\.id))
      let visible = catalog.sessions.filter { $0.archived == archived }.sorted { $0.activityAt > $1.activityAt }
      families = SessionRows.tree(visible, indexed: indexed)
    }

    func machineId(for session: SessionItem) -> String {
      if !session.machineId.isEmpty { return session.machineId }
      if let projectMachine = projectMachines[session.projectId], !projectMachine.isEmpty { return projectMachine }
      return ""
    }

    func machineName(for machineId: String) -> String {
      if machineId.isEmpty { return String(localized: "inbox.section.chat", bundle: .lody) }
      let name = machineNames[machineId] ?? ""
      return name.isEmpty ? machineId : name
    }

    func rows(_ families: [SessionRows.Family], showsPlace: Bool = true, maxRoots: Int = .max) -> [LodyListRow] {
      let rootProjects = Set(families.map { $0.session.projectId })
      return SessionRows.treeRows(families, attention: attention, maxRoots: maxRoots) { session in
        var row = SessionRows.row(session, projectName: InboxSections.place(session, names), now: now)
        row.place = (showsPlace || !rootProjects.contains(session.projectId)) && !SessionRows.isChat(session.projectId) ? names[session.projectId] ?? "" : ""
        row.placeIsRepo = repos.contains(session.projectId)
        row.repository = repositories[session.projectId] ?? ""
        return row
      }
    }
  }

  /// iPhone Projects tab: one row per project with its open chat count and most urgent state.
  static func search(
    _ catalog: SessionCatalog, hits: InboxSearchHits, query: String = "", now: Double = LodyRelativeTime.now()
  ) -> [LodyListSection] {
    let names = projectNames(catalog)
    let projectIds = Set(hits.projectIds)
    let snippets = Dictionary(hits.sessions.map { ($0.id, $0.snippet) }, uniquingKeysWith: { first, _ in first })
    let projects = catalog.projects.filter { projectIds.contains($0.id) }.map { project in
      var row = LodyListRow()
      row.id = "project:\(project.id)"
      row.title = project.name
      row.subtitle = project.rootPath
      row.image = "folder"
      row.action = true
      row.disclosure = true
      row.navigates = true
      row.menuActions = SessionRows.projectMenu(project)
      row.highlight = query
      return row
    }
    let sessions = catalog.sessions.filter { snippets[$0.id] != nil }.sorted(by: SessionRows.byActivity)
    let rows = SessionRows.treeRows(sessions, all: catalog.sessions) { session in
      var row = SessionRows.row(session, projectName: place(session, names), now: now)
      row.highlight = query
      if let snippet = snippets[session.id] ?? nil {
        row.subtitle = snippet
        row.subtitleMono = false
        row.wrapSubtitle = true
      }
      return row
    }
    return [
      section("projects", header: String(localized: "inbox.section.projects", bundle: .lody), rows: projects),
      section("sessions", header: String(localized: "inbox.section.sessions", bundle: .lody), rows: rows),
    ].filter { !$0.rows.isEmpty }
  }

  static func match(_ catalog: SessionCatalog, keyword: String) -> InboxSearchHits {
    let term = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !term.isEmpty else { return InboxSearchHits() }
    let names = projectNames(catalog)
    let projects = catalog.projects.filter { !SessionRows.isChat($0.id) && $0.name.lowercased().contains(term) }
    let sessions = catalog.sessions
      .filter { "\($0.title) \(place($0, names))".lowercased().contains(term) }
      .sorted(by: SessionRows.byActivity)
    return InboxSearchHits(projectIds: projects.map(\.id), sessions: sessions.map { ($0.id, nil) })
  }

  static func isChatRow(_ id: String) -> Bool {
    ["chat", "toggle:chat", "view:chat", "project:chat"].contains(id)
  }

  static func sortProjects(_ projects: [SessionProject], sessions: [SessionItem], sort: InboxSort) -> [SessionProject] {
    let owned = projects.filter { !SessionRows.isChat($0.id) }
    var latest: [String: Double] = [:]
    var urgency: [String: Int] = [:]
    if sort != .name {
      for session in sessions where !session.archived {
        latest[session.projectId] = max(latest[session.projectId] ?? 0, session.activityAt)
        if sort == .urgency {
          let state = SessionState(session)
          let rank: Int
          if state == .attention || state == .failed { rank = 0 }
          else if state == .live { rank = 1 }
          else { rank = 2 }
          urgency[session.projectId] = min(urgency[session.projectId] ?? 2, rank)
        }
      }
    }
    return owned.sorted { left, right in
      if sort != .name {
        if sort == .urgency {
          let rank = (urgency[left.id] ?? 2) - (urgency[right.id] ?? 2)
          if rank != 0 { return rank < 0 }
        }
        let activity = (latest[right.id] ?? 0) - (latest[left.id] ?? 0)
        if activity != 0 { return activity < 0 }
      }
      return left.name.localizedCompare(right.name) == .orderedAscending
    }
  }

  static func activityBucket(_ value: Double, now: Double, calendar: Calendar = .current) -> String {
    let today = calendar.startOfDay(for: Date(timeIntervalSince1970: now / 1000)).timeIntervalSince1970 * 1000
    if value.isNaN || value >= today { return "today" }
    if value >= today - day { return "yesterday" }
    if value >= today - 7 * day { return "week" }
    if value >= today - 30 * day { return "month" }
    return "older"
  }

  private static func group(_ session: SessionItem, now: Double) -> String {
    if session.pinned { return pinnedId }
    let state = SessionState(session)
    if state == .attention || state == .failed { return "attention" }
    if state == .live { return "live" }
    if SessionRows.isUnread(session) { return "unread" }
    return activityBucket(session.activityAt, now: now)
  }

  fileprivate static func projectNames(_ catalog: SessionCatalog) -> [String: String] {
    Dictionary(catalog.projects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
  }

  static func place(_ session: SessionItem, _ names: [String: String]) -> String {
    SessionRows.isChat(session.projectId) ? String(localized: "inbox.section.chat", bundle: .lody) : names[session.projectId] ?? ""
  }

  private static func section(_ id: String, header: String = "", rows: [LodyListRow]) -> LodyListSection {
    var section = LodyListSection()
    section.id = id
    section.header = header
    section.rows = rows
    return section
  }
}
