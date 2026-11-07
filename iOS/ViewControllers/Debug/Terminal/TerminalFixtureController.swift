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
    let page = TerminalFixturePage(sessionId: "fixture", authorized: { fixture.authorized }) { ownership, event, closed in
      guard ownership.configure(machineId: "fixture-member", cleanup: { id, completion in
        fixture.cleanups += 1
        fixture.close(id)
        completion(true)
      }) else { return nil }
      return TerminalFixtureChannel(fixture: fixture, scenario: scenario, ownership: ownership, event: event, closed: closed)
    }
    page.disconnect = { fixture.forceDisconnect?() }
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
  var disconnect: (@MainActor () -> Void)?
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    let expire = UIBarButtonItem(title: "Expire account", primaryAction: UIAction { [weak self] _ in self?.expire?() })
    expire.accessibilityIdentifier = "terminal-fixture-expire"
    let disconnect = UIBarButtonItem(title: "Disconnect", primaryAction: UIAction { [weak self] _ in self?.disconnect?() })
    disconnect.accessibilityIdentifier = "terminal-fixture-disconnect"
    parent?.navigationItem.rightBarButtonItems = [expire, disconnect]
  }
}

@MainActor
private final class TerminalFixture {
  var authorized = true
  var rejectedBeforeSend = false
  var terminals: [String: String] = [:]
  var active: Int { terminals.count }
  var cleanups = 0
  var forceDisconnect: (@MainActor () -> Void)?
  var opens = 0
  var closes = 0
  var inputs = 0
  var resizes = 0
  var releaseOpen: (@MainActor () -> Void)?
  var changed: (@MainActor () -> Void)?
  var summary: String { "active:\(active),opens:\(opens),closes:\(closes),inputs:\(inputs),resizes:\(resizes),cleanups:\(cleanups)" }
  func update() { changed?() }
  func close(_ id: String) {
    if terminals.removeValue(forKey: id) != nil { closes += 1 }
    update()
  }
}

@MainActor
private final class TerminalFixtureChannel: TerminalChannel {
  private let fixture: TerminalFixture
  private let scenario: String
  private let ownership: TerminalShellOwnership
  private let event: @MainActor (LanTerminalEvent) -> Void
  private let closed: @MainActor (LanTerminalLink.Failure) -> Void
  private var stopped = false
  private var disconnected = false
  private var ownedId: String?
  private var admitted = Set<String>()
  private var line = ""
  init(fixture: TerminalFixture, scenario: String, ownership: TerminalShellOwnership,
       event: @escaping @MainActor (LanTerminalEvent) -> Void,
       closed: @escaping @MainActor (LanTerminalLink.Failure) -> Void) {
    self.fixture = fixture; self.scenario = scenario; self.ownership = ownership
    self.event = event; self.closed = closed
    fixture.forceDisconnect = { [weak self] in
      guard let self, !self.disconnected else { return }
      self.disconnected = true // Server unsubscribes, retaining its PTY.
      self.closed(.unreachable("Offline fixture connection lost"))
    }
  }
  func start(_ completion: @escaping @MainActor (Result<Void, LanTerminalLink.Failure>) -> Void) {
    if scenario == "failure", fixture.opens == 0 {
      fixture.opens += 1
      completion(.failure(.unreachable("Offline fixture refusal")))
    } else { completion(.success(())) }
  }
  func request(_ command: LanTerminalCommand, _ completion: @escaping @MainActor (Result<LanTerminalEvent, LanTerminalLink.Failure>) -> Void) {
    guard !stopped, !disconnected else { completion(.failure(.notSent("Offline link already stopped"))); return }
    switch command.type {
    case "list":
      let terminals = fixture.terminals.map { LanTerminalSnapshot(terminalId: $0.key, title: $0.value) }
        + [LanTerminalSnapshot(terminalId: "desktop-owned", title: "Do not close")]
      admitted.formUnion(terminals.map(\.terminalId))
      completion(.success(.terminals(requestId: nil, sessionId: "fixture", terminals: terminals)))
    case "open":
      if scenario == "not-sent", !fixture.rejectedBeforeSend {
        fixture.rejectedBeforeSend = true
        disconnected = true
        // Force onClose to invalidate the view generation before the local
        // rejection callback. No shell and no command bytes exist yet.
        closed(.unreachable("Offline local queue rejected open"))
        completion(.failure(.notSent("Offline open was never submitted")))
        return
      }
      let open: @MainActor @Sendable () -> Void = { [self] in
        fixture.releaseOpen = nil
        fixture.opens += 1
        let id = "fixture-\(fixture.opens)"
        ownedId = id
        admitted.insert(id)
        fixture.terminals[id] = "offline shell"
        ownership.record(id)
        if stopped || disconnected {
          fixture.close(id); ownership.confirmExit(id); return
        }
        fixture.update()
        completion(.success(.opened(requestId: nil, terminalId: id, cwd: "/offline")))
      }
      if scenario == "unknown-open" {
        fixture.releaseOpen = open
        completion(.failure(.timedOut))
      } else if scenario == "late-open" { fixture.releaseOpen = open }
      else { open() }
    case "attach":
      guard let id = command.terminalId, fixture.terminals[id] != nil else {
        completion(.failure(.refused(code: "terminal_not_found", message: "Missing fixture shell"))); return
      }
      admitted.insert(id)
      event(.data(requestId: nil, terminalId: id, data: "Lody LAN terminal \(id) \u{E0B0} \u{F07C} \u{E725}\r\n$ ", replay: true))
      completion(.success(.title(requestId: nil, terminalId: id, title: "offline shell")))
    default: completion(.failure(.closed("Unexpected fixture command")))
    }
  }
  func adopt(terminalId: String) { ownedId = terminalId }
  func send(_ command: LanTerminalCommand) {
    guard !stopped, !disconnected, let id = ownedId, admitted.contains(id) else { return }
    if command.type == "resize" { fixture.resizes += 1; fixture.update(); return }
    guard let text = command.data else { return }
    fixture.inputs += 1; fixture.update()
    for character in text {
      if character == "\r" || character == "\n" {
        if line == "exit" {
          fixture.close(id); ownership.confirmExit(id)
          event(.exit(requestId: nil, terminalId: id, exitCode: 0, signal: nil)); return
        }
        event(.data(requestId: nil, terminalId: id, data: "\r\n\(line)\r\n$ ", replay: false)); line = ""
      } else if character == "\u{7f}" {
        if !line.isEmpty { line.removeLast(); event(.data(requestId: nil, terminalId: id, data: "\u{8} \u{8}", replay: false)) }
      } else {
        line.append(character); event(.data(requestId: nil, terminalId: id, data: String(character), replay: false))
      }
    }
  }
  func disconnect() { disconnected = true }
  func stop() {
    guard !stopped else { return }
    stopped = true
    if disconnected { ownership.cleanupKnown() }
    else if let id = ownedId, admitted.contains(id) { fixture.close(id); ownership.confirmExit(id) }
    else { ownership.cleanupKnown() }
  }
}
