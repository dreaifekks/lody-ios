import LodyCore
import UIKit

@MainActor
final class ContinueMarkerPreviewController: SessionController {
  private let fixture: ContinueMarkerFixture
  private let probe = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
  private var timer: Timer?
  private lazy var advanceItem: UIBarButtonItem = {
    let item = UIBarButtonItem(title: "Resolve fixture", primaryAction: UIAction { [weak self] _ in self?.fixture.advance() })
    item.accessibilityIdentifier = "continue-marker-advance"
    return item
  }()
  private lazy var closeItem: UIBarButtonItem = {
    let item = UIBarButtonItem(title: "Close fixture", primaryAction: UIAction { [weak self] _ in
      self?.navigationController?.presentingViewController?.dismiss(animated: true)
    })
    item.accessibilityIdentifier = "continue-marker-close"
    return item
  }()

  init(scenario: String) {
    let fixture = ContinueMarkerFixture(scenario: scenario)
    self.fixture = fixture
    let envelope = fixture.envelope
    var environment = SessionSendEnvironment.live
    environment.store = { _, _ in nil }; environment.inflight = OutboxInflight()
    environment.serverCreated = { _ in true }; environment.foreground = { _, _ in }
    environment.composer = .init(options: { _, _ in .init(sessionId: "continue-session", agents: [], capabilities: []) }, tier: { _, _ in nil })
    environment.turn = { _ in fixture.sends += 1; return #"{"state":"not_sent"}"# }
    super.init(sessionId: "continue-session", source: .init(changes: [], read: { fixture.state }, write: { _, _, _ in }),
      feed: .init(watch: { _, receive in fixture.feed = receive; fixture.publish(); return { fixture.feed = nil } },
        reconnect: { _ in }, cached: { _, _, _ in envelope }), environment: environment)
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  isolated deinit { timer?.invalidate() }
  override var persistsDraft: Bool { false }

  override func viewDidLoad() {
    super.viewDidLoad()
    probe.isAccessibilityElement = true; probe.accessibilityIdentifier = "continue-marker-probe"
    timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.updateProbe() }
    }
    updateProbe()
  }
  private func updateProbe() {
    if probe.superview == nil { view.addSubview(probe) }
    let header = LodyNavigationHeader.of(navigationItem)
    if header.rightItems != [advanceItem] { header.rightItems = [advanceItem] }
    if header.leftItems != [closeItem] { header.leftItems = [closeItem] }
    advanceItem.isEnabled = !fixture.advanced
    let rows = chat.dataSource.snapshot().itemIdentifiers.compactMap { id -> [String: String]? in
      guard let row = chat.rows[id] else { return nil }
      return ["id": row.id, "kind": row.kind, "symbol": row.symbol]
    }
    probe.accessibilityValue = Self.json(["scenario": fixture.scenario, "advanced": fixture.advanced, "rows": rows, "sends": fixture.sends])
  }
}

@MainActor
private final class ContinueMarkerFixture {
  let scenario: String
  private(set) var advanced = false
  var sends = 0
  var feed: (@MainActor (SessionRuntimeEvent) -> Void)?
  init(scenario: String) { self.scenario = scenario }
  var state: SessionListState {
    .init(userId: "offline-continue-user", workspaceId: "offline-continue", catalog: .init(sessions: [.init(id: "continue-session", title: "Continue marker")]))
  }
  var envelope: String {
    var entry: [String: Any] = ["id": "continue", "role": "user", "status": "handled", "finished": true,
      "deliveryKind": "continue", "items": [["itemId": "prompt", "type": "text", "text": SessionDecision.interruptedContinuation]]]
    if !advanced {
      if ["transition", "unknown"].contains(scenario) { entry["status"] = "delivery_unknown" }
      if scenario == "queued" { entry["status"] = "queued" }
      if scenario.hasPrefix("delivery-") { entry["delivery"] = String(scenario.dropFirst("delivery-".count)) }
      if scenario == "ordinary" { entry.removeValue(forKey: "deliveryKind") }
    } else if scenario == "queued" { entry["status"] = "delivery_unknown" }
    if scenario == "restart" {
      entry = ["id": "restart", "role": "assistant", "status": "failed", "finished": true, "items": [
        ["itemId": "error", "type": "system_notice", "name": "chat_failed", "meta": ["reason": "daemon_restart"]]]]
    }
    return SessionController.json(["v": 1, "status": "live", "revision": advanced ? 2 : 1, "entries": [entry]])
  }
  func advance() { advanced = true; publish() }
  func publish() { feed?(.init(generation: 1, state: "live", sessionId: "continue-session", session: envelope)) }
}
