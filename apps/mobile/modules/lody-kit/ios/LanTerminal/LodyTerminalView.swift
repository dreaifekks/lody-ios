import CoreText
import ExpoModulesCore
import SwiftTerm
import UIKit

/// An interactive shell on a LAN member, in the working directory of one
/// session. The LAN credential stays in Keychain: RN only names the machine,
/// its published endpoint and the session. Leaving the page ends the shell.
final class LodyTerminalView: ExpoView {
  private struct Source: Decodable, Equatable {
    let workspaceId: String
    let machineId: String
    let sessionId: String
    let host: String
    let port: Int
    /// Debug scenes echo locally instead of reaching a machine.
    var fixture: Bool?
  }

  private enum State: String {
    case connecting, ready, exited, failed
  }

  let onState = EventDispatcher()

  private let terminal = TerminalView(frame: .zero)
  private let status = UILabel()
  private let reconnect = UIButton(configuration: .tinted())
  private var source: Source?
  private var link: LanTerminalLink?
  private var terminalId: String?
  /// Callbacks of a replaced link are ignored.
  private var generation = 0
  private var fixtureLine = ""
  private var accessibilityPending = false

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    backgroundColor = .systemBackground
    terminal.translatesAutoresizingMaskIntoConstraints = false
    terminal.terminalDelegate = self
    terminal.accessibilityIdentifier = "terminal-view"
    terminal.isAccessibilityElement = true
    terminal.accessibilityLabel = LodyStrings.text("native.terminal.accessibility")
    Self.applyFont(to: terminal, size: traitCollection.userInterfaceIdiom == .pad ? 14 : 12)
    addSubview(terminal)
    keyboardLayoutGuide.followsUndockedKeyboard = true
    NSLayoutConstraint.activate([
      terminal.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
      terminal.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 4),
      terminal.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -4),
      terminal.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
    ])
    applyColors()
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: LodyTerminalView, _) in view.applyColors() }

    status.font = .preferredFont(forTextStyle: .subheadline)
    status.adjustsFontForContentSizeCategory = true
    status.textColor = .secondaryLabel
    status.textAlignment = .center
    status.numberOfLines = 0
    status.accessibilityIdentifier = "terminal-status"
    reconnect.configuration?.title = LodyStrings.text("native.terminal.reconnect")
    reconnect.accessibilityIdentifier = "terminal-reconnect"
    reconnect.addAction(UIAction { [weak self] _ in self?.connect() }, for: .primaryActionTriggered)
    let overlay = UIStackView(arrangedSubviews: [status, reconnect])
    overlay.axis = .vertical
    overlay.alignment = .center
    overlay.spacing = 12
    overlay.translatesAutoresizingMaskIntoConstraints = false
    addSubview(overlay)
    NSLayoutConstraint.activate([
      overlay.centerXAnchor.constraint(equalTo: safeAreaLayoutGuide.centerXAnchor),
      overlay.centerYAnchor.constraint(equalTo: safeAreaLayoutGuide.centerYAnchor),
      overlay.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: 24),
      overlay.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -24),
      reconnect.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
    ])
    show(nil)
  }

  func setSource(_ json: String) {
    guard let next = try? JSONDecoder().decode(Source.self, from: Data(json.utf8)), next != source else { return }
    source = next
    if window != nil { connect() }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil {
      disconnect()
    } else if link == nil, terminalId == nil {
      connect()
    }
  }

  // MARK: Connection

  private func connect() {
    disconnect()
    guard let source else { return }
    generation += 1
    let current = generation
    terminal.getTerminal().resetToInitialState()
    emit(.connecting)
    show("native.terminal.connecting")
    if source.fixture == true { return startFixture() }
    guard let invite = LanHub.credential(for: source.workspaceId),
          let port = UInt16(exactly: source.port) else {
      return fail("native.terminal.unavailable", detail: nil)
    }
    let link = LanTerminalLink(
      endpoint: LanTerminalEndpoint(host: source.host, port: port),
      lanId: invite.id,
      key: LanTerminalProtocol.key(token: invite.token),
      machineId: source.machineId
    )
    self.link = link
    link.onEvent = { [weak self] event in
      MainActor.assumeIsolated { self?.receive(event, generation: current) }
    }
    link.onClose = { [weak self] failure in
      MainActor.assumeIsolated {
        guard let self, self.generation == current else { return }
        self.fail("native.terminal.disconnected", detail: failure.localizedDescription)
      }
    }
    link.start { [weak self] result in
      MainActor.assumeIsolated {
        guard let self, self.generation == current else { return }
        switch result {
        case let .failure(failure): self.fail("native.terminal.unreachable", detail: failure.localizedDescription)
        case .success: self.open(source, link: link, generation: current)
        }
      }
    }
  }

  private func open(_ source: Source, link: LanTerminalLink, generation current: Int) {
    let size = terminalSize()
    link.request(.open(sessionId: source.sessionId, cols: size.cols, rows: size.rows)) { [weak self] result in
      MainActor.assumeIsolated {
        guard let self, self.generation == current else { return }
        guard case let .success(.opened(_, terminalId, _)) = result else {
          return self.fail("native.terminal.openFailed", detail: Self.detail(result))
        }
        self.terminalId = terminalId
        let size = self.terminalSize()
        link.request(.attach(terminalId: terminalId, cols: size.cols, rows: size.rows)) { [weak self] result in
          MainActor.assumeIsolated {
            guard let self, self.generation == current else { return }
            guard case let .success(.title(_, _, title)) = result else {
              return self.fail("native.terminal.openFailed", detail: Self.detail(result))
            }
            self.show(nil)
            self.emit(.ready, title: title)
            _ = self.terminal.becomeFirstResponder()
          }
        }
      }
    }
  }

  private func receive(_ event: LanTerminalEvent, generation current: Int) {
    guard generation == current else { return }
    switch event {
    case let .data(_, id, data, _) where id == terminalId:
      feed(data)
    case let .title(_, id, title) where id == terminalId:
      emit(.ready, title: title)
    case let .exit(_, id, _, _) where id == terminalId:
      drop()
      emit(.exited)
      show("native.terminal.exited", retry: true)
    default:
      break
    }
  }

  private func disconnect() {
    generation += 1
    if let link {
      if let terminalId { link.close(terminal: terminalId) } else { link.cancel() }
    }
    link = nil
    terminalId = nil
  }

  /// Ends the link without reporting its own close, which would replace this state.
  private func drop() {
    generation += 1
    link?.cancel()
    link = nil
    terminalId = nil
  }

  private func fail(_ key: String, detail: String?) {
    drop()
    _ = terminal.resignFirstResponder()
    emit(.failed, message: detail)
    show(key, retry: true, detail: detail)
  }

  private static func detail(_ result: Result<LanTerminalEvent, LanTerminalLink.Failure>) -> String? {
    if case let .failure(failure) = result { return failure.localizedDescription }
    return nil
  }

  // MARK: Fixture

  private func startFixture() {
    terminalId = "fixture"
    // Powerline and Nerd Font glyphs, as a Powerlevel10k prompt draws them.
    feed("Lody LAN terminal fixture \u{E0B0} \u{F07C} \u{E725}\r\n$ ")
    show(nil)
    emit(.ready, title: "fixture")
    _ = terminal.becomeFirstResponder()
  }

  private func fixtureInput(_ text: String) {
    for character in text {
      if character == "\r" || character == "\n" {
        feed("\r\n\(fixtureLine)\r\n$ ")
        fixtureLine = ""
      } else if character == "\u{7f}" {
        guard !fixtureLine.isEmpty else { continue }
        fixtureLine.removeLast()
        feed("\u{8} \u{8}")
      } else {
        fixtureLine.append(character)
        feed(String(character))
      }
    }
  }

  // MARK: Presentation

  /// Prompts such as Powerlevel10k draw Nerd Font and Powerline glyphs that
  /// SF Mono lacks. The bundled MesloLGS NF carries them; CJK falls back to the
  /// system font and SwiftTerm still lays it out across two cells.
  private static let nerdFonts: Bool = ["MesloLGS-NF-Regular", "MesloLGS-NF-Bold"].allSatisfy { name in
    guard let url = Bundle(for: LodyTerminalView.self).url(forResource: name, withExtension: "ttf")
      ?? Bundle.main.url(forResource: name, withExtension: "ttf") else { return false }
    var error: Unmanaged<CFError>?
    // Registering twice reports "already registered"; the font is usable either way.
    _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
    return UIFont(name: name, size: 12) != nil
  }

  private static func applyFont(to terminal: TerminalView, size: CGFloat) {
    guard nerdFonts, let regular = UIFont(name: "MesloLGS-NF-Regular", size: size),
          let bold = UIFont(name: "MesloLGS-NF-Bold", size: size) else {
      terminal.font = .monospacedSystemFont(ofSize: size, weight: .regular)
      return
    }
    terminal.setFonts(normal: regular, bold: bold, italic: regular, boldItalic: bold)
  }

  private func feed(_ text: String) {
    terminal.feed(text: text)
    guard !accessibilityPending else { return }
    accessibilityPending = true
    // VoiceOver reads the visible screen; coalesce bursts of output.
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(250))
      guard let self else { return }
      self.accessibilityPending = false
      let screen = self.terminal.getTerminal()
      var lines = (0..<screen.rows).compactMap { screen.getLine(row: $0)?.translateToString(trimRight: true) }
      while lines.last?.isEmpty == true { lines.removeLast() }
      self.terminal.accessibilityValue = lines.suffix(12).joined(separator: "\n")
    }
  }

  private func terminalSize() -> (cols: Int, rows: Int) {
    let size = terminal.getTerminal()
    return (max(size.cols, 20), max(size.rows, 5))
  }

  private func show(_ key: String?, retry: Bool = false, detail: String? = nil) {
    status.text = key.map { key in [LodyStrings.text(key), detail].compactMap { $0 }.joined(separator: "\n") }
    status.isHidden = key == nil
    reconnect.isHidden = !retry
    terminal.alpha = key == nil ? 1 : 0.35
  }

  private func emit(_ state: State, title: String? = nil, message: String? = nil) {
    var payload: [String: Any] = ["state": state.rawValue]
    if let title { payload["title"] = title }
    if let message { payload["message"] = message }
    onState(payload)
  }

  private func applyColors() {
    let traits = traitCollection
    terminal.nativeBackgroundColor = UIColor.systemBackground.resolvedColor(with: traits)
    terminal.nativeForegroundColor = UIColor.label.resolvedColor(with: traits)
    terminal.caretColor = tintColor.resolvedColor(with: traits)
    terminal.keyboardAppearance = traits.userInterfaceStyle == .dark ? .dark : .default
  }
}

// SwiftTerm calls its delegate on the main thread from its UIKit view.
extension LodyTerminalView: @preconcurrency TerminalViewDelegate {
  func send(source: TerminalView, data: ArraySlice<UInt8>) {
    let text = String(decoding: data, as: UTF8.self)
    if self.source?.fixture == true { return fixtureInput(text) }
    guard let terminalId, let link else { return }
    link.send(.input(terminalId: terminalId, data: text))
  }

  func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
    guard let terminalId, let link, newCols > 0, newRows > 0 else { return }
    link.send(.resize(terminalId: terminalId, cols: newCols, rows: newRows))
  }

  func setTerminalTitle(source: TerminalView, title: String) {}

  func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

  func scrolled(source: TerminalView, position: Double) {}

  func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
    guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
    UIApplication.shared.open(url)
  }

  func clipboardCopy(source: TerminalView, content: Data) {
    UIPasteboard.general.string = String(decoding: content, as: UTF8.self)
  }

  func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
