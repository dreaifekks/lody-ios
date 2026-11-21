import UIKit

extension NSAttributedString.Key {
  /// A sent quote's range in a user bubble; `ChatReferenceChipsView` draws its leading bar.
  static let lodyQuoteBar = NSAttributedString.Key("lodyQuoteBar")
}

/// The link a bubble's quote block carries; tapping it opens `ChatQuoteViewerController`.
enum ChatQuoteLink {
  static let prefix = "lody-quote:"
  static func snapshot(_ href: String) -> String? {
    href.hasPrefix(prefix) ? String(href.dropFirst(prefix.count)) : nil
  }
}

/// A composer quote card (web message quotes): a read-only snapshot of a passage and the
/// user's comment on it. The runtime turns cards into the web wire format at send
/// (`cloud-runtime` `appendMessageQuotes`): the main text, then each quote block and comment.
/// Lives in its own file because the Share Extension compiles the composer.
struct ChatMessageQuote: Codable, Equatable {
  /// Web `MAX_SELECTION_TEXT`, in UTF-16 code units.
  static let maxLength = 50_000
  /// The machine protocol capability the runtime needs to deliver quotes.
  static let capability = "messageQuotes"

  let id: String
  /// The quoted passage. Never edited once the card exists.
  let text: String
  var comment: String

  init(id: String = UUID().uuidString.lowercased(), text: String, comment: String = "") {
    self.id = id
    self.text = text
    self.comment = comment
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    text = try container.decode(String.self, forKey: .text)
    comment = try container.decodeIfPresent(String.self, forKey: .comment) ?? ""
  }

  var json: [String: Any] { ["id": id, "text": text, "comment": comment] }

  /// Cards from a JSON array (a send payload, a stored draft or an edit draft).
  static func decode(_ value: Any?) -> [ChatMessageQuote] {
    guard let value, JSONSerialization.isValidJSONObject(["quotes": value]),
          let data = try? JSONSerialization.data(withJSONObject: value) else { return [] }
    return (try? JSONDecoder().decode([ChatMessageQuote].self, from: data)) ?? []
  }

  /// The passage on one line, for the card.
  var excerpt: String {
    String(text.prefix(240)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  /// The comment's first line, or nil without a comment.
  var commentLine: String? {
    comment.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .first { !$0.isEmpty }
  }

  /// A selection the composer can quote, or the message explaining why not.
  static func snapshot(of selection: String) -> Result<String, QuoteRejection> {
    let snapshot = selection.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !snapshot.isEmpty else { return .failure(.empty) }
    guard (snapshot as NSString).length <= maxLength else { return .failure(.tooLong) }
    return .success(snapshot)
  }

  enum QuoteRejection: Error { case empty, tooLong }

  static var upgradeMessage: String { String(localized: "native.chat.quote.upgrade", bundle: .lody) }
  static var tooLongMessage: String { String(localized: "native.chat.quote.tooLong", bundle: .lody) }
}

/// The quoted passage drawn as in a message: a leading bar, secondary ink.
private final class ChatQuoteSnapshotView: UIView {
  let text = UITextView()
  private let bar = UIView()

  init(snapshot: String, selectable: Bool) {
    super.init(frame: .zero)
    bar.backgroundColor = .lodyTertiary
    bar.layer.cornerRadius = 1.5
    text.text = snapshot
    text.font = .preferredFont(forTextStyle: .body)
    text.adjustsFontForContentSizeCategory = true
    text.textColor = .secondaryLabel
    text.backgroundColor = .clear
    text.isEditable = false
    text.isSelectable = selectable
    text.textContainerInset = .zero
    text.textContainer.lineFragmentPadding = 0
    text.accessibilityIdentifier = "quote-snapshot"
    for view in [bar, text] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }
    NSLayoutConstraint.activate([
      bar.leadingAnchor.constraint(equalTo: leadingAnchor),
      bar.topAnchor.constraint(equalTo: topAnchor),
      bar.bottomAnchor.constraint(equalTo: bottomAnchor),
      bar.widthAnchor.constraint(equalToConstant: 3),
      text.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 10),
      text.trailingAnchor.constraint(equalTo: trailingAnchor),
      text.topAnchor.constraint(equalTo: topAnchor),
      text.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private func quoteSheetHeader(title: String, leading: UIView?, trailing: UIView?) -> UIView {
  let label = UILabel()
  label.text = title
  label.font = .preferredFont(forTextStyle: .headline)
  label.adjustsFontForContentSizeCategory = true
  label.textAlignment = .center
  label.accessibilityTraits = .header
  let header = UIView()
  for view in [label, leading, trailing].compactMap({ $0 }) {
    view.translatesAutoresizingMaskIntoConstraints = false
    header.addSubview(view)
  }
  var constraints = [
    header.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
    label.centerXAnchor.constraint(equalTo: header.centerXAnchor),
    label.centerYAnchor.constraint(equalTo: header.centerYAnchor),
    label.widthAnchor.constraint(lessThanOrEqualTo: header.widthAnchor, multiplier: 0.5),
  ]
  if let leading {
    constraints += [leading.leadingAnchor.constraint(equalTo: header.leadingAnchor),
                    leading.centerYAnchor.constraint(equalTo: header.centerYAnchor),
                    leading.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)]
  }
  if let trailing {
    constraints += [trailing.trailingAnchor.constraint(equalTo: header.trailingAnchor),
                    trailing.centerYAnchor.constraint(equalTo: header.centerYAnchor),
                    trailing.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)]
  }
  NSLayoutConstraint.activate(constraints)
  return header
}

private func presentAsQuoteSheet(_ controller: UIViewController) {
  if let sheet = controller.sheetPresentationController {
    sheet.detents = [.medium(), .large()]
    sheet.prefersGrabberVisible = true
    sheet.prefersScrollingExpandsWhenScrolledToEdge = false
  }
}

/// Writes the comment on a quoted passage (web `MessageQuoteAction` sheet). The snapshot
/// is read-only; Add creates the card, Save and Remove quote edit an existing one, and
/// swiping down or Cancel leaves the composer unchanged.
final class ChatQuoteSheetController: UIViewController, UITextViewDelegate {
  private var quote: ChatMessageQuote
  private let editingCard: Bool
  private let onCommit: (ChatMessageQuote) -> Void
  private let onRemove: () -> Void
  private let snapshot: ChatQuoteSnapshotView
  private let toggle = UIButton(type: .system)
  private let comment = UITextView()
  private let placeholder = UILabel()
  private var snapshotHeight: NSLayoutConstraint!
  private var expanded = false
  private static let collapsedLines: CGFloat = 4

  init(quote: ChatMessageQuote, editing: Bool, onCommit: @escaping (ChatMessageQuote) -> Void, onRemove: @escaping () -> Void = {}) {
    self.quote = quote
    editingCard = editing
    self.onCommit = onCommit
    self.onRemove = onRemove
    snapshot = ChatQuoteSnapshotView(snapshot: quote.text, selectable: false)
    super.init(nibName: nil, bundle: nil)
    presentAsQuoteSheet(self)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    view.accessibilityIdentifier = "quote-sheet"
    var cancelConfig = UIButton.Configuration.plain()
    cancelConfig.title = String(localized: "common.cancel", bundle: .lody)
    cancelConfig.baseForegroundColor = .label
    let cancel = UIButton(configuration: cancelConfig)
    cancel.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
    var primaryConfig = UIButton.Configuration.filled()
    let primaryKey = editingCard ? "common.save" : "native.chat.quote.add"
    primaryConfig.title = String(localized: String.LocalizationValue(primaryKey), bundle: .lody)
    primaryConfig.cornerStyle = .capsule
    primaryConfig.baseBackgroundColor = .lodyAccent
    primaryConfig.baseForegroundColor = .systemBackground
    let primary = UIButton(configuration: primaryConfig)
    primary.accessibilityIdentifier = "quote-commit"
    primary.addAction(UIAction { [weak self] _ in self?.commit() }, for: .touchUpInside)
    let header = quoteSheetHeader(title: String(localized: "native.chat.quote.action", bundle: .lody), leading: cancel, trailing: primary)

    toggle.titleLabel?.font = .preferredFont(forTextStyle: .footnote)
    toggle.contentHorizontalAlignment = .leading
    toggle.tintColor = .secondaryLabel
    toggle.addAction(UIAction { [weak self] _ in self?.toggleSnapshot() }, for: .touchUpInside)

    comment.text = quote.comment
    comment.font = .preferredFont(forTextStyle: .body)
    comment.adjustsFontForContentSizeCategory = true
    comment.backgroundColor = .secondarySystemBackground
    comment.layer.cornerRadius = 12
    comment.layer.cornerCurve = .continuous
    comment.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
    comment.delegate = self
    comment.accessibilityIdentifier = "quote-comment"
    // The comment takes the sheet's remaining height above the keyboard.
    comment.setContentHuggingPriority(.init(1), for: .vertical)
    comment.accessibilityLabel = String(localized: "native.chat.quote.addComment", bundle: .lody)
    placeholder.text = String(localized: "native.chat.quote.addComment", bundle: .lody)
    placeholder.font = comment.font
    placeholder.textColor = .placeholderText
    placeholder.isHidden = !quote.comment.isEmpty
    placeholder.isUserInteractionEnabled = false
    placeholder.translatesAutoresizingMaskIntoConstraints = false
    comment.addSubview(placeholder)

    let stack = UIStackView(arrangedSubviews: [header, snapshot, toggle, comment])
    stack.axis = .vertical
    stack.spacing = 12
    stack.setCustomSpacing(4, after: snapshot)
    if editingCard {
      var removeConfig = UIButton.Configuration.plain()
      removeConfig.title = String(localized: "native.chat.quote.remove", bundle: .lody)
      removeConfig.baseForegroundColor = .systemRed
      let remove = UIButton(configuration: removeConfig)
      remove.accessibilityIdentifier = "quote-remove"
      remove.addAction(UIAction { [weak self] _ in
        guard let self else { return }
        self.onRemove()
        self.dismiss(animated: true)
      }, for: .touchUpInside)
      remove.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
      stack.addArrangedSubview(remove)
    }
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    snapshotHeight = snapshot.heightAnchor.constraint(equalToConstant: collapsedHeight)
    let fill = stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12)
    fill.priority = .defaultHigh
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
      stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor, constant: -12),
      fill,
      snapshotHeight,
      comment.heightAnchor.constraint(greaterThanOrEqualToConstant: 88),
      placeholder.topAnchor.constraint(equalTo: comment.topAnchor, constant: 10),
      placeholder.leadingAnchor.constraint(equalTo: comment.leadingAnchor, constant: 13),
    ])
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    comment.becomeFirstResponder()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    renderSnapshot()
  }

  private var collapsedHeight: CGFloat {
    ceil((snapshot.text.font ?? .preferredFont(forTextStyle: .body)).lineHeight * Self.collapsedLines)
  }

  private func renderSnapshot() {
    let width = snapshot.text.bounds.width
    guard width > 0 else { return }
    let full = ceil(snapshot.text.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    let collapsed = collapsedHeight
    let expandable = full > collapsed + 1
    toggle.isHidden = !expandable
    let key = expanded ? "native.chat.message.collapse" : "native.chat.message.expand"
    toggle.setTitle(String(localized: String.LocalizationValue(key), bundle: .lody), for: .normal)
    // Expanded, the passage scrolls inside at most half the sheet so the comment stays in reach.
    let limit = max(collapsed, view.bounds.height * 0.45)
    let height = expanded ? min(full, limit) : min(full, collapsed)
    snapshot.text.isScrollEnabled = expanded && full > height
    if snapshotHeight.constant != height { snapshotHeight.constant = height }
  }

  private func toggleSnapshot() {
    expanded.toggle()
    UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.25) {
      self.renderSnapshot()
      self.view.layoutIfNeeded()
    }
  }

  private func commit() {
    quote.comment = comment.text.trimmingCharacters(in: .whitespacesAndNewlines)
    onCommit(quote)
    dismiss(animated: true)
  }

  func textViewDidChange(_ textView: UITextView) {
    placeholder.isHidden = !textView.text.isEmpty
  }
}

/// A sent quote in full, selectable for Copy (history taps).
final class ChatQuoteViewerController: UIViewController {
  private let snapshot: ChatQuoteSnapshotView

  init(snapshot text: String) {
    snapshot = ChatQuoteSnapshotView(snapshot: text, selectable: true)
    super.init(nibName: nil, bundle: nil)
    presentAsQuoteSheet(self)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    view.accessibilityIdentifier = "quote-viewer"
    var doneConfig = UIButton.Configuration.plain()
    doneConfig.title = String(localized: "common.done", bundle: .lody)
    doneConfig.baseForegroundColor = .label
    let done = UIButton(configuration: doneConfig)
    done.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
    let header = quoteSheetHeader(title: String(localized: "native.chat.quote.viewerTitle", bundle: .lody), leading: nil, trailing: done)
    snapshot.text.isScrollEnabled = true
    snapshot.text.textColor = .label
    for child in [header, snapshot] as [UIView] {
      child.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(child)
    }
    NSLayoutConstraint.activate([
      header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
      header.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
      header.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
      snapshot.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
      snapshot.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
      snapshot.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
      snapshot.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
    ])
  }
}
