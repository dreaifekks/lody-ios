import CoreText
import LodyData
import SwiftTerm
import UIKit

/// An interactive shell on a LAN member, in the working directory of one
/// session. The LAN credential is resolved natively from Keychain. Leaving the page ends the shell.
@MainActor
final class LodyTerminalView: UIView {
  enum State: String { case connecting, ready, exited, failed }
  typealias Factory = @MainActor (TerminalShellOwnership, @escaping @MainActor (LanTerminalEvent) -> Void,
                      @escaping @MainActor (LanTerminalLink.Failure) -> Void) -> (any TerminalChannel)?
  var onState: ((State, String?) -> Void)?
  private let sessionId: String
  private var factory: Factory?
  private var started = false
  private var ended = false
  var scrollView: UIScrollView { terminal }

  private let terminal = TerminalView(frame: .zero)
  private let status = UILabel()
  private let reconnect = UIButton(configuration: .tinted())
  private var link: (any TerminalChannel)?
  private var terminalId: String?
  private let ownership = TerminalShellOwnership()
  /// Callbacks of a replaced link are ignored.
  private var generation = 0
  private var accessibilityPending = false
  private var failureKey: String?

  init(sessionId: String, factory: @escaping Factory) {
    self.sessionId = sessionId
    self.factory = factory
    super.init(frame: .zero)
    ownership.onOpenRejected = { [weak self] in
      guard let self, !self.ended, let key = self.failureKey else { return }
      self.show(key, retry: true)
    }
    backgroundColor = .systemBackground
    terminal.translatesAutoresizingMaskIntoConstraints = false
    terminal.terminalDelegate = self
    terminal.accessibilityIdentifier = "terminal-view"
    terminal.isAccessibilityElement = true
    terminal.accessibilityLabel = Self.text("terminal.accessibility")
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
    reconnect.configuration?.title = Self.text("terminal.reconnect")
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

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  func begin() {
    guard !started, !ended else { return }
    started = true
    connect()
  }

  /// Called only after committed navigation, or when account ownership expires.
  func end() {
    guard !ended else { return }
    ended = true
    generation += 1
    ownership.end(using: link)
    factory = nil
    ownership.onOpenRejected = nil
    link = nil
    terminalId = nil
    _ = terminal.resignFirstResponder()
    show("terminal.unavailable")
  }

  isolated deinit { ownership.end(using: link) }

  // MARK: Connection

  private func connect() {
    guard !ended else { return }
    guard !ownership.openUncertain else { return fail("terminal.openUnknown", detail: nil) }
    drop()
    generation += 1
    let current = generation
    failureKey = nil
    terminal.getTerminal().resetToInitialState()
    emit(.connecting)
    show("terminal.connecting")
    guard let factory, let link = factory(ownership, { [weak self] event in
      self?.receive(event, generation: current)
    }, { [weak self] failure in
      guard let self, self.generation == current else { return }
      self.fail("terminal.disconnected", detail: failure.localizedDescription)
    }) else { return fail("terminal.unavailable", detail: nil) }
    self.link = link
    link.start { [weak self, weak link] result in
      guard let self, self.generation == current, !self.ended, let link else { return }
      switch result {
      case let .failure(failure): self.fail("terminal.unreachable", detail: failure.localizedDescription)
      case .success:
        // Only the page's known ID can be restored; never adopt another
        // terminal discovered in this list.
        link.request(.list(sessionId: self.sessionId)) { [weak self, weak link] result in
          guard let self, self.generation == current, !self.ended, let link else { return }
          guard case let .success(.terminals(_, id, terminals)) = result, id == self.sessionId else {
            return self.fail("terminal.openFailed", detail: Self.detail(result))
          }
          if let ownedId = self.ownership.terminalId {
            if terminals.contains(where: { $0.terminalId == ownedId }) {
              link.adopt(terminalId: ownedId)
              self.attach(ownedId, link: link, generation: current)
              return
            }
            // Fresh list confirms the old ID no longer exists.
            self.ownership.confirmExit(ownedId)
          }
          self.open(link, generation: current)
        }
      }
    }
  }

  private func open(_ link: any TerminalChannel, generation current: Int) {
    let ownership = self.ownership
    guard !ownership.openUncertain else { return }
    let attempt = ownership.beginOpen()
    let size = terminalSize()
    link.request(.open(sessionId: sessionId, cols: size.cols, rows: size.rows)) { [weak self, weak link] result in
      // Resolve a local rejection even if onClose already invalidated this UI
      // generation and released its channel. Never clear a newer open attempt.
      switch result {
      case .failure(.notSent(_)), .failure(.refused(_, _)):
        ownership.confirmNotOpened(attempt: attempt)
      default: break
      }
      guard let self, self.generation == current, !self.ended, let link else { return }
      guard case let .success(.opened(_, id, _)) = result else {
        return self.fail("terminal.openFailed", detail: Self.detail(result))
      }
      self.ownership.record(id)
      self.attach(id, link: link, generation: current)
    }
  }

  private func attach(_ id: String, link: any TerminalChannel, generation current: Int) {
    terminalId = id
    let size = terminalSize()
    link.request(.attach(terminalId: id, cols: size.cols, rows: size.rows)) { [weak self] result in
      guard let self, self.generation == current, !self.ended else { return }
      guard case let .success(.title(_, answerId, title)) = result, answerId == id else {
        return self.fail("terminal.openFailed", detail: Self.detail(result))
      }
      self.show(nil)
      self.emit(.ready, title: title)
      _ = self.terminal.becomeFirstResponder()
    }
  }

  private func receive(_ event: LanTerminalEvent, generation current: Int) {
    guard generation == current else { return }
    switch event {
    case let .data(_, id, data, _) where id == terminalId:
      feed(data)
    case let .title(_, id, title) where id == terminalId:
      emit(.ready, title: title)
    case let .error(_, id, _, message) where id == nil || id == terminalId:
      fail("terminal.disconnected", detail: message)
    case let .exit(_, id, _, _) where id == terminalId:
      ownership.confirmExit(id)
      drop()
      emit(.exited)
      show("terminal.exited", retry: true)
    default:
      break
    }
  }

  /// Lose a subscription, retaining the page's shell identity and cleanup route.
  private func drop() {
    generation += 1
    link?.disconnect()
    link = nil
    terminalId = nil
  }

  private func fail(_ key: String, detail: String?) {
    failureKey = key
    drop()
    _ = terminal.resignFirstResponder()
    emit(.failed, message: detail)
    if ownership.openUncertain { show("terminal.openUnknown", detail: detail) }
    else { show(key, retry: true, detail: detail) }
  }

  private static func detail(_ result: Result<LanTerminalEvent, LanTerminalLink.Failure>) -> String? {
    if case let .failure(failure) = result { return failure.localizedDescription }
    return nil
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
    status.text = key.map { key in [Self.text(key), detail].compactMap { $0 }.joined(separator: "\n") }
    status.isHidden = key == nil
    reconnect.isHidden = !retry
    terminal.alpha = key == nil ? 1 : 0.35
  }

  private func emit(_ state: State, title: String? = nil, message: String? = nil) {
    onState?(state, title)
  }

  private static func text(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), bundle: .lody)
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
