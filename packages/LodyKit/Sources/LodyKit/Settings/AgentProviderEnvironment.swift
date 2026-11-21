import UIKit

/// Environment values are write-only drafts, never loaded from a list or saved locally. Each variable is
/// a row that opens `AgentProviderEnvSheet`; the patch keeps the wire semantics: an absent key keeps the
/// saved value, nil removes it and a string replaces it.
@MainActor
final class AgentProviderEnvironment: UIStackView {
  var changed: (() -> Void)?
  private(set) var patch: [String: String?] = [:]
  private var keys: [String] = []
  private var protectedKeys: Set<String> = []
  private var editable = true
  private var rows: [LodyFormValueRow] = []
  private let add = LodyFormValueRow(id: "provider-env-add", title: AgentProviderSections.text("envAdd"))

  init() {
    super.init(frame: .zero)
    axis = .vertical
    add.addAction(UIAction { [weak self] _ in self?.open(nil) }, for: .touchUpInside)
    rebuild()
  }

  @available(*, unavailable)
  required init(coder: NSCoder) { fatalError() }

  func configure(keys: [String], protectedKeys: Set<String> = []) {
    self.keys = keys
    self.protectedKeys = protectedKeys
    rebuild()
  }

  func setEditable(_ editable: Bool) {
    self.editable = editable
    for row in rows { row.isEnabled = editable }
    add.isEnabled = editable
  }

  func clearSecrets() {
    patch.removeAll()
    rebuild()
  }

  private func isValidName(_ candidate: String) -> Bool {
    candidate.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
      && !protectedKeys.contains(candidate) && !keys.contains(candidate) && !patch.keys.contains(candidate)
  }

  private func choice(_ name: String) -> AgentProviderEnvSheet.Choice {
    guard let change = patch[name] else { return .keep }
    return change == nil ? .remove : .replace
  }

  private func open(_ name: String?) {
    guard editable else { return }
    let sheet = AgentProviderEnvSheet(
      name: name, saved: name.map { keys.contains($0) } ?? false, choice: name.map { choice($0) } ?? .replace,
      isValidName: { [weak self] in self?.isValidName($0) ?? false }
    ) { [weak self] name, choice, value in
      guard let self else { return }
      switch choice {
      case .replace: self.patch.updateValue(value, forKey: name)
      case .remove:
        if self.keys.contains(name) { self.patch.updateValue(nil, forKey: name) }
        else { self.patch.removeValue(forKey: name) }
      case .keep: self.patch.removeValue(forKey: name)
      }
      self.rebuild()
      self.changed?()
    }
    LodyShell.shared.presentNative(sheet, title: name ?? AgentProviderSections.text("envAdd"), detents: [0.5, 1])
  }

  private func rebuild() {
    arrangedSubviews.forEach { $0.removeFromSuperview() }
    rows = Set(keys).union(patch.keys).sorted().filter { !protectedKeys.contains($0) }.map { name in
      let row = LodyFormValueRow(id: "provider-env:\(name)", title: name)
      let state: String
      switch choice(name) {
      case .keep: state = "envStateSaved"
      case .replace: state = keys.contains(name) ? "envStateReplaced" : "envStateNew"
      case .remove: state = "envStateRemoved"
      }
      row.update(value: AgentProviderSections.text(state))
      row.addAction(UIAction { [weak self] _ in self?.open(name) }, for: .touchUpInside)
      return row
    }
    add.update(value: "")
    addArrangedSubview(LodyFormGroup(header: AgentProviderSections.text("environment"), footer: AgentProviderSections.text("envWriteOnly"),
                                     rows: rows + [add]))
    setEditable(editable)
  }
}
