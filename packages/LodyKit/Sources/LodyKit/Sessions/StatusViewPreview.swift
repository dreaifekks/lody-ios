import Foundation

/// Offline responses for Home's Status review scene. Production controllers use
/// the same commands and catalog readback path with the actual runtime.
@MainActor
enum StatusViewPreview {
  private static var layout = StatusViewLayout()
  private static var pendingMove: StatusViewLayout?
  private static var initialIds: [String] = []
  private static var archivedIds: Set<String> = []
  private static let hour = 3_600_000.0

  static func matches(_ workspaceId: String) -> Bool {
    LodyUIVerify.status && workspaceId == "ui-home"
  }

  static func reset() {
    let now = LodyRelativeTime.now()
    func row(_ id: String, _ tier: StatusViewRow.Tier, until: Double? = nil) -> StatusViewRow {
      StatusViewRow(id: id, tier: tier, activityAt: now - hour, unread: id == "focus-woken",
        snoozedUntil: until, woken: id == "focus-woken", canManage: true, canPrefer: true)
    }
    let extraFocus = LodyUIVerify.has("--ui-review-status-long")
      ? (1...24).map { row("focus-extra-\($0)", .focus) } : []
    layout = StatusViewLayout(
      pinned: [
        .init(sectionId: nil, name: nil, rows: [row("pin-a", .pinned), row("pin-c", .pinned)]),
        .init(sectionId: "maintenance", name: "Maintenance", rows: [row("pin-b", .pinned)], hiddenCount: 2),
        .init(sectionId: "review", name: "Review"),
      ],
      focus: [row("focus-woken", .focus), row("focus-a", .focus), row("ui-design", .focus)] + extraFocus,
      later: [row("later-a", .later, until: now + 2 * hour)],
      settled: [row("settled-a", .settled)],
      canManageSections: true
    )
    initialIds = layout.index.keys.sorted().filter { $0 != "ui-design" }
    archivedIds = []
    pendingMove = nil
  }

  static func project(into catalog: inout SessionCatalog) {
    catalog.statusView = .init(mine: layout, team: layout, nowMs: LodyRelativeTime.now())
    catalog.pinSections = layout.pinned.compactMap { section in
      guard let id = section.sectionId, let name = section.name else { return nil }
      return .init(id: id, name: name, orderKey: nil)
    }
    let index = layout.index
    catalog.sessions += initialIds.map { id in
      SessionItem(id: id, title: id, archived: archivedIds.contains(id), pinned: index[id]?.tier == .pinned,
        userId: "ui-home", lastMessageAt: index[id]?.activityAt)
    }
  }

  static func presets() -> (nowMs: Double, presets: [StatusViewSnoozePreset]) {
    let now = LodyRelativeTime.now()
    let hours: [(String, Double)] = [("oneHour", 1), ("laterToday", 3), ("tomorrowMorning", 13), ("nextWeek", 168)]
    return (now, hours.map { StatusViewSnoozePreset(id: $0.0, timestamp: now + $0.1 * hour) })
  }

  static func archive(_ id: String, archived: Bool) {
    if archived {
      removeRow(id)
      archivedIds.insert(id)
    } else {
      archivedIds.remove(id)
      layout.focus.append(.init(id: id, tier: .focus, activityAt: LodyRelativeTime.now(), canManage: true, canPrefer: true))
    }
    publish()
  }

  static func apply(_ command: StatusViewCommand) -> Int {
    let before = layout
    switch command {
    case .move:
      let base = pendingMove ?? layout
      guard let hold = StatusViewHold(command, base: base) else { return 0 }
      let next = hold.apply(to: base)
      if LodyUIVerify.has("--ui-review-status-hold") {
        guard next != base else { return 0 }
        pendingMove = next
        return 1
      }
      layout = next
    case .setPinned(let id, let pinned):
      let move = StatusViewCommand.move(sessionId: id, to: pinned ? .pinned(nil) : .focus, beforeId: nil)
      if let hold = StatusViewHold(move, base: layout) { layout = hold.apply(to: layout) }
    case .snooze(let id, let until, _):
      guard until > LodyRelativeTime.now(), var row = layout.index[id] else { return 0 }
      removeRow(id)
      row.tier = .later
      row.snoozedUntil = until
      layout.later.append(row)
    case .settle(let id, _):
      guard var row = layout.index[id] else { return 0 }
      removeRow(id)
      row.tier = .settled
      row.snoozedUntil = nil
      layout.settled.append(row)
    case .moveToFocus(let id, _):
      let move = StatusViewCommand.move(sessionId: id, to: .focus, beforeId: layout.focus.first?.id)
      if let hold = StatusViewHold(move, base: layout) { layout = hold.apply(to: layout) }
    case .createSection(let id, let name):
      layout.pinned.append(.init(sectionId: id, name: name))
    case .renameSection(let id, let name):
      guard let index = layout.pinned.firstIndex(where: { $0.sectionId == id }) else { return 0 }
      layout.pinned[index].name = name
    case .deleteSection(let id):
      guard let index = layout.pinned.firstIndex(where: { $0.sectionId == id }) else { return 0 }
      let removed = layout.pinned.remove(at: index)
      layout.pinned[0].rows += removed.rows
    case .moveSection(let id, let beforeId):
      guard let index = layout.pinned.firstIndex(where: { $0.sectionId == id }) else { return 0 }
      let moving = layout.pinned.remove(at: index)
      let target = beforeId.flatMap { id in layout.pinned.firstIndex { $0.sectionId == id } } ?? layout.pinned.count
      layout.pinned.insert(moving, at: target)
    }
    guard layout != before else { return 0 }
    publish()
    return 1
  }

  static func publishCatalog(readBackMove: Bool) {
    guard LodyUIVerify.status, LodyUIVerify.has("--ui-review-status-hold") else { return }
    if readBackMove, let pendingMove {
      layout = pendingMove
      self.pendingMove = nil
    }
    publish()
  }

  private static func removeRow(_ id: String) {
    layout.focus.removeAll { $0.id == id }
    layout.later.removeAll { $0.id == id }
    layout.settled.removeAll { $0.id == id }
    for index in layout.pinned.indices { layout.pinned[index].rows.removeAll { $0.id == id } }
  }

  private static func publish() {
    NotificationCenter.default.post(name: .lodySessionCatalogPreviewDidChange, object: nil)
  }
}
