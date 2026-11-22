import LodyDesignSystem
import UIKit

/// The compact quota line under a provider's name: `Remaining  5h ▬ 82%  7d ▬ 40%  +1`. It shows the
/// two tightest windows (`AgentProviderSections.compactQuota`); a window at or below 20% left turns
/// orange. Tapping it opens the provider's usage sheet. It hides itself without windows.
@MainActor
final class AgentProviderQuotaLine: UIControl {
  private let row = UIStackView()
  private static let trackWidth: CGFloat = 32

  override init(frame: CGRect) {
    super.init(frame: frame)
    row.axis = .horizontal
    row.alignment = .center
    row.spacing = 10
    row.isUserInteractionEnabled = false
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: leadingAnchor),
      row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
      row.topAnchor.constraint(equalTo: topAnchor, constant: 4),
      row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
    ])
    isAccessibilityElement = true
    accessibilityTraits = .button
    accessibilityIdentifier = "provider-quota"
    isHidden = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override var isHighlighted: Bool {
    didSet { row.alpha = isHighlighted ? 0.45 : 1 }
  }

  /// A small line still gets a comfortable touch target.
  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    bounds.insetBy(dx: -4, dy: -10).contains(point)
  }

  func update(_ windows: [LodyListVisualItem]) {
    row.arrangedSubviews.forEach { $0.removeFromSuperview() }
    isHidden = windows.isEmpty
    accessibilityLabel = AgentProviderSections.quotaSummary(windows)
    guard !windows.isEmpty else { return }
    row.addArrangedSubview(Self.label(AgentProviderSections.text("quotaRemaining"), color: .lodySecondary))
    let compact = AgentProviderSections.compactQuota(windows)
    for window in compact.shown {
      let warning = AgentProviderSections.quotaWarning(window)
      let tint: UIColor = warning ? .systemOrange : .lodySecondary
      let track = UIView()
      track.backgroundColor = .tertiarySystemFill
      track.layer.cornerRadius = 2
      track.clipsToBounds = true
      let fill = UIView()
      fill.backgroundColor = tint
      fill.layer.cornerRadius = 2
      fill.translatesAutoresizingMaskIntoConstraints = false
      track.addSubview(fill)
      let left = CGFloat(AgentProviderSections.remaining(window)) / 100
      NSLayoutConstraint.activate([
        track.widthAnchor.constraint(equalToConstant: Self.trackWidth),
        track.heightAnchor.constraint(equalToConstant: 4),
        fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
        fill.topAnchor.constraint(equalTo: track.topAnchor),
        fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
        fill.widthAnchor.constraint(equalToConstant: Self.trackWidth * left),
      ])
      let percent = Self.label(AgentProviderSections.percent(AgentProviderSections.remaining(window)), color: warning ? .systemOrange : .lodyInk)
      percent.font = percent.font.withTabularNumbers()
      let item = UIStackView(arrangedSubviews: [Self.label(window.shortLabel, color: .lodySecondary), track, percent])
      item.axis = .horizontal
      item.alignment = .center
      item.spacing = 4
      row.addArrangedSubview(item)
    }
    if compact.more > 0 {
      row.addArrangedSubview(Self.label(String.localizedStringWithFormat(AgentProviderSections.text("quotaMore"), compact.more), color: .lodySecondary))
    }
  }

  private static func label(_ text: String, color: UIColor) -> UILabel {
    let label = UILabel()
    label.text = text
    label.font = LodyDesign.font(.footnote, size: 12.5)
    label.adjustsFontForContentSizeCategory = true
    label.textColor = color
    label.setContentCompressionResistancePriority(.required, for: .horizontal)
    return label
  }
}

/// A provider row that carries a quota line under its name. Rows without windows stay system rows.
struct AgentProviderRowContent: UIContentConfiguration {
  var title: String
  var subtitle: String
  var asset: String
  var symbol: String
  var windows: [LodyListVisualItem]
  var onQuota: (@MainActor () -> Void)?

  func makeContentView() -> UIView & UIContentView { AgentProviderRowView(self) }
  func updated(for state: UIConfigurationState) -> AgentProviderRowContent { self }
}

final class AgentProviderRowView: UIView, UIContentView {
  private let icon = UIImageView()
  private let title = UILabel()
  private let subtitle = UILabel()
  private let quota = AgentProviderQuotaLine()

  var configuration: UIContentConfiguration {
    didSet { apply() }
  }

  init(_ configuration: AgentProviderRowContent) {
    self.configuration = configuration
    super.init(frame: .zero)
    icon.contentMode = .scaleAspectFit
    icon.tintColor = .lodySecondary
    icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)
    title.font = LodyDesign.font(.subheadline, size: 15)
    title.textColor = .lodyInk
    title.numberOfLines = 0
    subtitle.font = LodyDesign.font(.footnote, size: 12.5)
    subtitle.textColor = .lodySecondary
    subtitle.numberOfLines = 0
    for label in [title, subtitle] { label.adjustsFontForContentSizeCategory = true }
    quota.addAction(UIAction { [weak self] _ in
      (self?.configuration as? AgentProviderRowContent)?.onQuota?()
    }, for: .touchUpInside)
    let text = UIStackView(arrangedSubviews: [title, subtitle, quota])
    text.axis = .vertical
    text.alignment = .leading
    text.spacing = 2
    text.setCustomSpacing(2, after: subtitle)
    for view in [icon, text] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }
    NSLayoutConstraint.activate([
      icon.centerXAnchor.constraint(equalTo: leadingAnchor, constant: LodyFlatRows.iconCenter),
      icon.centerYAnchor.constraint(equalTo: title.centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: LodyFlatRows.iconSize),
      icon.heightAnchor.constraint(equalToConstant: LodyFlatRows.iconSize),
      text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: LodyDesign.Rail.text),
      text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      text.topAnchor.constraint(equalTo: topAnchor, constant: 9),
      text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
      heightAnchor.constraint(greaterThanOrEqualToConstant: LodyFlatRows.minHeight(hasSubtitle: true)),
    ])
    apply()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  private func apply() {
    guard let content = configuration as? AgentProviderRowContent else { return }
    title.text = content.title
    subtitle.text = content.subtitle
    subtitle.isHidden = content.subtitle.isEmpty
    let image = content.asset.isEmpty ? nil : LodyIcon(rawValue: content.asset)?.uiImage
      ?? UIImage(named: content.asset, in: .main, compatibleWith: nil) ?? UIImage(named: content.asset)
    icon.image = (image ?? UIImage(systemName: content.symbol))?.withRenderingMode(.alwaysTemplate)
    quota.update(content.windows)
  }
}

/// One bar per subscription window: what is left, and when it resets.
@MainActor
final class AgentProviderUsageView: UIStackView {
  init() {
    super.init(frame: .zero)
    axis = .vertical
    spacing = 14
    isLayoutMarginsRelativeArrangement = true
    directionalLayoutMargins = NSDirectionalEdgeInsets(
      top: 12, leading: LodyFormGroup.margin, bottom: 12, trailing: LodyFormGroup.margin
    )
  }

  @available(*, unavailable)
  required init(coder: NSCoder) { fatalError() }

  func update(_ windows: [LodyListVisualItem], group: String = "") {
    arrangedSubviews.forEach { $0.removeFromSuperview() }
    for window in windows {
      let label = UILabel()
      label.font = .preferredFont(forTextStyle: .subheadline)
      label.adjustsFontForContentSizeCategory = true
      // The group header already names the quota.
      let prefix = group + " · "
      label.text = !group.isEmpty && window.label.hasPrefix(prefix) ? String(window.label.dropFirst(prefix.count)) : window.label
      label.numberOfLines = 0
      let value = UILabel()
      value.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.medium).withTabularNumbers()
      value.text = window.value
      value.textColor = AgentProviderSections.quotaWarning(window) ? .systemOrange : .lodyInk
      value.setContentCompressionResistancePriority(.required, for: .horizontal)
      value.setContentHuggingPriority(.required, for: .horizontal)
      let heading = UIStackView(arrangedSubviews: [label, value])
      heading.spacing = 12
      let bar = UIProgressView(progressViewStyle: .default)
      let warning = window.tone == "warning" || AgentProviderSections.quotaWarning(window)
      bar.progressTintColor = warning ? .systemOrange : .lodyAccent
      bar.trackTintColor = .tertiarySystemFill
      bar.progress = Float(max(0, min(1, 1 - window.fraction)))
      let caption = UILabel()
      caption.font = .preferredFont(forTextStyle: .caption1)
      caption.adjustsFontForContentSizeCategory = true
      caption.textColor = .secondaryLabel
      caption.numberOfLines = 0
      caption.text = [window.caption, window.detail].filter { !$0.isEmpty }.joined(separator: " · ")
      let block = UIStackView(arrangedSubviews: [heading, bar, caption])
      block.axis = .vertical
      block.spacing = 6
      block.isAccessibilityElement = true
      block.accessibilityLabel = window.accessibilityLabel
      addArrangedSubview(block)
    }
  }
}

/// The provider's usage sheet, shared by the list's quota line and the editor's: windows grouped by the
/// quota that reported them, the shared/offline note, and Refresh usage when the provider allows it.
@MainActor
final class AgentProviderUsageController: LodyFormController {
  private let machine: AgentProviderMachine
  private let item: AgentProviderItem
  private let scope: SettingsActor
  private let scopeKey: String
  private let details: ProviderDetailService
  private let canRefresh: Bool
  /// Whether the provider supports Refresh usage; nil until its detail says.
  private var supported: Bool?
  private var refreshGroup: UIView?
  private let groups = UIStackView()
  private let note = LodyFormGroup.caption()
  private let status = LodyFormGroup.caption()
  private let spinner = UIActivityIndicatorView(style: .medium)
  private var busy = false
  private var observer: NSObjectProtocol?
  private lazy var refreshButton = LodyFormButton.make(id: "provider-rate-limits-refresh", title: AgentProviderSections.text("rate-limits-refresh")) { [weak self] in
    self?.refreshUsage()
  }
  private lazy var doneItem = Self.barButton(symbol: "xmark", label: AgentProviderSections.text("done")) { [weak self] in self?.closeForm() }

  /// `canRefresh`: the caller may manage the provider and its machine is online. `supported` comes from
  /// the provider's detail when the caller has it; otherwise the sheet reads the detail itself.
  init(machine: AgentProviderMachine, item: AgentProviderItem, scope: SettingsActor, details: ProviderDetailService,
       canRefresh: Bool, supported: Bool? = nil) {
    self.machine = machine
    self.item = item
    self.scope = scope
    scopeKey = scope.key
    self.details = details
    self.canRefresh = canRefresh && !machine.readOnly && !item.readOnly && machine.online
    self.supported = supported
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  isolated deinit {
    if let observer { NotificationCenter.default.removeObserver(observer) }
  }

  static func sheetTitle(_ item: AgentProviderItem) -> String {
    let name = item.name.isEmpty ? RemoteSettingsSections.agentName(item.agentType) : item.name
    return String.localizedStringWithFormat(AgentProviderSections.text("usageTitle"), name)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    groups.axis = .vertical
    groups.spacing = LodyDesign.Rail.groupGap
    stack.addArrangedSubview(groups)
    note.text = machine.online ? RemoteSettingsSections.usage("sharedShort") : RemoteSettingsSections.usage("lastOffline")
    stack.addArrangedSubview(LodyFormGroup.inset(note))
    if canRefresh {
      let group = LodyFormGroup(refreshButton)
      refreshGroup = group
      stack.addArrangedSubview(group)
      spinner.hidesWhenStopped = true
      status.accessibilityIdentifier = "provider-operation-status"
      let line = UIStackView(arrangedSubviews: [spinner, status])
      line.spacing = 8
      line.alignment = .center
      stack.addArrangedSubview(LodyFormGroup.inset(line))
      if supported == nil { readSupport() }
    }
    observer = NotificationCenter.default.addObserver(forName: .lodyCatalogDidChange, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.render() }
    }
    render()
  }

  override func didMove(toParent parent: UIViewController?) {
    super.didMove(toParent: parent)
    header?.leftBarButtonItems = [doneItem]
  }

  private var windows: [LodyListVisualItem] {
    guard let reported = RemoteSettingsContext.current().agentUsage[machine.id] else { return [] }
    let setting = RemoteSetting(kind: "agent", id: item.id, name: item.name, machineId: machine.id, detail: item.agentType)
    return RemoteSettingsSections.rings(setting, reported, now: LodyRelativeTime.now())
  }

  private func render() {
    guard isViewLoaded else { return }
    groups.arrangedSubviews.forEach { $0.removeFromSuperview() }
    let current = windows
    for group in AgentProviderSections.quotaGroups(current) {
      let view = AgentProviderUsageView()
      view.update(group.windows, group: group.title)
      groups.addArrangedSubview(LodyFormGroup(header: group.title.isEmpty ? nil : group.title, view))
    }
    if current.isEmpty {
      let empty = LodyFormGroup.caption()
      empty.text = AgentProviderSections.text("usageEmpty")
      groups.addArrangedSubview(LodyFormGroup.inset(empty))
    }
    refreshGroup?.isHidden = supported != true
    refreshButton.isEnabled = !busy && scope.key == scopeKey
    if busy { spinner.startAnimating() } else { spinner.stopAnimating() }
  }

  private func readSupport() {
    let target = ProviderTarget(workspaceId: scope.workspaceId, machineId: machine.id, id: item.id)
    Task { [weak self, details] in
      let detail = try? await details.detail(target)
      guard let self, self.scope.key == self.scopeKey else { return }
      self.supported = detail.map { detail in
        detail.supportsRateLimitsRefresh != false && !detail.unavailableActions.contains { $0.action == "rate-limits-refresh" }
      } ?? false
      self.render()
    }
  }

  private func refreshUsage() {
    guard canRefresh, supported == true, !busy, scope.key == scopeKey else { return }
    busy = true
    status.text = AgentProviderSections.text("working")
    render()
    let request = ProviderOperationRequest(workspaceId: scope.workspaceId, machineId: machine.id, id: item.id,
                                           action: "rate-limits-refresh", cliType: nil, agentType: nil)
    Task { [weak self, details] in
      var message = "operationUnknown"
      do {
        let result = try await details.operation(request)
        message = result.success ? "operationComplete" : "operationFailed"
      } catch {}
      guard let self, self.scope.key == self.scopeKey else { return }
      self.busy = false
      self.status.text = AgentProviderSections.text(message)
      self.render()
    }
  }
}
