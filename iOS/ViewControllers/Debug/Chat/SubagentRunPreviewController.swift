import LodyCore
import UIKit

@MainActor
final class SubagentRunPreviewController: SessionController {
  private let fixture: SubagentRunFixture
  private let probe = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
  private var timer: Timer?
  private lazy var advanceItem: UIBarButtonItem = {
    let item = UIBarButtonItem(title: "Update run", primaryAction: UIAction { [weak self] _ in self?.fixture.advance() })
    item.accessibilityIdentifier = "subagent-run-update"
    return item
  }()

  init() {
    let fixture = SubagentRunFixture()
    self.fixture = fixture
    let envelope = fixture.envelope
    var environment = SessionSendEnvironment.live
    environment.store = { _, _ in nil }; environment.inflight = OutboxInflight()
    environment.serverCreated = { _ in true }; environment.foreground = { _, _ in }
    environment.composer = .init(options: { _, _ in .init(sessionId: "run-session", agents: [], capabilities: []) }, tier: { _, _ in nil })
    super.init(sessionId: "run-session", source: .init(changes: [], read: { fixture.state }, write: { _, _, _ in }),
      feed: .init(watch: { _, receive in fixture.feed = receive; fixture.publish(); return { fixture.feed = nil } },
        reconnect: { _ in }, cached: { _, _, _ in envelope }), environment: environment, itemDetail: fixture.service)
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  isolated deinit { timer?.invalidate() }
  override var persistsDraft: Bool { false }

  override func viewDidLoad() {
    super.viewDidLoad()
    probe.isAccessibilityElement = true; probe.accessibilityIdentifier = "subagent-run-probe"
    timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.updateProbe() }
    }
    updateProbe()
  }

  private func updateProbe() {
    let host: UIViewController
    if let page = subagentPage, page.viewIfLoaded?.window != nil { host = page }
    else { host = self }
    if probe.superview !== host.view { host.view.addSubview(probe) }
    let header = LodyNavigationHeader.of((host.parent ?? host).navigationItem)
    let items = header.rightItems ?? []
    if !items.contains(where: { $0 === advanceItem }) { header.rightItems = items + [advanceItem] }
    probe.accessibilityValue = Self.json(["reads": fixture.reads, "details": fixture.details,
      "observers": fixture.observers.count, "revision": fixture.revision, "host": host === self ? "session" : "run"])
  }
}

@MainActor
private final class SubagentRunFixture {
  static let first = #"["task-run","first"]"#
  static let tool = #"["task-run","old-tool"]"#
  static let tail = #"["task-run","last"]"#
  var revision = 1
  var reads = 0
  var details: [String] = []
  var feed: (@MainActor (SessionRuntimeEvent) -> Void)?
  var observers: [UUID: @MainActor (Int, String?) -> Void] = [:]
  private let time = Date().timeIntervalSince1970 * 1000

  var state: SessionListState {
    .init(userId: "offline-run-user", workspaceId: "offline-run", catalog: .init(sessions: [.init(id: "run-session", title: "Subagent run")]))
  }
  var steps: [[String: Any]] {
    [["itemId": Self.first, "type": "text", "text": "Earlier full report revision \(revision)."],
     ["itemId": Self.tool, "type": "tool_call", "kind": "execute", "title": "Inspect old source", "status": "completed", "hasDetail": true],
     ["itemId": Self.tail, "type": "text", "text": "Latest step revision \(revision)."]]
  }
  var fullRun: [String: Any] {
    ["state": revision == 1 ? "running" : "completed", "items": steps,
     "modelId": "Model-X", "totalTokens": 1200, "toolCallCount": 1, "contextUsagePercent": 37, "outputIncomplete": revision == 1]
  }
  var envelope: String {
    var run = fullRun; run["items"] = [steps.last!]; run["itemCount"] = steps.count
    return SessionController.json(["v": 1, "status": "live", "revision": revision, "entries": [
      ["id": "run-parent", "role": "assistant", "status": "completed", "finished": true, "startedAt": time - 8000, "endedAt": time - 2000,
       "items": [["itemId": "work", "type": "tool_call", "title": "Parent work", "status": "completed"],
         ["itemId": "task-run", "rev": revision, "type": "subagent_task", "status": "completed", "actor": "Explore", "description": "Inspect run", "summary": "Latest step revision \(revision).", "run": run],
         ["itemId": "task-done", "rev": 1, "type": "subagent_task", "status": "in_progress", "actor": "Review", "description": "Review done", "summary": "Review complete", "run": ["state": "completed", "items": []]],
         ["itemId": "answer", "type": "text", "text": "Parent answer remains readable."]]]]])
  }
  var service: ItemDetailService {
    .init(load: { [self] params in
      if params.run == true {
        reads += 1
        let value = try JSONDecoder().decode(RuntimeContract.JSONValue.self, from: JSONSerialization.data(withJSONObject: fullRun))
        let rev = revision
        try await Task.sleep(for: .milliseconds(300))
        return .init(itemId: params.itemId, rev: rev, blocks: [], run: .init(value: value), truncated: false)
      }
      details.append(params.itemId)
      return .init(itemId: params.itemId, rev: revision, blocks: [.object([
        "type": .string("terminal_output"), "output": .string("Historical tool detail: " + params.itemId),
      ])], truncated: false)
    }, observe: { [self] receive in
      let id = UUID(); observers[id] = receive
      return { [weak self] in self?.observers[id] = nil }
    })
  }
  func advance() { revision += 1; publish() }
  func publish() {
    let json = envelope
    feed?(.init(generation: 1, state: "live", sessionId: "run-session", session: json))
    for receive in Array(observers.values) { receive(1, json) }
  }
}
