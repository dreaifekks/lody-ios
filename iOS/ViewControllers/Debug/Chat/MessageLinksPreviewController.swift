import Litext
import LodyCore
import MarkdownParser
import MarkdownView
import UIKit

/// Resets on every entry. All effects end at injected catalog/navigation/URL boundaries.
@MainActor
final class MessageLinksPreviewController: SessionController {
  private let fixture: MessageLinksFixture
  private let probe = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
  private var timer: Timer?
  private lazy var closeFixtureItem: UIBarButtonItem = {
    let item = UIBarButtonItem(title: "Close fixture", primaryAction: UIAction { [weak self] _ in
      self?.navigationController?.presentingViewController?.dismiss(animated: true)
    })
    item.accessibilityIdentifier = "message-links-close"
    return item
  }()

  init(scenario: String) {
    let fixture = MessageLinksFixture(scenario: scenario)
    self.fixture = fixture
    let envelope = fixture.envelope
    var environment = SessionSendEnvironment.live
    environment.store = { _, _ in nil }
    environment.inflight = OutboxInflight()
    environment.serverCreated = { _ in true }
    environment.foreground = { _, _ in }
    environment.composer = .init(options: { _, _ in CreationOptions(sessionId: "origin", agents: [], capabilities: []) }, tier: { _, _ in nil })
    super.init(sessionId: "origin", source: fixture.source,
      feed: .init(watch: { _, receive in
        receive(SessionRuntimeEvent(generation: 1, state: "live", sessionId: "origin", session: envelope))
        return {}
      }, reconnect: { _ in }, cached: { _, _, _ in envelope }),
      environment: environment,
      messageLinks: .init(isLAN: { scenario != "cloud-localhost" },
        openSession: { id, _, controller in fixture.record("session", id, from: controller) },
        openURL: { url in fixture.record("url", url.absoluteString) },
        openFile: { id, path, line, controller in fixture.record("file", "\(id):\(path):\(line)", from: controller) },
        notice: { text, controller in fixture.record("notice", text, from: controller) }))
    chat.usesLAN = { scenario != "cloud-localhost" }
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  isolated deinit { timer?.invalidate() }
  override var persistsDraft: Bool { false }

  override func viewDidLoad() {
    super.viewDidLoad()
    probe.isAccessibilityElement = true
    probe.accessibilityIdentifier = "message-links-probe"
    timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.updateProbe() }
    }
    updateProbe()
  }

  private func updateProbe() {
    let host: UIViewController
    if let page = subagentPage, page.viewIfLoaded?.window != nil { host = page }
    else if let page = processPage, page.viewIfLoaded?.window != nil { host = page }
    else { host = self }
    if probe.superview !== host.view { host.view.addSubview(probe) }
    let header = LodyNavigationHeader.of((host.parent ?? host).navigationItem)
    if header.leftItems != [closeFixtureItem] { header.leftItems = [closeFixtureItem] }
    var targets: [[String: Any]] = []
    func walk(_ view: UIView) {
      guard !view.isHidden, view.alpha > 0 else { return }
      if let label = view as? TextLabelView, let window = label.window {
        let text = label.attributedText
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, range, _ in
          let href: String
          if let value = value as? String { href = value }
          else if let value = value as? URL { href = value.absoluteString }
          else { return }
          for box in label.textLayout.rects(for: range) {
            let rect = label.convert(label.viewRect(fromLayoutRect: box), to: window)
            guard window.bounds.contains(CGPoint(x: rect.midX, y: rect.midY)), rect.width > 0 else { continue }
            targets.append(["href": href, "x": rect.midX, "y": rect.midY])
          }
        }
      }
      for child in view.subviews { walk(child) }
    }
    walk(host.view)
    let theme = ChatMarkdownTheme.make(traits: traitCollection, secondary: false)
    let content = FileMarkdownView.content(MarkdownContent(markdown: fixture.body, theme: theme), linkify: true)
    func links(_ blocks: [MarkdownBlockNode]) -> [String] {
      blocks.flatMap { block -> [String] in
        let nodes: [MarkdownInlineNode]
        switch block {
        case .paragraph(let value), .heading(_, let value): nodes = value
        case .table(_, let rows): nodes = rows.flatMap { $0.cells.flatMap(\.content) }
        default: return links(block.children)
        }
        return nodes.collect { node -> [String] in
          if case .link(let href, _) = node { return [href] }
          return []
        }
      }
    }
    let payload: [String: Any] = ["events": fixture.events, "targets": targets,
      "parsedLinks": links(content.blocks), "scenario": fixture.scenario, "host": MessageLinksFixture.hostName(host)]
    probe.accessibilityValue = String(decoding: try! JSONSerialization.data(withJSONObject: payload, options: .sortedKeys), as: UTF8.self)
  }
}

@MainActor
private final class MessageLinksFixture {
  let body: String
  let scenario: String
  private(set) var events: [[String: String]] = []
  var source: SessionSource { SessionSource(changes: [], read: { self.state }, write: { _, _, _ in }) }

  init(scenario: String) {
    self.scenario = scenario
    let samples: [String: String] = [
      "session": "lody://session/target?workspace=links_ws",
      "legacy": "session://target",
      "streaming": "session://target",
      "tab": "[Legacy tab](lody://session/base?workspace=links_ws&tab=tab)",
      "missing-tab": "[Missing tab](lody://session/base?tab=missing)",
      "workspace": "[Other workspace](lody://session/target?workspace=other)",
      "missing": "[Missing session](session://missing)",
      "file": "src/link.swift:12",
      "unicode": "See notes/準備.md。",
      "inline-code": "`src/code.swift`",
      "code-fence": "```text\nsession://target\nsrc/code.swift\n```",
      "explicit-code": "[`Code label`](src/explicit.swift:3)",
      "localhost": "[Local server](http://localhost:5173/a%20b?x=1&y=2#frag)",
      "ipv4": "[Local server](http://127.0.0.1:5173/a%20b?x=1&y=2#frag)",
      "zero": "[Local server](http://0.0.0.0:5173/a%20b?x=1&y=2#frag)",
      "ipv6": "[Local server](http://[::1]:5173/a%20b?x=1&y=2#frag)",
      "nohost": "[Local server](http://localhost:5173/)",
      "cloud-localhost": "[Local server](http://localhost:5173/)",
      "http": "[System link](http://example.invalid/path?q=1#frag)",
      "https": "[System link](https://example.invalid/path?q=1#frag)",
      "file-url": "[System link](file:///tmp/report%20one.md#L12)",
      "tg": "[System link](tg://resolve?domain=lody)",
      "mailto": "[System link](mailto:reader@example.invalid)",
      "tel": "[System link](tel:+15550100)",
      "process": "session://target",
      "process-file": "src/child.swift:4",
      "process-code": "`src/code.swift`",
      "subagent": "session://target",
      "subagent-file": "src/child.swift:4",
      "subagent-code": "`session://target`",
      "process-url": "[Local server](http://localhost:5173/a%20b?x=1&y=2#frag)",
      "subagent-url": "[System link](file:///tmp/report%20one.md#L12)",
    ]
    body = samples[scenario]!
  }

  var state: SessionListState {
    SessionListState(userId: "links-user", workspaceId: "links_ws", catalog: SessionCatalog(
      sessions: [SessionItem(id: "origin", title: "Message links", machineId: scenario == "nohost" ? "missing-machine" : "machine-b"),
        SessionItem(id: "target", title: "Target"), SessionItem(id: "base", title: "Base"), SessionItem(id: "tab", title: "Tab"),
        SessionItem(id: "different-id", title: "missing")],
      machineTerminals: ["machine-a": .init(host: "192.0.2.10", port: 9000), "machine-b": .init(host: "192.0.2.42", port: 9000)]))
  }

  var envelope: String {
    var items: [[String: Any]] = [["itemId": "body", "type": "text", "text": body]]
    if scenario.hasPrefix("process") {
      items = [["itemId": "thought", "type": "thought", "text": body], ["itemId": "body", "type": "text", "text": "Open the process row."]]
    }
    if scenario.hasPrefix("subagent") {
      items = [["itemId": "task", "type": "subagent_task", "taskId": "fixture-task", "actor": "Fixture agent",
        "description": "Linked task", "status": "completed", "summary": body], ["itemId": "body", "type": "text", "text": "Open the task row."]]
    }
    return SessionController.json(["v": 1, "status": "live", "revision": 1, "entries": [
      ["id": "links", "role": "assistant", "status": scenario == "streaming" ? "in_progress" : "completed", "finished": scenario != "streaming", "items": items]]])
  }

  static func hostName(_ controller: UIViewController) -> String {
    if controller is ProcessController { return "process" }
    if controller is SubagentTaskController { return "subagent" }
    return "session"
  }

  func record(_ kind: String, _ target: String, from controller: UIViewController? = nil) {
    events.append(["kind": kind, "target": target, "host": controller.map { Self.hostName($0) } ?? "system"])
  }
}
