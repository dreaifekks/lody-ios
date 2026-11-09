import UIKit

@MainActor
final class VoicePreviewController: UIViewController {
  private let fixture = VoiceFixture()
  private let host: String
  private var composer: ChatComposerView!
  private var composerHeight: NSLayoutConstraint!
  private var retainedHost: UIView?
  private let status = UILabel()

  init(host: String = "chat") {
    self.host = host
    super.init(nibName: nil, bundle: nil)
    title = "Voice · " + host
  }
  required init?(coder: NSCoder) { fatalError() }
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemGroupedBackground
    VoicePreferences.save(enabled: true)
    if host == "create" {
      let wrapper = LodyComposerView(frame: .zero)
      retainedHost = wrapper
      composer = wrapper.composer
    } else {
      let chat = LodyChatView(frame: .zero)
      retainedHost = chat
      composer = chat.composer
    }
    composer.voiceFactory = { [fixture] in fixture.dictation() }
    // Replace the idle instance initialized while the host was assembled.
    composer.resetVoiceDictation()
    composerHeight = composer.heightAnchor.constraint(equalToConstant: 64)
    composerHeight.isActive = true
    composer.onHeightChange = { [weak self] height in self?.composerHeight.constant = height }
    composer.setComposerState(#"{"editable":true,"canSend":true}"#)
    composer.setInputIdentifier("voice-input")
    composer.setInitialDraft("Draft")
    composer.onSend = { [weak self] _ in self?.status.text = "Sent" }
    status.accessibilityIdentifier = "voice-calls"
    status.text = "Ready"
    fixture.onCalls = { [weak self] in self?.status.text = self?.fixture.calls.joined(separator: ",") }
    let preferences = button("Preferences", "voice-preferences") { [weak self] in
      guard let self else { return }
      let page = PreferencesController(scope: SettingsScope(change: Notification.Name("VoiceFixtureScope")) {
        SettingsWorkspace(userId: "local:fixture", workspaceId: "lw_fixture")
      }, voiceAgents: { VoiceFixture.agents })
      LodyShell.shared.present(page, title: "Preferences")
    }
    let connect = button("Connect", "voice-connect") { [fixture] in fixture.connect() }
    let transcript = button("Transcript", "voice-transcript") { [fixture] in fixture.transcript() }
    let failure = button("Fail next start", "voice-fail") { [fixture] in fixture.fail = true }
    let first = UIStackView(arrangedSubviews: [preferences, connect])
    let second = UIStackView(arrangedSubviews: [transcript, failure])
    for row in [first, second] { row.distribution = .fillEqually; row.spacing = 8 }
    let stack = UIStackView(arrangedSubviews: [status, first, second])
    stack.axis = .vertical; stack.spacing = 8
    view.addSubview(stack); view.addSubview(composer)
    stack.translatesAutoresizingMaskIntoConstraints = false; composer.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
      stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
      composer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
      composer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
      composer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
    ])
  }
  private func button(_ title: String, _ id: String, action: @escaping () -> Void) -> UIButton {
    let button = UIButton(configuration: .bordered())
    button.setTitle(title, for: .normal); button.accessibilityIdentifier = id
    button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    return button
  }
}
