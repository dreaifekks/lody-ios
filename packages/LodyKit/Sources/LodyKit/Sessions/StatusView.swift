import Foundation

// The Status view (Focus / Later / Settled) and the pin sections, as the shared runtime computes
// them (`catalog.statusView`, `catalog.pinSections`). Swift renders this layout and never sorts or
// classifies these rows itself; writes go back as `StatusViewCommand`s that the runtime plans.
// Shapes: Lody `.agents/notes/implemented/architecture/2026-11-21-status-view-on-phones.md`.

struct StatusViewRow: Equatable, Sendable {
  enum Tier: String, Decodable, Sendable { case pinned, focus, later, settled }

  var id: String
  var tier: Tier
  /// Opened-by children rendered under this row (one level on phones; deeper ones are flattened).
  var children: [StatusViewRow] = []
  /// `max(lastMessageAt, expired snoozedUntil)`.
  var activityAt: Double = .nan
  var unread = false
  /// Set while the row is in Later.
  var snoozedUntil: Double?
  /// An expired snooze floating at the top of Focus.
  var woken = false
  /// Later / Settle / Move to Focus / reorder in Focus.
  var canManage = false
  /// Pin, unpin and pin placement.
  var canPrefer = false

  /// This row and its children, depth first.
  var family: [StatusViewRow] { [self] + children.flatMap(\.family) }
}

extension StatusViewRow: Decodable {
  private enum CodingKeys: String, CodingKey {
    case id, tier, children, activityAt, unread, snoozedUntil, woken, canManage, canPrefer
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    func value<T: Decodable>(_ key: CodingKeys) -> T? { (try? values.decodeIfPresent(T.self, forKey: key)) ?? nil }
    id = try values.decode(String.self, forKey: .id)
    tier = try values.decode(Tier.self, forKey: .tier)
    let children: [Lossy<StatusViewRow>] = value(.children) ?? []
    self.children = children.compactMap(\.value)
    activityAt = value(.activityAt) ?? .nan
    unread = value(.unread) ?? false
    snoozedUntil = value(.snoozedUntil)
    woken = value(.woken) ?? false
    canManage = value(.canManage) ?? false
    canPrefer = value(.canPrefer) ?? false
  }
}

struct StatusViewPinnedSection: Equatable, Sendable {
  /// nil is the default "Pinned" section.
  var sectionId: String?
  var name: String?
  var rows: [StatusViewRow] = []
  /// Rows of this section the current scope hides.
  var hiddenCount = 0
}

extension StatusViewPinnedSection: Decodable {
  private enum CodingKeys: String, CodingKey { case sectionId, name, rows, hiddenCount }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    sectionId = (try? values.decodeIfPresent(String.self, forKey: .sectionId)) ?? nil
    name = (try? values.decodeIfPresent(String.self, forKey: .name)) ?? nil
    rows = ((try? values.decodeIfPresent([Lossy<StatusViewRow>].self, forKey: .rows)) ?? nil)?.compactMap(\.value) ?? []
    hiddenCount = (try? values.decodeIfPresent(Int.self, forKey: .hiddenCount)) ?? 0
  }
}

struct StatusViewLayout: Equatable, Sendable {
  var pinned: [StatusViewPinnedSection] = []
  var focus: [StatusViewRow] = []
  var later: [StatusViewRow] = []
  var settled: [StatusViewRow] = []
  /// May create, rename, reorder and delete pin sections.
  var canManageSections = false
  /// Earliest future instant at which the layout can change by time alone.
  var nextChangeAt: Double?

  /// Every row by id, children included, each with the tier it renders in.
  var index: [String: StatusViewRow] {
    var result: [String: StatusViewRow] = [:]
    for row in (pinned.flatMap(\.rows) + focus + later + settled).flatMap(\.family) where result[row.id] == nil {
      result[row.id] = row
    }
    return result
  }

  /// Ids rendered in the Pinned area, children included.
  var pinnedIds: Set<String> { Set(pinned.flatMap(\.rows).flatMap(\.family).map(\.id)) }

  /// The layout with every status, pin and section action withdrawn (a read-only member).
  var readOnly: StatusViewLayout {
    func strip(_ row: StatusViewRow) -> StatusViewRow {
      var row = row
      row.canManage = false
      row.canPrefer = false
      row.children = row.children.map(strip)
      return row
    }
    var result = self
    result.pinned = pinned.map { section in
      var section = section
      section.rows = section.rows.map(strip)
      return section
    }
    result.focus = focus.map(strip)
    result.later = later.map(strip)
    result.settled = settled.map(strip)
    result.canManageSections = false
    return result
  }

  func rows(in area: StatusViewArea) -> [StatusViewRow] {
    switch area {
    case .focus: focus
    case .pinned(let id): pinned.first { $0.sectionId == id }?.rows ?? []
    }
  }

  /// The root row containing `id` (itself when it is a root) and the area it renders in.
  func root(of id: String) -> (row: StatusViewRow, area: StatusViewArea?)? {
    for section in pinned {
      if let row = section.rows.first(where: { $0.family.contains { $0.id == id } }) { return (row, .pinned(section.sectionId)) }
    }
    if let row = focus.first(where: { $0.family.contains { $0.id == id } }) { return (row, .focus) }
    if let row = (later + settled).first(where: { $0.family.contains { $0.id == id } }) { return (row, nil) }
    return nil
  }
}

extension StatusViewLayout: Decodable {
  private enum CodingKeys: String, CodingKey { case pinned, focus, later, settled, canManageSections, nextChangeAt }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    func rows(_ key: CodingKeys) -> [StatusViewRow] {
      ((try? values.decodeIfPresent([Lossy<StatusViewRow>].self, forKey: key)) ?? nil)?.compactMap(\.value) ?? []
    }
    pinned = ((try? values.decodeIfPresent([Lossy<StatusViewPinnedSection>].self, forKey: .pinned)) ?? nil)?.compactMap(\.value) ?? []
    focus = rows(.focus)
    later = rows(.later)
    settled = rows(.settled)
    canManageSections = (try? values.decodeIfPresent(Bool.self, forKey: .canManageSections)) ?? false
    nextChangeAt = (try? values.decodeIfPresent(Double.self, forKey: .nextChangeAt)) ?? nil
  }
}

/// `catalog.statusView`: one layout per Home scope.
struct StatusViewLayouts: Decodable, Equatable, Sendable {
  var mine: StatusViewLayout
  var team: StatusViewLayout
  /// Server-clock instant the layouts were computed at.
  var nowMs: Double = .nan
  /// False until the workspace `pinSection` rows have been read once.
  var sectionsLoaded = true
  /// Device-clock instant this catalog was received (the saved catalog's `syncedAt`), so `nowMs`
  /// calibrates the clock correctly even when the catalog is restored from cache later.
  var receivedAt: Double?

  private enum CodingKeys: String, CodingKey { case mine, team, nowMs, sectionsLoaded }

  init(mine: StatusViewLayout, team: StatusViewLayout, nowMs: Double = .nan, sectionsLoaded: Bool = true) {
    self.mine = mine
    self.team = team
    self.nowMs = nowMs
    self.sectionsLoaded = sectionsLoaded
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    mine = try values.decode(StatusViewLayout.self, forKey: .mine)
    team = try values.decode(StatusViewLayout.self, forKey: .team)
    nowMs = (try? values.decodeIfPresent(Double.self, forKey: .nowMs)) ?? .nan
    sectionsLoaded = (try? values.decodeIfPresent(Bool.self, forKey: .sectionsLoaded)) ?? true
  }

  /// The layout a Home scope renders. A read-only member (the host knows the role, the runtime
  /// may not yet) gets no actions; sections are not managed before their rows have been read.
  func layout(team: Bool, readOnly: Bool = false) -> StatusViewLayout {
    var layout = team ? self.team : mine
    if readOnly { layout = layout.readOnly }
    if !sectionsLoaded { layout.canManageSections = false }
    return layout
  }

  /// The row as the scope that lists it renders it (the conversation page has no scope of its own).
  func row(_ id: String, team preferred: Bool, readOnly: Bool = false) -> StatusViewRow? {
    layout(team: preferred, readOnly: readOnly).index[id] ?? layout(team: !preferred, readOnly: readOnly).index[id]
  }

  static func == (left: StatusViewLayouts, right: StatusViewLayouts) -> Bool {
    // `nowMs` is NaN until a runtime sends it; compare it by value so equal snapshots stay equal.
    left.mine == right.mine && left.team == right.team && left.sectionsLoaded == right.sectionsLoaded
      && (left.nowMs == right.nowMs || (left.nowMs.isNaN && right.nowMs.isNaN))
  }
}

/// The runtime's server clock as the host sees it: an offset learned from a `nowMs` paired with the
/// device instant it was produced at, applied to the device clock. A catalog pairs its `nowMs` with
/// the instant it was received (`receivedAt`), so a catalog restored from cache calibrates as well
/// as a live one; `snoozePresets()` replies pair theirs with the reply's arrival. Any skew is
/// accepted: a device clock hours off still gets server-correct countdowns and past-time checks.
struct StatusViewClock: Equatable, Sendable {
  private(set) var offset = 0.0
  /// The device instant of the sample the offset came from; older samples never replace it.
  private var sampledAt = -Double.infinity

  mutating func observe(serverNow: Double, deviceNow: Double) {
    guard serverNow.isFinite, deviceNow.isFinite, deviceNow >= sampledAt else { return }
    sampledAt = deviceNow
    offset = serverNow - deviceNow
  }

  func now(device: Double) -> Double { device + offset }
}

/// `catalog.pinSections`: section definitions in display order (the default section is implicit).
struct StatusViewPinSection: Decodable, Equatable, Sendable {
  var id: String
  var name: String
  var orderKey: String?
}

/// Where a moved row lands: Focus, or a pin section (nil is the default section).
enum StatusViewArea: Hashable, Sendable {
  case focus
  case pinned(String?)

  /// The Home list section rendering this area.
  var sectionId: String {
    switch self {
    case .focus: InboxSections.focusId
    case .pinned(nil): InboxSections.pinnedId
    case .pinned(let id?): InboxSections.pinSectionPrefix + id
    }
  }

  init?(sectionId: String) {
    if sectionId == InboxSections.focusId {
      self = .focus
    } else if sectionId == InboxSections.pinnedId {
      self = .pinned(nil)
    } else if sectionId.hasPrefix(InboxSections.pinSectionPrefix) {
      self = .pinned(String(sectionId.dropFirst(InboxSections.pinSectionPrefix.count)))
    } else {
      return nil
    }
  }
}

/// The runtime's command union; encodes to the note's JSON shape.
enum StatusViewCommand: Equatable, Sendable {
  case snooze(sessionId: String, until: Double, includeOpened: Bool)
  case settle(sessionId: String, includeOpened: Bool)
  case moveToFocus(sessionId: String, includeOpened: Bool)
  case setPinned(sessionId: String, pinned: Bool)
  /// `beforeId` is the row it lands in front of; nil is the end of the area.
  case move(sessionId: String, to: StatusViewArea, beforeId: String?)
  case createSection(sectionId: String, name: String)
  case renameSection(sectionId: String, name: String)
  case deleteSection(sectionId: String)
  case moveSection(sectionId: String, beforeId: String?)

  /// The JSON object the runtime's `statusViewCommand` takes as `command`. Explicit nulls stay,
  /// because `beforeId: null` (end) and the default section (`sectionId: null`) carry meaning.
  var json: [String: Any] {
    switch self {
    case let .snooze(id, until, opened):
      return ["type": "snooze", "sessionId": id, "until": until, "includeOpened": opened]
    case let .settle(id, opened):
      return ["type": "settle", "sessionId": id, "includeOpened": opened]
    case let .moveToFocus(id, opened):
      return ["type": "moveToFocus", "sessionId": id, "includeOpened": opened]
    case let .setPinned(id, pinned):
      return ["type": "setPinned", "sessionId": id, "pinned": pinned]
    case let .move(id, area, before):
      return ["type": "move", "sessionId": id, "to": Self.json(area), "beforeId": before.map { $0 as Any } ?? NSNull()]
    case let .createSection(id, name):
      return ["type": "createSection", "sectionId": id, "name": name]
    case let .renameSection(id, name):
      return ["type": "renameSection", "sectionId": id, "name": name]
    case let .deleteSection(id):
      return ["type": "deleteSection", "sectionId": id]
    case let .moveSection(id, before):
      return ["type": "moveSection", "sectionId": id, "beforeId": before.map { $0 as Any } ?? NSNull()]
    }
  }

  private static func json(_ area: StatusViewArea) -> [String: Any] {
    switch area {
    case .focus: return ["area": "focus"]
    case .pinned(let id): return ["area": "pinned", "sectionId": id.map { $0 as Any } ?? NSNull()]
    }
  }
}

/// One `snoozePresets()` entry: `oneHour`, `laterToday`, `tomorrowMorning` or `nextWeek`, with the
/// wake-up instant it resolves to on the server clock.
struct StatusViewSnoozePreset: Equatable, Sendable {
  var id: String
  var timestamp: Double
}

enum StatusViewFormat {
  /// Web `formatSnoozeCountdown`: `3d`, `2h`, `45m`, `<1m`; nil once expired.
  static func countdown(until: Double, now: Double) -> String? {
    let remaining = until - now
    guard remaining.isFinite, remaining > 0 else { return nil }
    let minute = 60_000.0
    let hour = 60 * minute
    let day = 24 * hour
    if remaining < minute { return "<1m" }
    if remaining < 59.5 * minute { return "\(Int((remaining / minute).rounded(.up)))m" }
    if remaining < 23.5 * hour { return "\(Int((remaining / hour).rounded(.up)))h" }
    return "\(max(1, Int((remaining / day).rounded())))d"
  }
}

struct StatusViewMoveDirections: Equatable {
  let up: Bool
  let down: Bool
}

enum StatusViewPlanning {
  /// The row a drop lands in front of. `items` are the destination section's row ids in display
  /// order (children and footer rows included) before the drop; `roots` says which are top-level
  /// conversations; `index` is the final position UIKit proposes, counted without the dragged row.
  /// A drop among the dragged opener's own children (`family`) lands after that family.
  static func beforeId(
    moving id: String, family: Set<String>, items: [String], roots: Set<String>, index: Int
  ) -> String? {
    let remaining = items.filter { $0 != id }
    guard index < remaining.count else { return nil }
    return remaining[max(0, index)...].first { roots.contains($0) && !family.contains($0) }
  }

  /// The command for dropping root row `id` into `area`, or nil when the drop is not allowed:
  /// Focus takes Focus, Later and Settled rows (`canManage`) and pinned rows, which it unpins
  /// (`canManage` and `canPrefer`, Spec "Dragging a row from … the Pinned area (which unpins it)
  /// into Focus"); the Pinned area takes any row (`canPrefer`).
  static func drop(_ row: StatusViewRow, into area: StatusViewArea, beforeId: String?) -> StatusViewCommand? {
    switch area {
    case .focus:
      guard row.canManage, row.tier != .pinned || row.canPrefer else { return nil }
    case .pinned:
      guard row.canPrefer else { return nil }
    }
    return .move(sessionId: row.id, to: area, beforeId: beforeId == row.id ? nil : beforeId)
  }

  /// A drop target names a row the planner knows. Rows the layout does not list (an Outbox creation
  /// shown at the top of Focus before it reads back) stand for the top of the area, never its end.
  static func knownBefore(_ beforeId: String?, moving id: String, in area: StatusViewArea, of layout: StatusViewLayout) -> String? {
    guard let beforeId else { return nil }
    let ids = layout.rows(in: area).map(\.id)
    if ids.contains(beforeId) { return beforeId }
    return ids.first { $0 != id }
  }

  /// Accessibility Move up / Move down within the row's area: the command, or nil at the edge.
  static func step(_ id: String, up: Bool, in layout: StatusViewLayout) -> StatusViewCommand? {
    guard let found = layout.root(of: id), found.row.id == id, let area = found.area else { return nil }
    guard drop(found.row, into: area, beforeId: nil) != nil else { return nil }
    let ids = layout.rows(in: area).map(\.id)
    guard let position = ids.firstIndex(of: id) else { return nil }
    if up {
      guard position > 0 else { return nil }
      return .move(sessionId: id, to: area, beforeId: ids[position - 1])
    }
    guard position < ids.count - 1 else { return nil }
    return .move(sessionId: id, to: area, beforeId: position + 2 < ids.count ? ids[position + 2] : nil)
  }

  static func moveDirections(in layout: StatusViewLayout) -> [String: StatusViewMoveDirections] {
    var result: [String: StatusViewMoveDirections] = [:]
    func add(_ rows: [StatusViewRow], in area: StatusViewArea) {
      guard rows.count > 1 else { return }
      for (index, row) in rows.enumerated() where drop(row, into: area, beforeId: nil) != nil {
        result[row.id] = .init(up: index > 0, down: index < rows.count - 1)
      }
    }
    add(layout.focus, in: .focus)
    for section in layout.pinned {
      add(section.rows, in: .pinned(section.sectionId))
    }
    return result
  }

  /// "Move to top" of the row's own area (Focus or its pin section); nil when already first.
  static func moveToTop(_ id: String, in layout: StatusViewLayout) -> StatusViewCommand? {
    guard let found = layout.root(of: id), found.row.id == id, let area = found.area else { return nil }
    let row = found.row
    switch area {
    case .focus: guard row.canManage else { return nil }
    case .pinned: guard row.canPrefer else { return nil }
    }
    guard let first = layout.rows(in: area).first?.id, first != id else { return nil }
    return .move(sessionId: id, to: area, beforeId: first)
  }

  /// Section header Move up / Move down among the user sections (the default section stays first).
  static func moveSection(_ id: String, up: Bool, sections: [String]) -> StatusViewCommand? {
    guard let position = sections.firstIndex(of: id) else { return nil }
    if up {
      guard position > 0 else { return nil }
      return .moveSection(sectionId: id, beforeId: sections[position - 1])
    }
    guard position < sections.count - 1 else { return nil }
    return .moveSection(sectionId: id, beforeId: position + 2 < sections.count ? sections[position + 2] : nil)
  }

  /// The commands that undo a Settle or Later, one per conversation it changed, each restoring that
  /// conversation's own prior tier (an opened child already settled stays settled). `previous` is
  /// the acted-on row followed by the opened sub-conversations it carried, as they were rendered.
  static func undo(_ previous: [StatusViewRow], now: Double) -> [StatusViewCommand] {
    var seen = Set<String>()
    return previous.filter { seen.insert($0.id).inserted }.map { undo($0, includeOpened: false, now: now) }
  }

  /// The command that undoes a Settle or Later on `previous` (the row as it was rendered).
  static func undo(_ previous: StatusViewRow, includeOpened: Bool, now: Double) -> StatusViewCommand {
    switch previous.tier {
    case .later:
      if let until = previous.snoozedUntil, until > now {
        return .snooze(sessionId: previous.id, until: until, includeOpened: includeOpened)
      }
      return .moveToFocus(sessionId: previous.id, includeOpened: includeOpened)
    case .settled:
      return .settle(sessionId: previous.id, includeOpened: includeOpened)
    case .focus, .pinned:
      return .moveToFocus(sessionId: previous.id, includeOpened: includeOpened)
    }
  }
}

/// A dropped order held on screen until the catalog reads the write back. Applying it moves the
/// dropped family into its target area in front of `beforeId`; it never reorders anything else.
struct StatusViewHold: Equatable, Sendable {
  var sessionId: String
  var area: StatusViewArea
  var beforeId: String?
  /// The published layout when the row was dropped.
  var base: StatusViewLayout
  /// The runtime accepted the write.
  var acknowledged = false
  var failed = false
  /// Other local moves in flight can change a neighbour without moving this row.
  var concurrentMoves: Set<String> = []

  init?(_ command: StatusViewCommand, base: StatusViewLayout) {
    guard case let .move(id, area, before) = command else { return nil }
    sessionId = id
    self.area = area
    beforeId = before
    self.base = base
  }

  /// Whether `layout`, the one now published, replaces the held order: the write failed, the row
  /// already shows where it was dropped, or the write was accepted and the published layout moved
  /// this row. Unrelated catalog updates that arrive before the write reads back leave the row where
  /// it was in `base`, so they keep the hold instead of flashing the old order.
  func released(by layout: StatusViewLayout) -> Bool {
    failed || landed(in: layout) || (acknowledged && placement(in: layout) != placement(in: base))
  }

  /// Where the row renders: its area or tier and the row after it.
  private func placement(in layout: StatusViewLayout) -> String {
    for (name, rows) in [("focus", layout.focus), ("later", layout.later), ("settled", layout.settled)]
      + layout.pinned.map({ ("pinned:" + ($0.sectionId ?? ""), $0.rows) }) {
      if let position = rows.firstIndex(where: { $0.id == sessionId }) {
        let next = rows[(position + 1)...].first { !concurrentMoves.contains($0.id) }
        return name + ">" + (next?.id ?? "")
      }
    }
    return ""
  }

  /// Several holds apply in order, so a second quick move never drops the first one's order.
  static func apply(_ holds: [StatusViewHold], to layout: StatusViewLayout) -> StatusViewLayout {
    holds.reduce(layout) { $1.apply(to: $0) }
  }

  /// The published layout already shows the row where it was dropped.
  func landed(in layout: StatusViewLayout) -> Bool {
    let ids = layout.rows(in: area).map(\.id)
    guard let position = ids.firstIndex(of: sessionId) else { return false }
    let next = position + 1 < ids.count ? ids[position + 1] : nil
    return next == beforeId
  }

  func apply(to layout: StatusViewLayout) -> StatusViewLayout {
    guard let root = layout.root(of: sessionId)?.row, root.id == sessionId else { return layout }
    var result = layout
    func remove(_ rows: inout [StatusViewRow]) { rows.removeAll { $0.id == sessionId } }
    remove(&result.focus)
    remove(&result.later)
    remove(&result.settled)
    for index in result.pinned.indices { remove(&result.pinned[index].rows) }
    var moved = root
    var rows = result.rows(in: area)
    switch area {
    case .focus:
      moved.tier = .focus
      moved.snoozedUntil = nil
    case .pinned:
      moved.tier = .pinned
    }
    let position = beforeId.flatMap { before in rows.firstIndex { $0.id == before } } ?? rows.count
    rows.insert(moved, at: position)
    switch area {
    case .focus:
      result.focus = rows
    case .pinned(let id):
      if let section = result.pinned.firstIndex(where: { $0.sectionId == id }) {
        result.pinned[section].rows = rows
      } else {
        // The default section is omitted from the layout while it is empty.
        result.pinned.insert(StatusViewPinnedSection(sectionId: id, name: nil, rows: rows), at: id == nil ? 0 : result.pinned.count)
      }
    }
    return result
  }
}

/// What opening a conversation marks read. The page's own conversation is read up to its latest
/// message; its root conversation (itself, or the conversation a Tab belongs to) is also read up to
/// a woken snooze, the unread the Status view derives from `max(lastMessageAt, snoozedUntil)`. A Tab
/// never clears its root's own unread messages, which the person has not seen.
enum StatusViewRead {
  struct Receipt: Equatable, Sendable {
    var sessionId: String
    /// `lastReadAt` to write (server clock).
    var at: Double
    /// The watermark the local viewed store records, so the list clears before the receipt syncs.
    var viewed: Double
  }

  static func receipts(page: SessionItem, root: SessionItem, rootRow: StatusViewRow?, now: Double) -> [Receipt] {
    var result: [Receipt] = []
    if let message = page.lastMessageAt, message.isFinite, !page.isTabClosed, message > (page.lastReadAt ?? -.infinity) {
      result.append(Receipt(sessionId: page.id, at: max(now, message), viewed: message))
    }
    guard let rootRow, rootRow.id == root.id, rootRow.unread, rootRow.activityAt.isFinite else { return result }
    let read = root.lastReadAt ?? -.infinity
    // Only the wake-up is unread: the root's own messages are read, or this is the root's page.
    let messagesRead = (root.lastMessageAt ?? -.infinity) <= read || page.id == root.id
    guard messagesRead, rootRow.activityAt > read else { return result }
    let at = max(now, rootRow.activityAt)
    if let index = result.firstIndex(where: { $0.sessionId == root.id }) {
      result[index].at = max(result[index].at, at)
      result[index].viewed = max(result[index].viewed, rootRow.activityAt)
    } else {
      result.append(Receipt(sessionId: root.id, at: at, viewed: rootRow.activityAt))
    }
    return result
  }
}
