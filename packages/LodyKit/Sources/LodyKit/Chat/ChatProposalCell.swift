import LodyCore
import UIKit

/// An Agent's proposal (web `AgentRoleProposalNotice` / `ScheduleProposalNotice` /
/// `ScheduleEditProposalNotice`): what saving, creating or applying would do, then Dismiss and
/// Save / Create / Apply. An edit shows each current value beside the proposed one and a line
/// diff of the prompt, and applies only while the schedule is still the revision it was written
/// against. Once decided it reads as a receipt; a created or updated schedule offers Open.
/// Only the explicit buttons respond to taps.
final class ChatProposalCell: UICollectionViewCell {
  private static let inset: CGFloat = 14
  private static let iconWidth: CGFloat = 26
  private static let previewLimit = 600
  private static let diffLineLimit = 40

  private let card = UIView()
  private let icon = UIImageView()
  private let titleLabel = UILabel()
  private let bodyLabel = UILabel()
  private let noteLabel = UILabel()
  private let dismissButton = UIButton(type: .system)
  private let confirmButton = UIButton(type: .system)
  private let openButton = UIButton(type: .system)
  private var row: ChatRow?
  /// Sizes the confirm capsule from its title even while the spinner replaces it.
  private var confirmTitleForLayout = ""
  /// `true` accepts (Save / Create), `false` dismisses.
  var onDecision: ((Bool) -> Void)?
  var onOpenSchedule: ((String) -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    contentView.addSubview(card)
    card.backgroundColor = .secondarySystemGroupedBackground
    card.layer.cornerRadius = 16
    card.layer.cornerCurve = .continuous
    card.layer.borderWidth = 1 / max(1, traitCollection.displayScale)
    card.layer.borderColor = UIColor.separator.cgColor
    [icon, titleLabel, bodyLabel, noteLabel, dismissButton, openButton, confirmButton].forEach(card.addSubview)
    icon.contentMode = .scaleAspectFit
    icon.tintColor = .secondaryLabel
    icon.isAccessibilityElement = false
    titleLabel.numberOfLines = 0
    bodyLabel.numberOfLines = 0
    noteLabel.numberOfLines = 0
    dismissButton.addAction(UIAction { [weak self] _ in self?.decide(false) }, for: .primaryActionTriggered)
    confirmButton.addAction(UIAction { [weak self] _ in self?.confirm() }, for: .primaryActionTriggered)
    openButton.addAction(UIAction { [weak self] _ in
      if let id = self?.row?.proposal?.scheduleId { self?.onOpenSchedule?(id) }
    }, for: .primaryActionTriggered)
    lodyObserveTraitChanges([.preferredContentSizeCategory, .userInterfaceStyle]) { (cell: ChatProposalCell, _) in
      cell.card.layer.borderColor = UIColor.separator.resolvedColor(with: cell.traitCollection).cgColor
      if let row = cell.row { cell.configure(row) }
    }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(_ row: ChatRow) {
    self.row = row
    guard let proposal = row.proposal else { return }
    let traits = traitCollection
    icon.image = UIImage(systemName: proposal.isRole ? "person.crop.circle.badge.plus" : "calendar.badge.clock",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 15))
    titleLabel.text = proposal.headline
    titleLabel.font = Self.titleFont(traits)
    titleLabel.textColor = proposal.decided ? .secondaryLabel : .label
    bodyLabel.attributedText = Self.body(proposal, live: row.proposalInspection, traits: traits)
    noteLabel.attributedText = Self.note(row, traits: traits)
    let actions = Self.actions(row)
    dismissButton.isHidden = !actions.decide
    confirmButton.isHidden = !actions.decide && !actions.open
    openButton.isHidden = !actions.openBeside
    let pending = row.proposalState?.pending == true
    dismissButton.configuration = Self.button(Self.text("native.chat.proposal.dismiss"), primary: false, traits: traits)
    openButton.configuration = Self.button(Self.text("native.chat.proposal.open"), primary: false, traits: traits)
    var confirmTitle = Self.text(Self.confirmKey(proposal))
    if actions.open { confirmTitle = Self.text("native.chat.proposal.open") }
    var confirm = Self.button(confirmTitle, primary: actions.decide, traits: traits)
    if pending {
      // Spinner alone: indicator plus title overflowed the title-sized capsule and wrapped it.
      confirm.title = nil
      confirm.showsActivityIndicator = true
    }
    confirmButton.configuration = confirm
    confirmTitleForLayout = confirmTitle
    confirmButton.accessibilityLabel = confirmTitle
    let enabled = Self.enabled(row)
    dismissButton.isEnabled = !pending && enabled.dismiss
    confirmButton.isEnabled = actions.open || (!pending && enabled.confirm)
    card.accessibilityIdentifier = row.id
    dismissButton.accessibilityIdentifier = row.id + ":dismiss"
    confirmButton.accessibilityIdentifier = row.id + ":confirm"
    openButton.accessibilityIdentifier = row.id + ":open"
    isAccessibilityElement = false
    card.accessibilityElements = [titleLabel, bodyLabel, noteLabel, dismissButton, openButton, confirmButton].filter {
      !$0.isHidden && !(($0 as? UILabel)?.attributedText?.length == 0)
    }
    setNeedsLayout()
  }

  private func decide(_ accept: Bool) {
    guard let row, row.proposalState?.pending != true else { return }
    let enabled = Self.enabled(row)
    guard accept ? enabled.confirm : enabled.dismiss else { return }
    // Fence repeated taps before the runtime reports its pending state.
    dismissButton.isEnabled = false
    confirmButton.isEnabled = false
    onDecision?(accept)
  }

  private func confirm() {
    guard let row else { return }
    if Self.actions(row).open, let id = row.proposal?.scheduleId {
      onOpenSchedule?(id)
      return
    }
    decide(true)
  }

  // MARK: Content

  private static func text(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), bundle: .lody)
  }

  private static func confirmKey(_ proposal: ChatProposal) -> String {
    if proposal.isRole { return "native.chat.proposal.save" }
    return proposal.isEdit ? "native.chat.proposal.edit.apply" : "native.chat.proposal.create"
  }

  /// `open` turns the confirm button into Open (a receipt); `openBeside` adds Open next to Apply.
  private static func actions(_ row: ChatRow) -> (decide: Bool, open: Bool, openBeside: Bool) {
    guard let proposal = row.proposal else { return (false, false, false) }
    let schedule = proposal.scheduleId?.isEmpty == false
    if proposal.decided {
      return (false, schedule && (proposal.outcome == "created" || proposal.outcome == "applied"), false)
    }
    return (true, false, proposal.isEdit && schedule)
  }

  /// Web: an edit applies only to a ready live schedule, and only its owner may ignore it
  /// (anyone may ignore one whose schedule is gone). Nothing is decidable before it is read.
  static func enabled(_ row: ChatRow) -> (dismiss: Bool, confirm: Bool) {
    guard row.proposalDecidable, let proposal = row.proposal, !proposal.decided else { return (false, false) }
    guard proposal.isEdit else { return (true, true) }
    guard let live = row.proposalInspection else { return (false, false) }
    return (live.isOwner || live.state == .unavailable, live.state == .ready)
  }

  private static func titleFont(_ traits: UITraitCollection) -> UIFont {
    UIFont.systemFont(ofSize: UIFont.dynamic(of: 15, compatibleWith: traits).pointSize, weight: .semibold)
  }
  private static func labelFont(_ traits: UITraitCollection) -> UIFont {
    UIFont.systemFont(ofSize: UIFont.dynamic(of: 12, compatibleWith: traits).pointSize, weight: .medium)
  }
  private static func bodyFont(_ traits: UITraitCollection) -> UIFont {
    UIFont.dynamic(of: 14, compatibleWith: traits)
  }
  private static func noteFont(_ traits: UITraitCollection) -> UIFont {
    UIFont.dynamic(of: 12.5, compatibleWith: traits)
  }

  private static func clipped(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > previewLimit else { return trimmed }
    return String(trimmed.prefix(previewLimit)) + "…"
  }

  /// Labelled fields, one per paragraph (label above value), web's card order.
  private static func body(_ proposal: ChatProposal, live: RuntimeContract.InspectProposalResult?, traits: UITraitCollection) -> NSAttributedString {
    var fields: [(String, String, String?)] = []
    if proposal.isRole {
      let after = proposal.fields ?? .init()
      let entries: [(String, String?, String?)] = [
        ("native.chat.proposal.role.name", after.name, proposal.before?.name),
        ("native.chat.proposal.role.description", after.description, proposal.before?.description),
        ("native.chat.proposal.role.promptPrefix", after.promptPrefix, proposal.before?.promptPrefix),
      ]
      for (key, value, before) in entries {
        guard let value else { continue }
        let empty = text("native.chat.proposal.empty")
        let shown = value.isEmpty ? empty : clipped(value)
        if proposal.before != nil {
          let previous = (before ?? "").isEmpty ? empty : clipped(before ?? "")
          fields.append((text(key), shown, previous))
        } else {
          fields.append((text(key), shown, nil))
        }
      }
    } else if proposal.isEdit {
      return editBody(proposal, live: live, traits: traits)
    } else {
      if let title = proposal.title { fields.append((text("native.chat.proposal.schedule.name"), title, nil)) }
      if let rule = proposal.rule {
        let zone = rule.timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
        fields.append((text("native.chat.proposal.schedule.when"), ScheduleFormat.summary(rule, zone: zone), nil))
      }
      if let destination = proposal.destination {
        fields.append((text("native.chat.proposal.schedule.sendTo"), text("native.chat.proposal.schedule.destination." + destination), nil))
      }
      if let prompt = proposal.prompt, !proposal.decided {
        fields.append((text("native.chat.proposal.schedule.prompt"), clipped(prompt), nil))
      }
    }
    let result = NSMutableAttributedString()
    let label: [NSAttributedString.Key: Any] = [.font: labelFont(traits), .foregroundColor: UIColor.secondaryLabel]
    let value: [NSAttributedString.Key: Any] = [.font: bodyFont(traits), .foregroundColor: UIColor.label]
    let previous: [NSAttributedString.Key: Any] = [
      .font: bodyFont(traits), .foregroundColor: UIColor.secondaryLabel,
      .strikethroughStyle: NSUnderlineStyle.single.rawValue,
    ]
    let spacing = NSMutableParagraphStyle()
    spacing.paragraphSpacing = 8
    for (index, field) in fields.enumerated() {
      if index > 0 { result.append(NSAttributedString(string: "\n")) }
      result.append(NSAttributedString(string: field.0 + "\n", attributes: label))
      if let before = field.2 {
        result.append(NSAttributedString(string: before + "\n", attributes: previous))
      }
      result.append(NSAttributedString(string: field.1, attributes: value))
    }
    result.addAttribute(.paragraphStyle, value: spacing, range: NSRange(location: 0, length: result.length))
    return result
  }

  /// Web `ScheduleEditProposalNotice`: the schedule's name, each changed field as current (struck
  /// through when it differs) then proposed, and the prompt as a line diff (or the proposed text
  /// when it cannot be compared). A receipt keeps only the name.
  private static func editBody(_ proposal: ChatProposal, live: RuntimeContract.InspectProposalResult?, traits: UITraitCollection) -> NSAttributedString {
    let patch = proposal.patch ?? .init()
    let label: [NSAttributedString.Key: Any] = [.font: labelFont(traits), .foregroundColor: UIColor.secondaryLabel]
    let value: [NSAttributedString.Key: Any] = [.font: bodyFont(traits), .foregroundColor: UIColor.label]
    let previous: [NSAttributedString.Key: Any] = [
      .font: bodyFont(traits), .foregroundColor: UIColor.secondaryLabel,
      .strikethroughStyle: NSUnderlineStyle.single.rawValue,
    ]
    let result = NSMutableAttributedString()
    let field = { (key: String, before: String?, after: String) in
      if result.length > 0 { result.append(NSAttributedString(string: "\n")) }
      result.append(NSAttributedString(string: text(key) + "\n", attributes: label))
      if let before, before != after { result.append(NSAttributedString(string: before + "\n", attributes: previous)) }
      result.append(NSAttributedString(string: after, attributes: value))
    }
    let current = live?.currentTitle ?? proposal.title ?? ""
    if proposal.decided {
      field("native.chat.proposal.schedule.name", nil, proposal.outcome == "applied" ? patch.title ?? current : current)
    } else if let title = patch.title {
      field("native.chat.proposal.schedule.name", live?.currentTitle, title)
    } else {
      field("native.chat.proposal.schedule.name", nil, current)
    }
    let zone = live.flatMap { TimeZone(identifier: $0.timeZone) } ?? .current
    if !proposal.decided, let rule = patch.rule {
      let ruleZone = rule.timeZone.flatMap(TimeZone.init(identifier:)) ?? zone
      let before = live?.currentRule.map { ScheduleFormat.summary($0, zone: $0.timeZone.flatMap(TimeZone.init(identifier:)) ?? zone) }
      field("native.chat.proposal.schedule.when", before, ScheduleFormat.summary(rule, zone: ruleZone))
    }
    if !proposal.decided, let prompt = patch.prompt {
      result.append(NSAttributedString(string: "\n" + text("native.chat.proposal.schedule.prompt") + "\n", attributes: label))
      if let diff = live?.promptDiff, !diff.isEmpty {
        result.append(promptDiff(diff, traits: traits))
      } else {
        result.append(NSAttributedString(string: clipped(prompt), attributes: value))
      }
    }
    let spacing = NSMutableParagraphStyle()
    spacing.paragraphSpacing = 8
    result.addAttribute(.paragraphStyle, value: spacing, range: NSRange(location: 0, length: result.length))
    return result
  }

  /// Web's `<ins>` / `<del>` prompt lines: additions in green, removals struck through, folded runs as ⋯.
  private static func promptDiff(_ lines: [RuntimeContract.PromptDiffLine], traits: UITraitCollection) -> NSAttributedString {
    let font = UIFont.monospacedSystemFont(ofSize: UIFont.dynamic(of: 12.5, compatibleWith: traits).pointSize, weight: .regular)
    let result = NSMutableAttributedString()
    let shown = lines.prefix(diffLineLimit)
    for (index, line) in shown.enumerated() {
      var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.secondaryLabel]
      var prefix = "  "
      switch line.kind {
      case .add:
        prefix = "+ "
        attributes[.foregroundColor] = UIColor.systemGreen
      case .del:
        prefix = "− "
        attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
      case .gap:
        prefix = ""
      case .same:
        break
      }
      let body = line.kind == .gap ? "⋯" : line.text
      result.append(NSAttributedString(string: prefix + body + (index + 1 < shown.count ? "\n" : ""), attributes: attributes))
    }
    if lines.count > shown.count {
      result.append(NSAttributedString(string: "\n⋯", attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel]))
    }
    let tight = NSMutableParagraphStyle()
    tight.lineBreakMode = .byCharWrapping
    result.addAttribute(.paragraphStyle, value: tight, range: NSRange(location: 0, length: result.length))
    return result
  }

  /// Web's reason for an edit that cannot be applied, in its order.
  private static func editReason(_ live: RuntimeContract.InspectProposalResult?) -> String {
    guard let live else { return "" }
    let keys: [RuntimeContract.InspectProposalResultState: String] = [
      .unavailable: "native.chat.proposal.edit.unavailable",
      .stale: "native.chat.proposal.edit.stale",
      .notOwner: "native.chat.proposal.edit.notOwner",
      .machineUnsupported: "native.chat.proposal.error.schedule_machine_unsupported",
      .targetUnavailable: "native.chat.proposal.edit.targetUnavailable",
    ]
    return keys[live.state].map(text) ?? ""
  }

  /// The scope line while open, the owner-only reason, or the last failure.
  private static func note(_ row: ChatRow, traits: UITraitCollection) -> NSAttributedString {
    guard let proposal = row.proposal else { return NSAttributedString() }
    var message = ""
    var color = UIColor.secondaryLabel
    if let failure = row.proposalState?.message, !failure.isEmpty {
      message = failure
      color = .systemRed
    } else if !proposal.decided, proposal.isEdit {
      message = editReason(row.proposalInspection)
    } else if !proposal.decided, !row.proposalDecidable {
      message = text("native.chat.proposal.role.ownerOnly")
    } else if !proposal.decided, proposal.isRole {
      message = text(proposal.action == "create" ? "native.chat.proposal.role.defaults" : "native.chat.proposal.role.scope")
    }
    return NSAttributedString(string: message, attributes: [.font: noteFont(traits), .foregroundColor: color])
  }

  private static func button(_ title: String, primary: Bool, traits: UITraitCollection) -> UIButton.Configuration {
    var configuration: UIButton.Configuration = primary ? .lodyProminentGlass() : .lodyGlass()
    configuration.title = title
    // Resolve against the cell's appearance: a prominent glass button re-resolves dynamic
    // colors for its own tint, so `.systemBackground` on a light fill came out white in dark mode.
    let ink = UIColor.label.resolvedColor(with: traits)
    let paper = UIColor.systemBackground.resolvedColor(with: traits)
    let foreground = primary ? paper : ink
    configuration.baseForegroundColor = foreground
    if primary { configuration.baseBackgroundColor = ink }
    configuration.cornerStyle = .capsule
    configuration.background.backgroundInsets = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)
    configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
    let font = UIFont.systemFont(ofSize: UIFont.dynamic(of: 13, compatibleWith: traits).pointSize, weight: primary ? .semibold : .regular)
    configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
      var next = attributes
      next.font = font
      next.foregroundColor = foreground
      return next
    }
    return configuration
  }

  // MARK: Layout

  private static func textHeight(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
    guard text.length > 0 else { return 0 }
    return ceil(text.boundingRect(with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height)
  }

  private static func titleHeight(_ row: ChatRow, width: CGFloat, traits: UITraitCollection) -> CGFloat {
    let title = NSAttributedString(string: row.proposal?.headline ?? "", attributes: [.font: titleFont(traits)])
    return max(22, textHeight(title, width: width - inset * 2 - iconWidth))
  }

  static func height(_ row: ChatRow, width: CGFloat, traits: UITraitCollection) -> CGFloat {
    guard let proposal = row.proposal else { return 0 }
    let body = textHeight(Self.body(proposal, live: row.proposalInspection, traits: traits), width: width - inset * 2)
    let note = textHeight(Self.note(row, traits: traits), width: width - inset * 2)
    let actions = Self.actions(row)
    let content = inset + titleHeight(row, width: width, traits: traits)
      + (body > 0 ? 10 + body : 0) + (note > 0 ? 8 + note : 0)
    // Buttons draw their capsule 6 pt inside a 44 pt target, so they close the card themselves.
    let card = actions.decide || actions.open ? content + 6 + 44 + 4 : content + inset
    return card + 12
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard let row, let proposal = row.proposal else { return }
    let traits = traitCollection
    card.frame = bounds.insetBy(dx: 0, dy: 6)
    let width = card.bounds.width
    let content = width - Self.inset * 2
    let titleHeight = Self.titleHeight(row, width: width, traits: traits)
    icon.frame = CGRect(x: Self.inset, y: Self.inset + (min(titleHeight, 22) - 18) / 2, width: 18, height: 18)
    titleLabel.frame = CGRect(x: Self.inset + Self.iconWidth, y: Self.inset, width: max(1, content - Self.iconWidth), height: titleHeight)
    var y = titleLabel.frame.maxY
    let body = Self.textHeight(Self.body(proposal, live: row.proposalInspection, traits: traits), width: content)
    if body > 0 { y += 10 }
    bodyLabel.frame = CGRect(x: Self.inset, y: y, width: content, height: body)
    y += body
    let note = Self.textHeight(Self.note(row, traits: traits), width: content)
    if note > 0 { y += 8 }
    noteLabel.frame = CGRect(x: Self.inset, y: y, width: content, height: note)
    y += note + 6
    let font = UIFont.dynamic(of: 13, compatibleWith: traits)
    let fit = { (button: UIButton) -> CGFloat in
      let title = button.configuration?.title ?? ""
      return max(64, ceil((title as NSString).size(withAttributes: [.font: font]).width) + 40)
    }
    let confirmWidth = max(64, ceil((confirmTitleForLayout as NSString).size(withAttributes: [.font: font]).width) + 40)
    confirmButton.frame = CGRect(x: width - Self.inset - confirmWidth, y: y, width: confirmWidth, height: 44)
    var trailing = confirmButton.frame.minX
    if !openButton.isHidden {
      let openWidth = fit(openButton)
      openButton.frame = CGRect(x: trailing - 8 - openWidth, y: y, width: openWidth, height: 44)
      trailing = openButton.frame.minX
    }
    let dismissWidth = fit(dismissButton)
    dismissButton.frame = CGRect(x: trailing - 8 - dismissWidth, y: y, width: dismissWidth, height: 44)
  }
}
