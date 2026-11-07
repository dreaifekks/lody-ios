import SwiftTerm
import UIKit

/// SwiftTerm 1.19's default accessory uses sub-44 pt buttons on iPhone.
/// Keep its public input path, with a native scrolling row of full-size keys.
@MainActor
final class TerminalKeyboardAccessory: UIInputView, UIInputViewAudioFeedback {
  private enum Key: Sendable {
    case escape, control, tab, text(String), left, down, up, right, mouse, function(Int), hide
  }
  private weak var terminal: TerminalView?
  private let stockArrowActions: TerminalAccessory
  private let leftArrowAction: UIButton
  private let rightArrowAction: UIButton
  private let scroll = UIScrollView()
  private var controlButton: UIButton?
  private var mouseButton: UIButton?
  private var repeatTimer: Timer?

  nonisolated var enableInputClicksWhenVisible: Bool { true }
  override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 52) }

  init(terminal: TerminalView) {
    self.terminal = terminal
    // 1.19's horizontal-arrow actions include internal BiDi paragraph handling.
    // Compose its native controls via UIKit target/action instead of copying
    // that private layout algorithm or guessing a replacement byte sequence.
    let stock = TerminalAccessory(frame: CGRect(x: 0, y: 0, width: 320, height: 36),
      inputViewStyle: .keyboard, container: terminal)
    stock.setupUI()
    func arrowAction(_ action: String) -> UIButton {
      guard let button = stock.subviews.compactMap({ $0 as? UIButton }).first(where: {
        $0.actions(forTarget: stock, forControlEvent: .touchDown)?.contains(action) == true
      }) else { preconditionFailure("SwiftTerm 1.19 arrow action changed") }
      return button
    }
    stockArrowActions = stock
    leftArrowAction = arrowAction("left:")
    rightArrowAction = arrowAction("right:")
    super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 52), inputViewStyle: .keyboard)
    allowsSelfSizing = true
    backgroundColor = .secondarySystemBackground
    tintColor = .lodySignal
    accessibilityIdentifier = "terminal-keyboard-accessory"
    scroll.accessibilityIdentifier = "terminal-keyboard-scroll"
    scroll.accessibilityLabel = Self.text("shortcuts")
    scroll.showsHorizontalScrollIndicator = false
    scroll.alwaysBounceHorizontal = true
    scroll.delaysContentTouches = false
    scroll.translatesAutoresizingMaskIntoConstraints = false
    let keys = UIStackView()
    keys.axis = .horizontal
    keys.spacing = 4
    keys.translatesAutoresizingMaskIntoConstraints = false
    scroll.addSubview(keys)
    addSubview(scroll)
    let hide = button(.hide, id: "hide", symbol: "keyboard.chevron.compact.down", label: "hideKeyboard")
    hide.translatesAutoresizingMaskIntoConstraints = false
    addSubview(hide)
    NSLayoutConstraint.activate([
      scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 4),
      scroll.topAnchor.constraint(equalTo: topAnchor, constant: 4),
      scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
      scroll.trailingAnchor.constraint(equalTo: hide.leadingAnchor, constant: -4),
      hide.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -4),
      hide.topAnchor.constraint(equalTo: scroll.topAnchor),
      hide.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
      keys.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
      keys.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
      keys.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
      keys.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
      keys.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
    ])
    keys.addArrangedSubview(button(.escape, id: "escape", title: "Esc", label: "escape"))
    let control = button(.control, id: "control", title: "Ctrl", label: "control")
    controlButton = control
    keys.addArrangedSubview(control)
    keys.addArrangedSubview(button(.tab, id: "tab", symbol: "arrow.right.to.line.compact", label: "tab"))
    for (character, name) in [("~", "tilde"), ("|", "pipe"), ("/", "slash"), ("-", "dash")] {
      keys.addArrangedSubview(button(.text(character), id: name, title: character, label: name))
    }
    for (key, name) in [(Key.left, "left"), (.down, "down"), (.up, "up"), (.right, "right")] {
      let arrow = button(key, id: name, symbol: "arrow." + name, label: name)
      let hold = UILongPressGestureRecognizer(target: self, action: #selector(heldArrow(_:)))
      hold.minimumPressDuration = 0.6
      hold.cancelsTouchesInView = true
      arrow.addGestureRecognizer(hold)
      keys.addArrangedSubview(arrow)
    }
    let mouse = button(.mouse, id: "mouse", symbol: "cursorarrow", label: "mouse")
    mouseButton = mouse
    keys.addArrangedSubview(mouse)
    // These are optional on the stock bar; scrolling keeps them available on all widths.
    for number in 1...10 {
      keys.addArrangedSubview(button(.function(number), id: "f\(number)", title: "F\(number)",
        label: "function", number: number))
    }
    NotificationCenter.default.addObserver(self, selector: #selector(updateModifiers),
      name: .terminalViewControlModifierReset, object: terminal)
    updateModifiers()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }
  isolated deinit { repeatTimer?.invalidate(); NotificationCenter.default.removeObserver(self) }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil { stopRepeating() }
  }

  private func button(_ key: Key, id: String, title: String? = nil, symbol: String? = nil,
                      label: String, number: Int? = nil) -> UIButton {
    var configuration = UIButton.Configuration.gray()
    configuration.title = title
    if let symbol { configuration.image = UIImage(systemName: symbol) }
    configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
    let button = UIButton(configuration: configuration)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.titleLabel?.font = .preferredFont(forTextStyle: .callout)
    button.accessibilityIdentifier = "terminal-key-" + id
    if let number {
      button.accessibilityLabel = String.localizedStringWithFormat(Self.text(label), number)
    } else { button.accessibilityLabel = Self.text(label) }
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
      button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
    ])
    button.configurationUpdateHandler = { button in
      var configuration = button.configuration
      configuration?.baseForegroundColor = button.isSelected ? .lodySignal : .label
      configuration?.baseBackgroundColor = button.isSelected ? .lodySignal : .tertiarySystemFill
      button.configuration = configuration
    }
    button.addAction(UIAction { [weak self] _ in self?.perform(key) }, for: .primaryActionTriggered)
    return button
  }

  private func perform(_ key: Key) {
    guard let terminal else { return }
    UIDevice.current.playInputClick()
    switch key {
    case .escape: terminal.send(EscapeSequences.cmdEsc)
    case .tab: terminal.send(EscapeSequences.cmdTab)
    case let .text(text):
      // Match insertTextFromAccessory's applyModifiers:false through the public
      // insertion API: preserve IME/Kitty input and leave Ctrl/Meta armed.
      let control = terminal.controlModifier, meta = terminal.metaModifier
      terminal.controlModifier = false
      terminal.metaModifier = false
      terminal.insertText(text)
      terminal.controlModifier = control
      terminal.metaModifier = meta
    case .control:
      // With our UIInputView, TerminalView's TerminalAccessory cast is nil and
      // its public controlModifier supplies the stock Ctrl/Kitty/mouse path.
      terminal.controlModifier.toggle()
    case .left: sendHorizontalArrow(leftArrowAction)
    case .down:
      terminal.send(terminal.getTerminal().applicationCursor ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal)
    case .up:
      terminal.send(terminal.getTerminal().applicationCursor ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal)
    case .right: sendHorizontalArrow(rightArrowAction)
    case .mouse: terminal.allowMouseReporting.toggle()
    case let .function(number): terminal.send(EscapeSequences.cmdF[number - 1])
    case .hide: terminal.resignFirstResponder()
    }
    updateModifiers()
  }

  private func sendHorizontalArrow(_ action: UIButton) {
    action.sendActions(for: .touchDown)
    // Our visible button owns repeat/cancellation. Cancel the stock timer after
    // its one native action, including its BiDi/application-cursor resolution.
    action.sendActions(for: .touchUpInside)
  }

  @objc private func updateModifiers() {
    controlButton?.isSelected = terminal?.controlModifier == true
    controlButton?.accessibilityValue = Self.text(controlButton?.isSelected == true ? "on" : "off")
    mouseButton?.isSelected = terminal?.allowMouseReporting == true
    mouseButton?.accessibilityValue = Self.text(mouseButton?.isSelected == true ? "on" : "off")
  }

  @objc private func heldArrow(_ gesture: UILongPressGestureRecognizer) {
    if [.ended, .cancelled, .failed].contains(gesture.state) { stopRepeating(); return }
    guard gesture.state == .began, let id = gesture.view?.accessibilityIdentifier else { return }
    stopRepeating()
    let arrows: [String: Key] = ["terminal-key-left": .left, "terminal-key-down": .down,
      "terminal-key-up": .up, "terminal-key-right": .right]
    guard let key = arrows[id] else { return }
    perform(key)
    let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.perform(key) }
    }
    repeatTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func stopRepeating() { repeatTimer?.invalidate(); repeatTimer = nil }
  private static func text(_ key: String) -> String {
    String(localized: String.LocalizationValue("terminal.key." + key), bundle: .lody)
  }
}
