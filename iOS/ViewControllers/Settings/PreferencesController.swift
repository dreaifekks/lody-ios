import UIKit

@MainActor
class PreferencesController: UIViewController {
  private let list = LodyGroupedList(frame: .zero)
  private var observers: [NSObjectProtocol] = []
  private let scope: SettingsScope
  private let voiceAgents: @MainActor () async throws -> VoiceSettings.Snapshot
  private var workspace = ""
  private var snapshot: VoiceSettings.Snapshot?
  private var failed = false
  private var version = 0

  init(scope: SettingsScope = .catalog, voiceAgents: @escaping @MainActor () async throws -> VoiceSettings.Snapshot = VoiceService.agents) {
    self.scope = scope
    self.voiceAgents = voiceAgents
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
    for name in [Notification.Name.lodyPreferencesDidChange, VoicePreferences.didChange, scope.change] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.syncVoice() }
      })
    }
    syncVoice()
  }

  private func syncVoice() {
    let key = scope.current().key
    version += 1
    let version = version
    if workspace != key { snapshot = nil; failed = false }
    workspace = key
    render()
    guard VoicePreferences.enabled, !key.isEmpty else { return }
    Task { [weak self, voiceAgents] in
      let result = try? await voiceAgents()
      guard let self, self.version == version else { return }
      self.snapshot = result
      self.failed = result == nil
      self.render()
    }
  }

  private func render() {
    let language = text("preferences.languageName")
    let current = LodyPreferences.queuedMessageBehavior
    var queued = LodyListRow.item(
      "queued-message-behavior", text("queuedMessageBehavior.title"), value: text("queuedMessageBehavior.\(current)"),
      image: "arrow.uturn.forward"
    )
    queued.options = ["queue", "guide"].map { option($0, text("queuedMessageBehavior.\($0)"), selected: $0 == current) }
    list.setSections([
      .group("language-section", footer: text("preferences.languageHint"), [
        .item(
          "language", text("preferences.language"), value: language, image: "globe", disclosure: true,
          accessibilityValue: language
        ),
      ]),
      .group("notifications-section", header: text("preferences.notifications"), [
        .item("notifications", text("notifications.title"), image: "bell", disclosure: true, navigates: true),
      ]),
      .group("chat", header: text("preferences.chat"), footer: text("queuedMessageBehavior.hint"), [
        queued,
        .item("quick-replies", text("quickReplies.title"), image: "text.bubble", disclosure: true, navigates: true),
      ]),
      VoiceSettings.section(snapshot: snapshot, failed: failed, signedIn: !workspace.isEmpty),
    ])
  }

  private func event(_ name: String, _ body: [String: Any]) {
    guard let id = body["id"] as? String else { return }
    switch (name, id, body["actionId"] as? String) {
    case ("rowAction", "queued-message-behavior", let value?) where ["queue", "guide"].contains(value):
      LodyPreferences.saveQueuedMessageBehavior(value)
    case ("rowToggle", "voice-dictation", _):
      let agent = VoicePreferences.agent
      VoicePreferences.save(enabled: body["value"] as! Bool, configId: agent?["configId"] ?? "", machineId: agent?["machineId"] ?? "")
    case ("rowAction", "voice-agent", let id?):
      VoiceSettings.choose(id, snapshot: snapshot)
    case ("rowPress", "language", _):
      openLanguageSettings()
    case ("rowPress", "notifications", _):
      LodyShell.shared.openPage("notification-settings", from: self)
    case ("rowPress", "quick-replies", _):
      LodyShell.shared.push(QuickRepliesController(), title: text("quickReplies.title"), from: self)
    default:
      break
    }
  }

  private func openLanguageSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url) { opened in
      guard !opened else { return }
      LodyToastOverlay.shared.show(message: String(localized: "settings.preferences.languageFailed", bundle: .lody), kind: "error")
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
