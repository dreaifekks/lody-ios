import LodyCore
import UIKit

@MainActor
final class AnswerFoldingPreviewController: SessionController {
  private let fixture: AnswerFoldingFixture
  private let probe = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
  private var timer: Timer?
  private lazy var finishItem: UIBarButtonItem = {
    let item = UIBarButtonItem(title: "Finish turn", primaryAction: UIAction { [weak self] _ in self?.fixture.finish() })
    item.accessibilityIdentifier = "answer-folding-finish"
    return item
  }()
  private lazy var closeItem: UIBarButtonItem = {
    let item = UIBarButtonItem(title: "Close fixture", primaryAction: UIAction { [weak self] _ in
      self?.navigationController?.presentingViewController?.dismiss(animated: true)
    })
    item.accessibilityIdentifier = "answer-folding-close"
    return item
  }()

  init(scenario: String) {
    let fixture = AnswerFoldingFixture(scenario: scenario)
    self.fixture = fixture
    let envelope = fixture.envelope
    var environment = SessionSendEnvironment.live
    environment.store = { _, _ in nil }; environment.inflight = OutboxInflight()
    environment.serverCreated = { _ in true }; environment.foreground = { _, _ in }
    environment.composer = .init(options: { _, _ in .init(sessionId: "fold-session", agents: [], capabilities: []) }, tier: { _, _ in nil })
    super.init(sessionId: "fold-session", source: .init(changes: [], read: { fixture.state }, write: { _, _, _ in }),
      feed: .init(watch: { _, receive in fixture.feed = receive; fixture.publish(); return { fixture.feed = nil } },
        reconnect: { _ in }, cached: { _, _, _ in envelope }), environment: environment)
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  isolated deinit { timer?.invalidate() }
  override var persistsDraft: Bool { false }

  override func viewDidLoad() {
    super.viewDidLoad()
    probe.isAccessibilityElement = true; probe.accessibilityIdentifier = "answer-folding-probe"
    timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.updateProbe() }
    }
    updateProbe()
  }

  private func updateProbe() {
    let host: UIViewController
    if let page = processPage, page.viewIfLoaded?.window != nil { host = page }
    else { host = self }
    if probe.superview !== host.view { host.view.addSubview(probe) }
    let header = LodyNavigationHeader.of((host.parent ?? host).navigationItem)
    if header.rightItems != [finishItem] { header.rightItems = [finishItem] }
    if header.leftItems != [closeItem] { header.leftItems = [closeItem] }
    finishItem.isEnabled = !fixture.finished
    let ids = chat.dataSource.snapshot().itemIdentifiers.compactMap { id -> String? in
      guard let row = chat.rows[id], row.kind == "text" else { return nil }
      return row.itemID
    }
    var processIDs: [String] = []
    if host is ProcessController {
      let content = host.view.subviews.compactMap { $0 as? LodyChatView }.first!
      processIDs = content.dataSource.snapshot().itemIdentifiers.compactMap { content.rows[$0]?.itemID }
    }
    probe.accessibilityValue = Self.json(["scenario": fixture.scenario, "finished": fixture.finished,
      "mainTextIDs": ids, "processItemIDs": processIDs, "host": host === self ? "session" : "process"])
  }
}

@MainActor
private final class AnswerFoldingFixture {
  let scenario: String
  private(set) var finished = false
  var feed: (@MainActor (SessionRuntimeEvent) -> Void)?
  private var revision = 1
  init(scenario: String) { self.scenario = scenario }
  var state: SessionListState {
    .init(userId: "offline-fold-user", workspaceId: "offline-fold", catalog: .init(sessions: [.init(id: "fold-session", title: "Answer folding")]))
  }
  var envelope: String {
    func text(_ id: String, _ value: String) -> [String: Any] { ["itemId": id, "type": "text", "text": value] }
    func work(_ id: String) -> [String: Any] { ["itemId": id, "type": "tool_call", "title": "Check " + id, "status": "completed"] }
    var items = [text("narration", "I will inspect the files."), work("read"), text("earlier", "# Earlier report"), work("verify"),
      text("bridge", "Checking one more result."), work("poll"), text("answer1", "Primary answer."), text("answer2", "Details remain visible."),
      work("finish"), text("closing", scenario == "structured" ? "1. All checks passed." : "Background work also finished.")]
    if scenario == "tail-work" { items.append(work("cleanup")) }
    return SessionController.json(["v": 1, "status": "live", "revision": revision, "entries": [
      ["id": "fold", "role": "assistant", "status": finished ? "completed" : "running", "finished": finished, "items": items]]])
  }
  func finish() { finished = true; revision += 1; publish() }
  func publish() { feed?(.init(generation: 1, state: "live", sessionId: "fold-session", session: envelope)) }
}
