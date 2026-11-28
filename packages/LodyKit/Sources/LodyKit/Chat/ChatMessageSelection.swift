import LodyCore
import ObjectiveC
import UIKit

enum ChatShareSelectionMetrics {
  static let leadingGutter: CGFloat = 32
  static let badgeSize: CGFloat = 22
}

struct ChatShareSelectionSession: Equatable {
  let userId: String
  let workspaceId: String
  let sessionId: String
  let payload: RuntimeContract.ConversationShareMessagesResultReady
  let candidateIDs: Set<String>
  var selectedEntryIDs: Set<String>

  init(
    userId: String,
    workspaceId: String,
    sessionId: String,
    payload: RuntimeContract.ConversationShareMessagesResultReady,
    selectedEntryIDs: Set<String> = []
  ) {
    self.userId = userId
    self.workspaceId = workspaceId
    self.sessionId = sessionId
    self.payload = payload
    self.candidateIDs = Set(payload.messages.map(\.id))
    self.selectedEntryIDs = selectedEntryIDs.intersection(self.candidateIDs)
  }

  func selectableEntryIDs(loadedEntryIDs: Set<String>) -> Set<String> {
    candidateIDs.intersection(loadedEntryIDs)
  }

  func selectedCount(loadedEntryIDs: Set<String>) -> Int {
    selectedEntryIDs.intersection(selectableEntryIDs(loadedEntryIDs: loadedEntryIDs)).count
  }

  func areAllLoadedSelected(loadedEntryIDs: Set<String>) -> Bool {
    let selectable = selectableEntryIDs(loadedEntryIDs: loadedEntryIDs)
    guard !selectable.isEmpty else { return false }
    return selectable.isSubset(of: selectedEntryIDs)
  }

  @discardableResult
  mutating func toggleEntry(_ entryID: String, loadedEntryIDs: Set<String>) -> Bool {
    let selectable = selectableEntryIDs(loadedEntryIDs: loadedEntryIDs)
    guard selectable.contains(entryID) else { return false }
    if !selectedEntryIDs.insert(entryID).inserted {
      selectedEntryIDs.remove(entryID)
    }
    return true
  }

  mutating func toggleSelectAll(loadedEntryIDs: Set<String>) {
    let selectable = selectableEntryIDs(loadedEntryIDs: loadedEntryIDs)
    guard !selectable.isEmpty else { return }
    if selectable.isSubset(of: selectedEntryIDs) {
      selectedEntryIDs.subtract(selectable)
    } else {
      selectedEntryIDs.formUnion(selectable)
    }
  }

  func orderedSelectedMessages(loadedEntryIDs: Set<String>? = nil) -> [RuntimeContract.ConversationShareMessage] {
    let allowed: Set<String>
    if let loadedEntryIDs {
      allowed = selectedEntryIDs.intersection(selectableEntryIDs(loadedEntryIDs: loadedEntryIDs))
    } else {
      allowed = selectedEntryIDs
    }
    return payload.messages.filter { allowed.contains($0.id) }
  }
}

enum ChatShareCellSelectionState: Equatable {
  case inactive
  case dimmed
  case selectable(selected: Bool, isFirstRow: Bool, isLastRow: Bool)
}

@MainActor
private var selectionOverlayKey: UInt8 = 0

@MainActor
enum ChatSelectionCellDecoration {
  static func apply(to cell: UICollectionViewCell, state: ChatShareCellSelectionState) {
    switch state {
    case .inactive:
      if let existing = objc_getAssociatedObject(cell, &selectionOverlayKey) as? ChatSelectionOverlayView {
        existing.isHidden = true
      }
      cell.contentView.isUserInteractionEnabled = true
      cell.contentView.alpha = 1
    case .dimmed:
      if let existing = objc_getAssociatedObject(cell, &selectionOverlayKey) as? ChatSelectionOverlayView {
        existing.isHidden = true
      }
      cell.contentView.isUserInteractionEnabled = false
      cell.contentView.alpha = 0.55
    case let .selectable(selected, isFirstRow, isLastRow):
      cell.clipsToBounds = false
      cell.contentView.isUserInteractionEnabled = false
      cell.contentView.alpha = 1
      let overlay = overlayView(for: cell)
      overlay.isHidden = false
      overlay.configure(selected: selected, isFirstRow: isFirstRow, isLastRow: isLastRow)
      if selected {
        cell.accessibilityTraits = [.button, .selected]
        cell.accessibilityValue = String(localized: "chat.shareImage.rowSelected", bundle: .lody)
      } else {
        cell.accessibilityTraits = .button
        cell.accessibilityValue = String(localized: "chat.shareImage.rowNotSelected", bundle: .lody)
      }
    }
  }

  private static func overlayView(for cell: UICollectionViewCell) -> ChatSelectionOverlayView {
    if let existing = objc_getAssociatedObject(cell, &selectionOverlayKey) as? ChatSelectionOverlayView {
      if existing.superview !== cell {
        cell.insertSubview(existing, at: 0)
        existing.attach(to: cell)
      }
      return existing
    }
    let created = ChatSelectionOverlayView()
    cell.insertSubview(created, at: 0)
    created.attach(to: cell)
    objc_setAssociatedObject(cell, &selectionOverlayKey, created, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return created
  }
}

@MainActor
private final class ChatSelectionOverlayView: UIView {
  private let highlight = UIView()
  private let badge = UIView()
  private let checkmark = UIImageView()
  private var boundsObservation: NSKeyValueObservation?
  private var isSelectedState = false
  private var isFirstRowState = false
  private var isLastRowState = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    isAccessibilityElement = false
    clipsToBounds = false

    highlight.isUserInteractionEnabled = false
    highlight.layer.cornerCurve = .continuous
    addSubview(highlight)

    badge.isUserInteractionEnabled = false
    badge.layer.cornerRadius = ChatShareSelectionMetrics.badgeSize / 2
    badge.layer.cornerCurve = .circular
    addSubview(badge)

    checkmark.isUserInteractionEnabled = false
    checkmark.contentMode = .center
    checkmark.image = UIImage(
      systemName: "checkmark",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)
    )
    badge.addSubview(checkmark)

    lodyObserveTraitChanges([.userInterfaceStyle, .accessibilityContrast]) { (view: ChatSelectionOverlayView, _) in
      view.applyColors()
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  func attach(to host: UIView) {
    boundsObservation = host.layer.observe(\.bounds, options: [.initial, .new]) { [weak self, weak host] _, _ in
      MainActor.assumeIsolated {
        guard let self, let host else { return }
        self.syncFrame(in: host.bounds)
      }
    }
  }

  func configure(selected: Bool, isFirstRow: Bool, isLastRow: Bool) {
    isSelectedState = selected
    isFirstRowState = isFirstRow
    isLastRowState = isLastRow
    badge.isHidden = !isFirstRow
    checkmark.isHidden = !selected
    highlight.isHidden = !selected

    var corners: CACornerMask = []
    if isFirstRow {
      corners.insert(.layerMinXMinYCorner)
      corners.insert(.layerMaxXMinYCorner)
    }
    if isLastRow {
      corners.insert(.layerMinXMaxYCorner)
      corners.insert(.layerMaxXMaxYCorner)
    }
    highlight.layer.maskedCorners = corners
    highlight.layer.cornerRadius = corners.isEmpty ? 0 : 12
    applyColors()
    if let host = superview { syncFrame(in: host.bounds) }
  }

  private func syncFrame(in hostBounds: CGRect) {
    let next = CGRect(
      x: -ChatShareSelectionMetrics.leadingGutter,
      y: 0,
      width: hostBounds.width + ChatShareSelectionMetrics.leadingGutter + 6,
      height: hostBounds.height
    )
    if frame != next { frame = next }
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    highlight.frame = bounds
    let side = ChatShareSelectionMetrics.badgeSize
    let centeredY = (bounds.height - side) / 2
    let y = max(4, min(12, centeredY))
    badge.frame = CGRect(x: 4, y: y, width: side, height: side)
    checkmark.frame = badge.bounds
  }

  private func applyColors() {
    let isDark = traitCollection.userInterfaceStyle == .dark
    let tintAlpha: CGFloat = isDark ? 0.11 : 0.065
    highlight.backgroundColor = UIColor.lodyAccent.resolvedColor(with: traitCollection).withAlphaComponent(tintAlpha)

    if isSelectedState {
      badge.backgroundColor = UIColor.lodyAccent.resolvedColor(with: traitCollection)
      badge.layer.borderWidth = 0
      badge.layer.borderColor = nil
      checkmark.tintColor = LodyAccent.foregroundColor.resolvedColor(with: traitCollection)
    } else {
      badge.backgroundColor = UIColor.lodyBackground.resolvedColor(with: traitCollection).withAlphaComponent(0.92)
      badge.layer.borderWidth = 1.5
      badge.layer.borderColor = UIColor.lodyTertiary.resolvedColor(with: traitCollection).cgColor
    }
  }
}

@MainActor
final class ChatSelectionToolbar: UIView {
  var onCancel: (() -> Void)?
  var onToggleSelectAll: (() -> Void)?
  var onPreview: (() -> Void)?

  private let hairline = UIView()
  private let container = UIStackView()
  private let topRow = UIView()
  private let countLabel = UILabel()
  let cancelButton = UIButton(type: .system)
  let selectAllButton = UIButton(type: .system)
  let previewButton = UIButton(type: .system)

  override init(frame: CGRect) {
    super.init(frame: frame)
    accessibilityIdentifier = "chat.shareSelection.toolbar"
    backgroundColor = .lodyOpaqueBackground

    hairline.backgroundColor = .lodyLine2
    hairline.translatesAutoresizingMaskIntoConstraints = false
    addSubview(hairline)

    var cancelConfig = UIButton.Configuration.plain()
    cancelConfig.title = String(localized: "common.cancel", bundle: .lody)
    cancelConfig.baseForegroundColor = .label
    cancelConfig.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
    cancelButton.configuration = cancelConfig
    cancelButton.accessibilityIdentifier = "chat.shareSelection.cancel"
    cancelButton.addAction(UIAction { [weak self] _ in self?.onCancel?() }, for: .touchUpInside)

    countLabel.font = UIFont.preferredFont(forTextStyle: .subheadline).withTabularNumbers()
    countLabel.adjustsFontForContentSizeCategory = true
    countLabel.textColor = .secondaryLabel
    countLabel.textAlignment = .center
    countLabel.accessibilityIdentifier = "chat.shareSelection.count"

    var selectAllConfig = UIButton.Configuration.plain()
    selectAllConfig.title = String(localized: "chat.shareImage.selectAll", bundle: .lody)
    selectAllConfig.baseForegroundColor = .lodyAccent
    selectAllConfig.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
    selectAllButton.configuration = selectAllConfig
    selectAllButton.accessibilityIdentifier = "chat.shareSelection.selectAll"
    selectAllButton.addAction(UIAction { [weak self] _ in self?.onToggleSelectAll?() }, for: .touchUpInside)

    for subview in [cancelButton, countLabel, selectAllButton] {
      subview.translatesAutoresizingMaskIntoConstraints = false
      topRow.addSubview(subview)
    }

    var previewConfig = UIButton.Configuration.lodyProminent(font: .systemFont(ofSize: 16, weight: .semibold))
    previewConfig.title = String(localized: "chat.shareImage.previewAction", bundle: .lody)
    previewConfig.image = UIImage(
      systemName: "photo",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
    )
    previewConfig.imagePadding = 8
    previewConfig.cornerStyle = .capsule
    previewButton.configuration = previewConfig
    previewButton.accessibilityIdentifier = "chat.shareSelection.preview"
    previewButton.addAction(UIAction { [weak self] _ in self?.onPreview?() }, for: .touchUpInside)
    previewButton.translatesAutoresizingMaskIntoConstraints = false

    container.axis = .vertical
    container.spacing = 8
    container.alignment = .fill
    container.translatesAutoresizingMaskIntoConstraints = false
    container.addArrangedSubview(topRow)
    container.addArrangedSubview(previewButton)
    addSubview(container)

    let containerWidth = container.widthAnchor.constraint(equalTo: safeAreaLayoutGuide.widthAnchor, constant: -32)
    containerWidth.priority = .defaultHigh

    NSLayoutConstraint.activate([
      hairline.topAnchor.constraint(equalTo: topAnchor),
      hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
      hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
      hairline.heightAnchor.constraint(equalToConstant: 1),

      container.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      container.centerXAnchor.constraint(equalTo: safeAreaLayoutGuide.centerXAnchor),
      container.widthAnchor.constraint(lessThanOrEqualToConstant: ChatReadingColumn.maximumWidth - 32),
      containerWidth,
      container.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -10),

      topRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
      cancelButton.leadingAnchor.constraint(equalTo: topRow.leadingAnchor, constant: -8),
      cancelButton.centerYAnchor.constraint(equalTo: topRow.centerYAnchor),
      cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
      cancelButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),

      selectAllButton.trailingAnchor.constraint(equalTo: topRow.trailingAnchor, constant: 8),
      selectAllButton.centerYAnchor.constraint(equalTo: topRow.centerYAnchor),
      selectAllButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
      selectAllButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),

      countLabel.centerXAnchor.constraint(equalTo: topRow.centerXAnchor),
      countLabel.centerYAnchor.constraint(equalTo: topRow.centerYAnchor),
      countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: cancelButton.trailingAnchor, constant: 8),
      countLabel.trailingAnchor.constraint(lessThanOrEqualTo: selectAllButton.leadingAnchor, constant: -8),

      previewButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 46),
    ])

    update(selectedCount: 0, allSelected: false, hasSelectable: false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  func update(selectedCount: Int, allSelected: Bool, hasSelectable: Bool) {
    countLabel.text = String.localizedStringWithFormat(
      String(localized: "chat.shareImage.selectedCount", bundle: .lody),
      Int64(selectedCount)
    )
    let toggleKey = allSelected ? "chat.shareImage.clearSelection" : "chat.shareImage.selectAll"
    selectAllButton.configuration?.title = String(localized: String.LocalizationValue(toggleKey), bundle: .lody)
    selectAllButton.isEnabled = hasSelectable
    previewButton.isEnabled = selectedCount > 0
  }
}
