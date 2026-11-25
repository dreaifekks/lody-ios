import UIKit

@MainActor
final class PreferencesController: UIViewController {
  private let list = LodyGroupedList(frame: .zero)
  private var observers: [NSObjectProtocol] = []

  private var sharing: Bool?
  private var savingSharing = false
  private var sharingFailed = false

  typealias UsagePreference = @MainActor (Bool?) async throws -> Bool
  private let usagePreference: UsagePreference

  init(usagePreference: @escaping UsagePreference = PreferencesController.accountSharing) {
    self.usagePreference = usagePreference
    super.init(nibName: nil, bundle: nil)
    title = text("preferences.title")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  isolated deinit { observers.forEach(NotificationCenter.default.removeObserver) }

  override func viewDidLoad() {
    super.viewDidLoad()
    list.frame = view.bounds
    list.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    list.forwarded = { [weak self] name, body in self?.event(name, body) }
    view.addSubview(list)
    for name in [Notification.Name.lodyPreferencesDidChange, .lodyAppearanceDidChange, UIApplication.didBecomeActiveNotification] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.render() }
      })
    }
    render()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    if !savingSharing { Task { await refreshSharing() } }
    render()
  }

  private func refreshSharing(_ enabled: Bool? = nil) async {
    guard !savingSharing else { return }
    savingSharing = true
    sharingFailed = false
    render()
    defer { savingSharing = false; render() }
    do {
      sharing = try await usagePreference(enabled)
    } catch {
      sharing = nil
      sharingFailed = true
    }
  }

  static func accountSharing(_ enabled: Bool?) async throws -> Bool {
    if let enabled {
      _ = try await GitHubCloud.call("mutation", path: "analytics:setUsageSharing", args: ["enabled": enabled])
      return enabled
    }
    guard let value = try await GitHubCloud.call("query", path: "analytics:getUsageSharing", args: [:]) as? Bool else { throw GitHubCloud.failure() }
    return value
  }

  private func sharingRow() -> LodyListRow {
    var row = LodyListRow.item("usage-sharing", text("preferences.usageSharing"), image: "chart.bar")
    row.toggle = sharing
    row.action = sharing != nil && !savingSharing
    if sharingFailed { row.subtitle = text("preferences.sharingRetry"); row.action = true }
    return row
  }

  private func appIconRow() -> LodyListRow {
    let icon = LodyAppIcon.current
    let value = icon == "Aqua" ? "Aqua" : text("preferences.defaultIcon")
    var row = LodyListRow.item(
      "app-icon", text("preferences.appIcon"), value: value, imageAsset: "AppIconPreview-\(icon)", disclosure: true,
      navigates: true, accessibilityValue: value
    )
    row.imageOriginal = true
    return row
  }

  private func render() {
    let language = text("preferences.languageName")
    let current = LodyPreferences.queuedMessageBehavior
    var queued = LodyListRow.item(
      "queued-message-behavior", text("queuedMessageBehavior.title"), value: text("queuedMessageBehavior.\(current)"),
      image: "arrow.uturn.forward"
    )
    queued.options = ["queue", "guide"].map { option($0, text("queuedMessageBehavior.\($0)"), selected: $0 == current) }
    let sections: [LodyListSection] = [
      .group("general", header: text("preferences.general"), [
        .item(
          "language", text("preferences.language"), value: language, image: "globe", disclosure: true,
          accessibilityValue: language
        ),
        .item("notifications", text("notifications.title"), image: "bell", disclosure: true, navigates: true),
        sharingRow(),
      ]),
      .group("chat", header: text("preferences.chat"), [
        queued,
      ]),
      .group("appearance", header: text("preferences.appearance"), [appIconRow()]),
    ]
    // A choice re-renders while its menu is still dismissing; animating the reconfigure
    // under it reads as rows jumping, and this page's structure never changes.
    list.setSections(sections, animated: false)
  }

  private func event(_ name: String, _ body: [String: Any]) {
    guard let id = body["id"] as? String else { return }
    switch (name, id, body["actionId"] as? String) {
    case ("rowToggle", "usage-sharing", _):
      if let value = body["value"] as? Bool { Task { await refreshSharing(value) } }
    case ("rowPress", "usage-sharing", _):
      if sharingFailed { Task { await refreshSharing() } }
    case ("rowAction", "queued-message-behavior", let value?) where ["queue", "guide"].contains(value):
      LodyPreferences.saveQueuedMessageBehavior(value)
    case ("rowPress", "app-icon", _):
      LodyShell.shared.pushNative("app-icon", title: text("preferences.appIcon"), from: self)
    case ("rowPress", "language", _):
      openLanguageSettings()
    case ("rowPress", "notifications", _):
      LodyShell.shared.openPage("notification-settings", from: self)
    default:
      break
    }
  }

  private func openLanguageSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url) { opened in
      guard !opened else { return }
      LodyToastOverlay.shared.show(message: String(localized: "settings.preferences.languageFailed", bundle: .lody), kind: .error)
    }
  }

  private func option(_ id: String, _ title: String, selected: Bool) -> LodyListAction {
    var action = LodyListAction()
    action.id = id
    action.title = title
    action.selected = selected
    return action
  }

  private func text(_ key: String) -> String { String(localized: String.LocalizationValue("settings." + key), bundle: .lody) }
}
