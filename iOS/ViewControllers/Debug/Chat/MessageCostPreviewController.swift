import LodyCore
import UIKit

@MainActor
final class MessageCostPreviewController: SessionController {
  private let fixture: MessageCostFixture
  private let probe = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
  private var timer: Timer?
  private lazy var advanceItem: UIBarButtonItem = {
    let item = UIBarButtonItem(title: "Advance usage", primaryAction: UIAction { [weak self] _ in self?.fixture.advance() })
    item.accessibilityIdentifier = "message-cost-advance"
    return item
  }()
  private lazy var closeItem: UIBarButtonItem = {
    let item = UIBarButtonItem(title: "Close fixture", primaryAction: UIAction { [weak self] _ in
      self?.navigationController?.presentingViewController?.dismiss(animated: true)
    })
    item.accessibilityIdentifier = "message-cost-close"
    return item
  }()

  init(scenario: String) {
    let fixture = MessageCostFixture(scenario: scenario)
    self.fixture = fixture
    let envelope = fixture.envelope
    var environment = SessionSendEnvironment.live
    environment.store = { _, _ in nil }; environment.inflight = OutboxInflight()
    environment.serverCreated = { _ in true }; environment.foreground = { _, _ in }
    environment.composer = .init(options: { _, _ in .init(sessionId: "cost-session", agents: [], capabilities: []) }, tier: { _, _ in nil })
    super.init(sessionId: "cost-session", source: .init(changes: [], read: { fixture.state }, write: { _, _, _ in }),
      feed: .init(watch: { _, receive in fixture.feed = receive; fixture.publish(); return { fixture.feed = nil } },
        reconnect: { _ in }, cached: { _, _, _ in envelope }), environment: environment)
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  isolated deinit { timer?.invalidate() }
  override var persistsDraft: Bool { false }

  override func viewDidLoad() {
    super.viewDidLoad()
    probe.isAccessibilityElement = true; probe.accessibilityIdentifier = "message-cost-probe"
    timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.updateProbe() }
    }
    updateProbe()
  }
  private func updateProbe() {
    let host: UIViewController
    let details = chat.messageDetailsPage
    if let page = details, page.viewIfLoaded?.window != nil { host = page }
    else { host = self }
    if probe.superview !== host.view { host.view.addSubview(probe) }
    let header = LodyNavigationHeader.of((host.parent ?? host).navigationItem)
    let left = host === self ? closeItem : advanceItem
    if header.leftItems != [left] { header.leftItems = [left] }
    advanceItem.isEnabled = fixture.scenario == "late" && fixture.step < 3
    probe.accessibilityValue = Self.json(["scenario": fixture.scenario, "step": fixture.step,
      "host": host === self ? "session" : "details"])
  }
}

@MainActor
private final class MessageCostFixture {
  let scenario: String
  private(set) var step = 0
  var feed: (@MainActor (SessionRuntimeEvent) -> Void)?
  init(scenario: String) { self.scenario = scenario }
  var state: SessionListState {
    .init(userId: "offline-cost-user", workspaceId: "offline-cost", catalog: .init(sessions: [.init(id: "cost-session", title: "Message cost")]))
  }
  var envelope: String {
    var usage: [String: Any] = ["inputTokens": 12, "outputTokens": 3, "reasoningOutputTokens": 0,
      "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0]
    let costs: [String: Any] = ["tiny": 0.00000001, "zero": 0, "fraction": 0.123456, "normal": 12.3456,
      "null": NSNull(), "invalid": -1]
    if scenario == "late" {
      if step == 1 { usage["costUSD"] = 0.00000001 }
      if step == 2 { usage["costUSD"] = 0 }
    } else { usage["costUSD"] = costs[scenario] }
    return SessionController.json(["v": 1, "status": "live", "revision": step + 1, "entries": [
      ["id": "cost-turn", "role": "assistant", "status": "completed", "finished": true, "tokenUsage": usage,
       "items": [["itemId": "answer", "type": "text", "text": "Recorded provider usage."]]]]])
  }
  func advance() { step += 1; publish() }
  func publish() { feed?(.init(generation: 1, state: "live", sessionId: "cost-session", session: envelope)) }
}
