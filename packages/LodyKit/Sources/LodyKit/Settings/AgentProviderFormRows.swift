import UIKit

/// An editable value in a form: its label on the left, the current value (or a quiet "Not set") on the
/// right and a chevron, so it reads as tappable. Editing happens in a sheet the owner presents.
/// `stacked` puts a multi-line preview under the label (a system prompt).
@MainActor
final class LodyFormValueRow: UIControl {
  private let titleLabel = UILabel()
  private let valueLabel = UILabel()
  private let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
  private var placeholder = false

  init(id: String, title: String, stacked: Bool = false) {
    super.init(frame: .zero)
    accessibilityIdentifier = id
    isAccessibilityElement = true
    accessibilityLabel = title
    titleLabel.text = title
    titleLabel.font = .dynamic(of: 15)
    titleLabel.numberOfLines = 0
    valueLabel.font = .dynamic(of: stacked ? 13 : 15)
    valueLabel.numberOfLines = stacked ? 2 : 1
    valueLabel.lineBreakMode = stacked ? .byTruncatingTail : .byTruncatingMiddle
    valueLabel.textAlignment = stacked ? .natural : .right
    chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
    chevron.tintColor = .lodyTertiary
    chevron.contentMode = .center
    chevron.setContentHuggingPriority(.required, for: .horizontal)
    chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
    titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    titleLabel.setContentCompressionResistancePriority(.defaultHigh + 1, for: .horizontal)
    valueLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
    valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let content: UIStackView
    if stacked {
      let top = UIStackView(arrangedSubviews: [titleLabel, chevron])
      top.spacing = 8
      top.alignment = .center
      content = UIStackView(arrangedSubviews: [top, valueLabel])
      content.axis = .vertical
      content.spacing = 4
    } else {
      content = UIStackView(arrangedSubviews: [titleLabel, valueLabel, chevron])
      content.spacing = 8
      content.alignment = .center
    }
    content.isUserInteractionEnabled = false
    content.translatesAutoresizingMaskIntoConstraints = false
    addSubview(content)
    let margin = LodyFormGroup.margin
    NSLayoutConstraint.activate([
      heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
      content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
      content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
      content.topAnchor.constraint(equalTo: topAnchor, constant: 12),
      content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
    ])
    refresh()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override var isEnabled: Bool { didSet { refresh() } }
  override var isHighlighted: Bool { didSet { backgroundColor = isHighlighted ? .lodyLine : .clear } }

  /// `placeholder` values ("Not set", "Add") read in tertiary ink; `chevron` false marks a fixed value.
  func update(value: String, placeholder: Bool = false, chevron showsChevron: Bool = true) {
    valueLabel.text = value
    valueLabel.isHidden = value.isEmpty
    self.placeholder = placeholder
    chevron.isHidden = !showsChevron
    accessibilityValue = value
    refresh()
  }

  private func refresh() {
    titleLabel.textColor = isEnabled ? .lodyInk : .lodySecondary
    valueLabel.textColor = placeholder || !isEnabled ? .lodyTertiary : .lodySecondary
    chevron.alpha = isEnabled ? 1 : 0.4
    accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
  }
}

/// A small sheet that edits one text value of the draft. Done hands the text back; only the editor's
/// Save persists it.
@MainActor
final class AgentProviderTextSheet: LodyFormController {
  struct Options {
    var multiline = false
    var secure = false
    var url = false
    var minHeight: CGFloat = 160
    var footer: String?
  }

  private let id: String
  private let label: String
  private let initial: String
  private let limit: Int
  private let options: Options
  private let done: (String) -> Void
  private var field: LodyFormField?
  private var area: LodyFormTextView?
  private lazy var cancelItem = Self.barButton(symbol: "xmark", label: String(localized: "common.cancel", bundle: .lody)) { [weak self] in
    self?.closeForm()
  }
  private lazy var doneItem = Self.barButton(symbol: "checkmark", label: AgentProviderSections.text("done"), prominent: true) { [weak self] in
    self?.finish()
  }

  init(id: String, label: String, text: String, limit: Int, options: Options = Options(), done: @escaping (String) -> Void) {
    self.id = id
    self.label = label
    initial = text
    self.limit = limit
    self.options = options
    self.done = done
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    if options.multiline {
      let area = LodyFormTextView(id: id + ":input", label: label, text: initial, limit: limit, minHeight: options.minHeight)
      area.autocapitalizationType = .none
      self.area = area
      stack.addArrangedSubview(LodyFormGroup(footer: options.footer, area))
    } else {
      let field = LodyFormField(id: id + ":input", label: label, text: options.secure ? "" : initial, limit: limit)
      field.clearButtonMode = .whileEditing
      field.autocapitalizationType = .none
      field.autocorrectionType = .no
      if options.secure {
        field.isSecureTextEntry = true
        field.textContentType = nil
      }
      if options.url { field.keyboardType = .URL }
      self.field = field
      stack.addArrangedSubview(LodyFormGroup(footer: options.footer, field))
    }
  }

  override func didMove(toParent parent: UIViewController?) {
    super.didMove(toParent: parent)
    header?.leftBarButtonItems = [cancelItem]
    header?.rightBarButtonItems = [doneItem]
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    if let field { field.becomeFirstResponder() } else { area?.becomeFirstResponder() }
  }

  private func finish() {
    let value = area?.text ?? field?.text ?? ""
    field?.text = ""
    done(value)
    closeForm()
  }
}

/// Edits one environment variable of the draft. Saved values are never shown: an existing variable is
/// kept, replaced with a new value or removed; Add takes a new name and its value.
@MainActor
final class AgentProviderEnvSheet: LodyFormController {
  enum Choice: String { case keep = "envKeep", replace = "envReplace", remove = "envRemove" }

  /// nil for a new variable.
  private let name: String?
  private let saved: Bool
  private let isValidName: (String) -> Bool
  private let done: (String, Choice, String) -> Void
  private var choice: Choice
  private let key = LodyFormField(id: "provider-env-key", label: AgentProviderSections.text("envKey"), text: "", limit: 128)
  private let value = LodyFormField(id: "provider-env-value", label: AgentProviderSections.text("envValue"), text: "", limit: 32000)
  private let mode = UIButton.lodyFormPicker("provider-env-mode")
  private var valueRow: UIView?
  private lazy var cancelItem = Self.barButton(symbol: "xmark", label: String(localized: "common.cancel", bundle: .lody)) { [weak self] in
    self?.closeForm()
  }
  private lazy var doneItem = Self.barButton(symbol: "checkmark", label: AgentProviderSections.text("done"), prominent: true) { [weak self] in
    self?.finish()
  }

  /// `choice` is the variable's current draft state; `isValidName` checks a new name.
  init(name: String?, saved: Bool, choice: Choice, isValidName: @escaping (String) -> Bool,
       done: @escaping (String, Choice, String) -> Void) {
    self.name = name
    self.saved = saved
    self.choice = name == nil ? .replace : choice
    self.isValidName = isValidName
    self.done = done
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    for field in [key, value] {
      field.autocapitalizationType = .none
      field.autocorrectionType = .no
      field.clearButtonMode = .whileEditing
    }
    value.isSecureTextEntry = true
    value.textContentType = nil
    key.changed = { [weak self] in self?.render() }
    let footer = AgentProviderSections.text("envWriteOnly")
    if name == nil {
      stack.addArrangedSubview(LodyFormGroup(footer: footer, key, value))
    } else {
      let row = LodyFormRow(label: AgentProviderSections.text("envAction"), content: mode, picker: true)
      let group = LodyFormGroup(footer: footer, row, value)
      valueRow = group.arrangedSubviews.first { value.isDescendant(of: $0) }
      stack.addArrangedSubview(group)
    }
    render()
  }

  override func didMove(toParent parent: UIViewController?) {
    super.didMove(toParent: parent)
    header?.leftBarButtonItems = [cancelItem]
    header?.rightBarButtonItems = [doneItem]
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    if name == nil { key.becomeFirstResponder() }
  }

  private var choices: [Choice] { saved ? [.keep, .replace, .remove] : [.replace, .remove] }

  private func render() {
    guard isViewLoaded else { return }
    mode.configuration?.title = AgentProviderSections.text(choice.rawValue)
    mode.menu = UIMenu(children: choices.map { next in
      UIAction(title: AgentProviderSections.text(next.rawValue), state: next == choice ? .on : .off) { [weak self] _ in
        guard let self else { return }
        self.choice = next
        if next != .replace { self.value.text = "" }
        self.render()
      }
    })
    if let valueRow { LodyFormGroup.setRow(valueRow, hidden: choice != .replace) }
    doneItem.isEnabled = name != nil || isValidName(key.trimmed)
  }

  private func finish() {
    guard doneItem.isEnabled else { return }
    let entered = choice == .replace ? (value.text ?? "") : ""
    value.text = ""
    done(name ?? key.trimmed, choice, entered)
    closeForm()
  }
}
