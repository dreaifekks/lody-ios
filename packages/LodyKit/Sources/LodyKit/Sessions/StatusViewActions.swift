import LodyDesignSystem
import SwiftUI
import UIKit

/// Status view and pin section actions shared by Home rows, section labels and the conversation
/// page's More menu. Every write is a `StatusViewCommand` planned by the runtime; this type only
/// decides what to offer (from the layout row's tier and permissions), asks the questions desktop
/// asks, and confirms Settle and Later with an Undo notice.
@MainActor
final class StatusViewActions {
  private let source: SessionSource
  /// Runs a move so the list can hold the dropped order (Home); nil runs moves directly.
  var runMove: (@MainActor (StatusViewCommand) -> Void)?
  private var presets: (at: Date, items: [StatusViewSnoozePreset], workspaceId: String)?

  /// The runtime's server clock; layouts, countdowns and presets are all on it.
  static var clock = StatusViewClock()
  static var now: Double { clock.now(device: LodyRelativeTime.now()) }

  init(source: SessionSource) {
    self.source = source
  }

  /// Whether the signed-in user is a read-only member (from the member list's role).
  static func readOnly(_ state: SessionListState) -> Bool {
    WorkspaceMembers.readOnly(userId: state.userId, workspaceId: state.workspaceId) == true
  }

  /// The layout Home shows in the current scope.
  var layout: StatusViewLayout? {
    let state = source.state
    return state.catalog.statusView?.layout(team: HomeScope.stored == .team, readOnly: Self.readOnly(state))
  }

  func row(_ id: String) -> StatusViewRow? {
    let state = source.state
    return state.catalog.statusView?.row(id, team: HomeScope.stored == .team, readOnly: Self.readOnly(state))
  }

  // MARK: Menus

  /// A Home row's status menu: Later ▸, Settle / Move to Focus, Pin, Move to section ▸, Move to top.
  func menu(_ id: String, from controller: UIViewController) -> [UIMenuElement] {
    guard let layout, let row = layout.index[id] else { return [] }
    var items = tierItems(row, from: controller)
    if row.canPrefer {
      let pinned = row.tier == .pinned
      items.append(UIAction(
        title: text(pinned ? "session.action.unpin" : "session.action.pin"), image: UIImage(systemName: pinned ? "pin.slash" : "pin")
      ) { [weak self] _ in self?.run(.setPinned(sessionId: id, pinned: !pinned)) })
      items.append(sectionMenu(row, layout: layout, from: controller))
    }
    if let top = StatusViewPlanning.moveToTop(id, in: layout) {
      items.append(UIAction(title: text("home.status.moveToTop"), image: UIImage(systemName: "arrow.up.to.line")) { [weak self] _ in
        self?.move(top)
      })
    }
    return items
  }

  /// Later / Settle / Move to Focus for the row's tier; the conversation page's More menu uses these alone.
  func tierItems(_ row: StatusViewRow, from controller: UIViewController) -> [UIMenuElement] {
    guard row.canManage else { return [] }
    let id = row.id
    let settle = UIAction(title: text("home.status.settle"), image: UIImage(systemName: "checkmark.circle")) { [weak self, weak controller] _ in
      guard let controller else { return }
      self?.settle(id, from: controller)
    }
    switch row.tier {
    case .focus: return [laterMenu(row, from: controller), settle]
    case .later: return [laterMenu(row, from: controller), settle]
    case .settled: return [focusAction(id, from: controller)]
    case .pinned: return []
    }
  }

  private func focusAction(_ id: String, from controller: UIViewController) -> UIAction {
    UIAction(title: text("home.status.moveToFocus"), image: UIImage(systemName: "arrow.uturn.backward.circle")) { [weak self, weak controller] _ in
      guard let controller else { return }
      self?.moveToFocus(id, from: controller)
    }
  }

  /// Presets with their resolved times (cached from the runtime), a custom time, and Move to
  /// Focus while snoozed. A preset is resolved again when picked, so its instant is current.
  private func laterMenu(_ row: StatusViewRow, from controller: UIViewController) -> UIMenu {
    let workspaceId = source.state.workspaceId
    let id = row.id
    let resolved = UIDeferredMenuElement.uncached { [weak self, weak controller] complete in
      Task { @MainActor in
        guard let self, let controller, self.source.state.workspaceId == workspaceId else { return complete([]) }
        var items = self.cachedPresets(workspaceId)
        if items.isEmpty || self.presets.map({ Date().timeIntervalSince($0.at) >= 60 }) == true {
          items = (try? await self.loadPresets(workspaceId)) ?? items
        }
        guard self.source.state.workspaceId == workspaceId else { return complete([]) }
        complete(items.map { preset in
          UIAction(title: self.presetTitle(preset.id), subtitle: Self.resolved(preset.timestamp)) { [weak self, weak controller] _ in
            guard let self, let controller else { return }
            Task {
              let fresh = (try? await self.loadPresets(workspaceId))?.first { $0.id == preset.id }
              guard self.source.state.workspaceId == workspaceId else { return }
              self.snooze(id, until: fresh?.timestamp ?? preset.timestamp, from: controller)
            }
          }
        })
      }
    }
    var children: [UIMenuElement] = [resolved]
    children.append(UIAction(title: text("home.status.later.custom"), image: UIImage(systemName: "calendar")) { [weak self, weak controller] _ in
      guard let controller else { return }
      self?.presentLater(id, from: controller)
    })
    if row.tier == .later { children.append(focusAction(id, from: controller)) }
    return UIMenu(title: text("home.status.later"), image: UIImage(systemName: "clock"), children: children)
  }

  /// Move to section ▸: the other pin sections (each places the row at its top) and New section….
  private func sectionMenu(_ row: StatusViewRow, layout: StatusViewLayout, from controller: UIViewController) -> UIMenu {
    let id = row.id
    let current = row.tier == .pinned ? layout.root(of: id)?.area : nil
    // Section definitions arrive in render order, including sections the layout leaves out.
    var targets: [(StatusViewArea, String)] = [(.pinned(nil), text("inbox.section.pinned"))]
    if source.state.catalog.statusView?.sectionsLoaded != false {
      targets += source.state.catalog.pinSections.map { (StatusViewArea.pinned($0.id), $0.name) }
    }
    var children: [UIMenuElement] = targets.filter { $0.0 != current }.map { area, name in
      UIAction(title: name) { [weak self] _ in
        let top = layout.rows(in: area).first { $0.id != id }?.id
        self?.move(.move(sessionId: id, to: area, beforeId: top))
      }
    }
    if layout.canManageSections {
      children.append(UIAction(title: text("home.pins.newSection"), image: UIImage(systemName: "plus")) { [weak self, weak controller] _ in
        guard let controller else { return }
        self?.promptSectionName(title: self?.text("home.pins.newSection") ?? "", initial: "", from: controller) { name in
          let sectionId = UUID().uuidString.lowercased()
          Task { [weak self] in
            guard let self, (await self.perform(.createSection(sectionId: sectionId, name: name)) ?? 0) > 0 else { return }
            self.move(.move(sessionId: id, to: .pinned(sectionId), beforeId: nil))
          }
        }
      })
    }
    return UIMenu(title: text("home.status.moveToSection"), image: UIImage(systemName: "folder"), children: children)
  }

  // MARK: Row actions

  /// `rowAction` ids from swipe actions (`InboxSections.statusActions`).
  func perform(_ actionId: String, row id: String, from controller: UIViewController) -> Bool {
    switch actionId {
    case InboxSections.statusActions.settle: settle(id, from: controller)
    case InboxSections.statusActions.later: presentLater(id, from: controller)
    case InboxSections.statusActions.focus: moveToFocus(id, from: controller)
    case "pin":
      guard let row = row(id) else { return false }
      if row.canPrefer { run(.setPinned(sessionId: id, pinned: row.tier != .pinned)) }
    default: return false
    }
    return true
  }

  func settle(_ id: String, from controller: UIViewController) {
    guard let previous = row(id) else { return }
    askOpened(id, action: "settle", from: controller) { [weak self] opened in
      self?.confirming(.settle(sessionId: id, includeOpened: opened), previous: previous, opened: opened, message: self?.text("home.status.toast.settled") ?? "")
    }
  }

  func moveToFocus(_ id: String, from controller: UIViewController) {
    askOpened(id, action: "focus", from: controller) { [weak self] opened in
      self?.run(.moveToFocus(sessionId: id, includeOpened: opened))
    }
  }

  func snooze(_ id: String, until: Double, from controller: UIViewController) {
    guard let previous = row(id) else { return }
    guard until > Self.now else {
      LodyToastOverlay.shared.show(message: text("home.status.later.past"), kind: .error)
      return
    }
    askOpened(id, action: "snooze", from: controller) { [weak self] opened in
      guard let self else { return }
      let message = String.localizedStringWithFormat(self.text("home.status.toast.snoozed"), Self.resolved(until))
      self.confirming(.snooze(sessionId: id, until: until, includeOpened: opened), previous: previous, opened: opened, message: message)
    }
  }

  /// The Later sheet: the runtime's presets with resolved times and a custom date and time.
  func presentLater(_ id: String, from controller: UIViewController) {
    let workspaceId = source.state.workspaceId
    let model = StatusLaterModel(presets: cachedPresets(workspaceId))
    let sheet = UIHostingController(rootView: StatusLaterSheet(model: model))
    model.dismiss = { [weak sheet] in sheet?.dismiss(animated: true) }
    model.serverOffset = Self.clock.offset
    model.pick = { [weak self, weak controller, weak sheet] until in
      sheet?.dismiss(animated: true) {
        guard let self, let controller, self.source.state.workspaceId == workspaceId else { return }
        self.snooze(id, until: until, from: controller)
      }
    }
    sheet.view.backgroundColor = LodyUIColor.bgBase
    if let presentation = sheet.sheetPresentationController {
      presentation.detents = [.medium(), .large()]
      presentation.prefersGrabberVisible = true
    }
    controller.present(sheet, animated: true)
    Task {
      do {
        model.presets = try await loadPresets(workspaceId)
        model.serverOffset = Self.clock.offset
      } catch {
        model.failed = model.presets.isEmpty
      }
    }
  }

  // MARK: Section actions

  /// `sectionAction` ids from a pin section label's ⋯ menu (`InboxSections.sectionActions`).
  func performSection(_ actionId: String, section listId: String, from controller: UIViewController) {
    guard let layout, layout.canManageSections, case .pinned(let sectionId)? = StatusViewArea(sectionId: listId) else { return }
    let actions = InboxSections.sectionActions
    let definitions = source.state.catalog.pinSections
    let userSections = definitions.map(\.id)
    let name = definitions.first { $0.id == sectionId }?.name ?? layout.pinned.first { $0.sectionId == sectionId }?.name ?? ""
    switch actionId {
    case actions.create:
      promptSectionName(title: text("home.pins.newSection"), initial: "", from: controller) { [weak self] name in
        self?.run(.createSection(sectionId: UUID().uuidString.lowercased(), name: name))
      }
    case actions.rename:
      guard let sectionId else { return }
      promptSectionName(title: text("home.pins.rename"), initial: name, from: controller) { [weak self] next in
        guard next != name else { return }
        self?.run(.renameSection(sectionId: sectionId, name: next))
      }
    case actions.up, actions.down:
      guard let sectionId, let command = StatusViewPlanning.moveSection(sectionId, up: actionId == actions.up, sections: userSections) else { return }
      run(command)
    case actions.delete:
      guard let sectionId else { return }
      let alert = UIAlertController(
        title: String.localizedStringWithFormat(text("home.pins.delete.title"), name), message: text("home.pins.delete.message"),
        preferredStyle: .alert
      )
      alert.addAction(UIAlertAction(title: text("common.cancel"), style: .cancel))
      alert.addAction(UIAlertAction(title: text("home.pins.delete"), style: .destructive) { [weak self] _ in
        self?.run(.deleteSection(sectionId: sectionId))
      })
      controller.present(alert, animated: true)
    default:
      break
    }
  }

  private func promptSectionName(title: String, initial: String, from controller: UIViewController, done: @escaping (String) -> Void) {
    let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
    alert.addTextField { field in
      field.text = initial
      field.placeholder = String(localized: "home.pins.name", bundle: .lody)
      field.autocapitalizationType = .sentences
    }
    alert.addAction(UIAlertAction(title: text("common.cancel"), style: .cancel))
    alert.addAction(UIAlertAction(title: text("common.save"), style: .default) { [weak alert] _ in
      let name = String((alert?.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
      guard !name.isEmpty else { return }
      done(name)
    })
    controller.present(alert, animated: true)
  }

  // MARK: Running commands

  func run(_ command: StatusViewCommand) {
    Task { _ = await perform(command) }
  }

  private func move(_ command: StatusViewCommand) {
    if let runMove { runMove(command) } else { run(command) }
  }

  /// Runs `command` in the current Home scope; a failure warns once. Returns the rows the runtime
  /// wrote (0: the planner refused it or nothing changed), or nil when the write failed.
  func perform(_ command: StatusViewCommand) async -> Int? {
    let workspaceId = source.state.workspaceId
    guard !workspaceId.isEmpty else { return nil }
    do {
      return try await source.statusCommand(workspaceId, command, HomeScope.stored)
    } catch {
      if source.state.workspaceId == workspaceId {
        LodyToastOverlay.shared.show(message: text("home.status.toast.failed"), kind: .error)
      }
      return nil
    }
  }

  /// Settle and Later confirm with an Undo notice that puts the conversation back where it was.
  private func confirming(_ command: StatusViewCommand, previous: StatusViewRow, opened: Bool, message: String) {
    Task {
      // Nothing written (already settled, or refused) has nothing to undo.
      guard (await perform(command) ?? 0) > 0 else { return }
      LodyToastOverlay.shared.show(message: message, kind: .neutral, actionTitle: text("home.status.toast.undo")) { [weak self] in
        self?.run(StatusViewPlanning.undo(previous, includeOpened: opened, now: Self.now))
      }
    }
  }

  /// Desktop's "apply to opened sub-conversations too?" question, asked only when the conversation
  /// has active opened sub-conversations. `done` receives whether they follow.
  private func askOpened(_ id: String, action: String, from controller: UIViewController, done: @escaping (Bool) -> Void) {
    let opened = source.state.catalog.sessions.filter { session in
      !session.archived && !SessionRows.isTab(session) && session.id != id
        && (session.openedBySessionId == id || session.openedByRootSessionId == id)
    }
    guard !opened.isEmpty else { return done(false) }
    let working = opened.filter { SessionState($0) == .live }.count
    let key = "home.status.opened." + action
    let alert = UIAlertController(
      title: text(key + ".title"),
      message: working > 0 ? String.localizedStringWithFormat(text("home.status.opened.working"), working) : nil,
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: text("common.cancel"), style: .cancel))
    alert.addAction(UIAlertAction(title: text(key + ".only"), style: .default) { _ in done(false) })
    alert.addAction(UIAlertAction(title: text(key + ".all"), style: .default) { _ in done(true) })
    controller.present(alert, animated: true)
  }

  // MARK: Presets

  private func cachedPresets(_ workspaceId: String) -> [StatusViewSnoozePreset] {
    guard let presets, presets.workspaceId == workspaceId else { return [] }
    let now = Self.now
    return presets.items.filter { $0.timestamp > now }
  }

  /// Fetches the presets; their `nowMs` also calibrates the server clock.
  private func loadPresets(_ workspaceId: String) async throws -> [StatusViewSnoozePreset] {
    let result = try await StatusViewRuntime.presets(workspaceId)
    Self.clock.observe(serverNow: result.nowMs, deviceNow: LodyRelativeTime.now())
    presets = (Date(), result.presets, workspaceId)
    return result.presets
  }

  private func presetTitle(_ id: String) -> String {
    let keys = ["oneHour": "home.status.later.oneHour", "laterToday": "home.status.later.laterToday",
                "tomorrowMorning": "home.status.later.tomorrowMorning", "nextWeek": "home.status.later.nextWeek"]
    return keys[id].map(text) ?? id
  }

  /// A server-clock instant as the person reads it on this device.
  static func resolved(_ timestamp: Double) -> String {
    let date = Date(timeIntervalSince1970: (timestamp - clock.offset) / 1000)
    if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
    return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
  }

  private func text(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), bundle: .lody)
  }
}

// MARK: - Later sheet

@MainActor
final class StatusLaterModel: ObservableObject {
  @Published var presets: [StatusViewSnoozePreset]
  @Published var failed = false
  /// Server clock minus device clock; the date picker works on device time.
  var serverOffset = 0.0
  var pick: @MainActor (Double) -> Void = { _ in }
  var dismiss: @MainActor () -> Void = {}

  init(presets: [StatusViewSnoozePreset]) {
    self.presets = presets
  }
}

/// Later: the four presets, each with its resolved time, and a custom date and time in the same
/// sheet. Past times are refused.
private struct StatusLaterSheet: View {
  @ObservedObject var model: StatusLaterModel
  @State private var custom = Date().addingTimeInterval(3600)
  @State private var refused = false

  private static let titles = [
    "oneHour": "home.status.later.oneHour", "laterToday": "home.status.later.laterToday",
    "tomorrowMorning": "home.status.later.tomorrowMorning", "nextWeek": "home.status.later.nextWeek",
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: LodySpacing.md) {
      HStack {
        Text(String(localized: "home.status.later", bundle: .lody)).lodyTextStyle(.headline).foregroundStyle(LodyColor.textPrimary)
        Spacer()
        Button(String(localized: "common.cancel", bundle: .lody)) { model.dismiss() }
      }
      VStack(spacing: 0) {
        ForEach(model.presets, id: \.id) { preset in
          Button { model.pick(preset.timestamp) } label: {
            HStack {
              Text(String(localized: String.LocalizationValue(Self.titles[preset.id] ?? preset.id), bundle: .lody))
                .lodyTextStyle(.body).foregroundStyle(LodyColor.textPrimary)
              Spacer()
              Text(StatusViewActions.resolved(preset.timestamp))
                .lodyTextStyle(.footnote).foregroundStyle(LodyColor.textSecondary).monospacedDigit()
            }
            .frame(minHeight: LodySize.listRow)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("later-preset:" + preset.id)
        }
        if model.presets.isEmpty {
          Text(String(localized: String.LocalizationValue(model.failed ? "home.status.later.presetsFailed" : "common.loading"), bundle: .lody))
            .lodyTextStyle(.footnote).foregroundStyle(LodyColor.textTertiary)
            .frame(maxWidth: .infinity, minHeight: LodySize.listRow, alignment: .leading)
        }
      }
      Divider()
      DatePicker(
        String(localized: "home.status.later.custom", bundle: .lody), selection: $custom, in: Date()...,
        displayedComponents: [.date, .hourAndMinute]
      )
      .lodyTextStyle(.body)
      .onChange(of: custom) { _ in refused = false }
      if refused {
        Text(String(localized: "home.status.later.past", bundle: .lody)).lodyTextStyle(.footnote).foregroundStyle(LodyColor.dangerDefault)
      }
      Button {
        let until = custom.timeIntervalSince1970 * 1000 + model.serverOffset
        guard until > LodyRelativeTime.now() + model.serverOffset else {
          refused = true
          return
        }
        model.pick(until)
      } label: {
        Text(String(localized: "home.status.later.confirm", bundle: .lody)).frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .accessibilityIdentifier("later-custom-confirm")
      Spacer(minLength: 0)
    }
    .padding(.horizontal, LodyLayout.screenPaddingX)
    .padding(.top, LodySpacing.xl)
  }
}
