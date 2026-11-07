import LodyData
import UIKit

/// Credential-free terminal scene using the production page and SwiftTerm view.
@MainActor
final class TerminalFixtureController: UIViewController {
  private let fixture = TerminalFixture()
  private let probe = UILabel()
  private let scenario: String
  init(scenario: String = "ready") { self.scenario = scenario; super.init(nibName: nil, bundle: nil) }
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    let open = button("Open terminal", id: "terminal-fixture-open") { [weak self] in self?.open() }
    let release = button("Release delayed open", id: "terminal-fixture-release") { [weak self] in self?.fixture.releaseOpen?() }
    probe.accessibilityIdentifier = "terminal-fixture-probe"
    probe.numberOfLines = 0
    probe.font = .preferredFont(forTextStyle: .body)
    let stack = UIStackView(arrangedSubviews: [open, release, probe])
    stack.axis = .vertical; stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
    ])
    fixture.changed = { [weak self] in self?.probe.text = self?.fixture.summary }
    probe.text = fixture.summary
  }
  private func button(_ title: String, id: String, action: @escaping @MainActor () -> Void) -> UIButton {
    let button = UIButton(configuration: .tinted())
    button.configuration?.title = title; button.accessibilityIdentifier = id
    button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    button.addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
    return button
  }
  private func open() {
    fixture.authorized = true
    let fixture = self.fixture
    let scenario = self.scenario
    let page = TerminalFixturePage(sessionId: "fixture", authorized: { fixture.authorized }) { event, closed in
      TerminalFixtureChannel(fixture: fixture, scenario: scenario, event: event, closed: closed)
    }
    page.expire = {
      fixture.authorized = false
      NotificationCenter.default.post(name: .lodyAuthDidChange, object: nil)
    }
    LodyShell.shared.push(page, title: "Terminal fixture", from: self)
  }
}

@MainActor
private final class TerminalFixturePage: TerminalController {
  var expire: (@MainActor () -> Void)?
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    let expire = UIBarButtonItem(title: "Expire account", primaryAction: UIAction { [weak self] _ in self?.expire?() })
    expire.accessibilityIdentifier = "terminal-fixture-expire"
    parent?.navigationItem.rightBarButtonItem = expire
  }
}

@MainActor
private final class TerminalFixture {
  var authorized = true
  var active = 0
  var opens = 0
  var closes = 0
  var inputs = 0
  var resizes = 0
  var releaseOpen: (@MainActor () -> Void)?
  var changed: (@MainActor () -> Void)?
  var summary: String { "active:\(active),opens:\(opens),closes:\(closes),inputs:\(inputs),resizes:\(resizes)" }
  func update() { changed?() }
}

@MainActor
private final class TerminalFixtureChannel: TerminalChannel {
  private let fixture: TerminalFixture
  private let scenario: String
  private let event: @MainActor (LanTerminalEvent) -> Void
  private let closed: @MainActor (LanTerminalLink.Failure) -> Void
  private var stopped = false
  private var owned = false
  private var line = ""
  init(fixture: TerminalFixture, scenario: String, event: @escaping @MainActor (LanTerminalEvent) -> Void,
       closed: @escaping @MainActor (LanTerminalLink.Failure) -> Void) {
    self.fixture = fixture; self.scenario = scenario; self.event = event; self.closed = closed
  }
  func start(_ completion: @escaping @MainActor (Result<Void, LanTerminalLink.Failure>) -> Void) {
    if scenario == "failure", fixture.opens == 0 {
      fixture.opens += 1
      completion(.failure(.unreachable("Offline fixture refusal")))
    } else { completion(.success(())) }
  }
  func request(_ command: LanTerminalCommand, _ completion: @escaping @MainActor (Result<LanTerminalEvent, LanTerminalLink.Failure>) -> Void) {
    guard !stopped else { return }
    switch command.type {
    case "list": completion(.success(.terminals(requestId: nil, sessionId: "fixture", terminals: [])))
    case "open":
      let open: @MainActor @Sendable () -> Void = { [self] in
        fixture.releaseOpen = nil
        fixture.opens += 1
        // Emulate a late server answer; cleanup still belongs to the transport.
        if stopped { fixture.closes += 1; fixture.update(); return }
        owned = true; fixture.active += 1; fixture.update()
        completion(.success(.opened(requestId: nil, terminalId: "fixture", cwd: "/offline")))
      }
      if scenario == "late-open" { fixture.releaseOpen = open } else { open() }
    case "attach":
      event(.data(requestId: nil, terminalId: "fixture", data: "Lody LAN terminal \u{E0B0} \u{F07C} \u{E725}\r\n$ ", replay: true))
      completion(.success(.title(requestId: nil, terminalId: "fixture", title: "offline shell")))
    default: completion(.failure(.closed("Unexpected fixture command")))
    }
  }
  func send(_ command: LanTerminalCommand) {
    guard !stopped else { return }
    if command.type == "resize" { fixture.resizes += 1; fixture.update(); return }
    guard let text = command.data else { return }
    fixture.inputs += 1; fixture.update()
    for character in text {
      if character == "\r" || character == "\n" {
        if line == "exit" {
          stop(); event(.exit(requestId: nil, terminalId: "fixture", exitCode: 0, signal: nil)); return
        }
        event(.data(requestId: nil, terminalId: "fixture", data: "\r\n\(line)\r\n$ ", replay: false)); line = ""
      } else if character == "\u{7f}" {
        if !line.isEmpty { line.removeLast(); event(.data(requestId: nil, terminalId: "fixture", data: "\u{8} \u{8}", replay: false)) }
      } else {
        line.append(character); event(.data(requestId: nil, terminalId: "fixture", data: String(character), replay: false))
      }
    }
  }
  func stop() {
    guard !stopped else { return }
    stopped = true
    if owned { owned = false; fixture.active -= 1; fixture.closes += 1 }
    fixture.update()
  }
}
