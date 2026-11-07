import UIKit

@MainActor
final class JoinLanController: FormController {
  private let join: @MainActor (String) async throws -> Void
  private let invite = LodyFormField(id: "lan-invite", label: String(localized: "lan.join.invite", bundle: .lody), text: nil, limit: 4096)
  private let failure = LodyFormGroup.caption(color: .systemRed, size: 15)
  private var task: Task<Void, Never>?
  private var busy = false
  private lazy var joinItem = Self.barButton(title: String(localized: "lan.join.action", bundle: .lody),
    label: String(localized: "lan.join.action", bundle: .lody), prominent: true) { [weak self] in self?.submit() }

  init(join: @escaping @MainActor (String) async throws -> Void = OnboardingService.live.joinLAN) {
    self.join = join
    super.init(nibName: nil, bundle: nil)
    title = String(localized: "lan.join.title", bundle: .lody)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  isolated deinit { task?.cancel() }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.accessibilityIdentifier = "join-lan-form"
    invite.isSecureTextEntry = true
    invite.autocapitalizationType = .none
    invite.autocorrectionType = .no
    invite.spellCheckingType = .no
    invite.textContentType = .password
    invite.placeholder = "lody-lan://…"
    invite.changed = { [weak self] in self?.render() }
    failure.numberOfLines = 0
    failure.accessibilityIdentifier = "lan-join-error"
    stack.addArrangedSubview(LodyFormGroup(footer: String(localized: "lan.join.hint", bundle: .lody),
      LodyFormRow(label: String(localized: "lan.join.invite", bundle: .lody), content: invite)))
    stack.addArrangedSubview(LodyFormGroup.inset(failure))
    render()
  }

  override func didMove(toParent parent: UIViewController?) {
    super.didMove(toParent: parent)
    joinItem.accessibilityIdentifier = "lan-join-submit"
    header?.rightBarButtonItems = [joinItem]
    render()
  }

  private func render() {
    joinItem.isEnabled = !busy && !invite.trimmed.isEmpty
    invite.isEnabled = !busy
    (parent ?? self).isModalInPresentation = busy
  }

  private func submit() {
    guard !busy, !invite.trimmed.isEmpty else { return }
    let raw = invite.trimmed
    busy = true
    failure.text = nil
    view.endEditing(true)
    render()
    task = Task { [weak self, join] in
      do {
        try await join(raw)
        guard let self, !Task.isCancelled else { return }
        self.invite.text = nil
        self.busy = false
        self.render()
        LodyShell.shared.finish(from: self, value: nil)
        LodyShell.shared.close(from: self)
      } catch {
        guard let self, !Task.isCancelled else { return }
        self.busy = false
        // Do not reflect an invite or native credential in an error string.
        self.failure.text = String(localized: "lan.join.failed", bundle: .lody)
        self.render()
        UIAccessibility.post(notification: .announcement, argument: self.failure.text)
      }
    }
  }
}
