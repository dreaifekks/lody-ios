import Litext
import UIKit

final class ChatMarkdownCell: UICollectionViewCell {
  private var markdown: ChatMarkdownView?
  var selectionLabels: [TextLabelView] { markdown?.selectionLabels ?? [] }
  var codeSelectionLabels: [TextLabelView] { markdown?.codeSelectionLabels ?? [] }
  var tableSelectionGroups: [TextSelectionGroup] { markdown?.tableSelectionGroups ?? [] }
  private let icon = UIImageView()
  private(set) var row: ChatRow?
  private var topInset = ChatRowPadding.content
  var onLink: ((String) -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    icon.contentMode = .center
    contentView.addSubview(icon)
    clipsToBounds = false
    contentView.clipsToBounds = false
    isAccessibilityElement = true
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(_ row: ChatRow, markdown: ChatMarkdownView, previousKind: String? = nil) {
    self.row = row
    topInset = ChatRowPadding.top(kind: row.kind, previousKind: previousKind)
    if self.markdown !== markdown {
      if self.markdown?.superview === contentView {
        self.markdown?.clearSelection()
        self.markdown?.removeFromSuperview()
      }
      self.markdown = markdown
      contentView.addSubview(markdown)
    }
    markdown.onLink = { [weak self] in self?.onLink?($0) }
    markdown.setShine(row.shines)
    icon.image = row.symbol.isEmpty ? nil : UIImage(systemName: row.symbol, withConfiguration: ChatCell.iconSymbolConfiguration(for: row))
    icon.tintColor = .secondaryLabel  // No warning orange in a conversation.
    accessibilityIdentifier = row.id
    accessibilityLabel = row.text
    accessibilityCustomActions = markdown.fileActions
    accessibilityTraits = row.actionable ? .button : .staticText
    setNeedsLayout()
  }

  func clearSelection() {
    if markdown?.superview === contentView { markdown?.clearSelection() }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    row = nil
    topInset = ChatRowPadding.content
    markdown?.setShine(false)
    if markdown?.superview === contentView {
      markdown?.clearSelection()
      markdown?.onLink = nil
      markdown?.removeFromSuperview()
    }
    markdown = nil
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard let row, let markdown else { return }
    let width = contentView.bounds.width
    let inset = ChatCell.leading(row)
    let textWidth = ChatCell.textWidth(row, width: width)
    markdown.measure(width: textWidth)
    let height = markdown.measuredHeight
    markdown.frame = CGRect(x: inset, y: topInset, width: textWidth, height: height)
    icon.frame = ChatCell.iconFrame(for: row, textY: topInset, textHeight: height)
    var view: UIView? = superview
    while let current = view, !(current is UIScrollView) { view = current.superview }
    markdown.trackedScrollView = view as? UIScrollView
    clipsToBounds = false
    contentView.clipsToBounds = false
    layer.masksToBounds = false
    contentView.layer.masksToBounds = false
    ChatTableViewport.apply(to: markdown)
  }

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    if super.point(inside: point, with: event) { return true }
    guard let markdown, markdown.superview === contentView else { return false }
    return markdown.point(inside: markdown.convert(point, from: self), with: event)
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard !isHidden, alpha > 0.01, isUserInteractionEnabled else { return nil }
    if let markdown, markdown.superview === contentView, let hit = markdown.hitTest(markdown.convert(point, from: self), with: event) {
      return hit
    }
    return super.hitTest(point, with: event)
  }
}

/// Forwards a Markdown table's own `TextSelectionGroupDelegate` (Copy as Markdown
/// and horizontal drag-scroll) while layering the conversation's Quote action.
@MainActor
final class ChatTableSelectionDelegate: TextSelectionGroupDelegate {
  weak var group: TextSelectionGroup?
  weak var original: (any TextSelectionGroupDelegate)?
  weak var chat: LodyChatView?

  init(group: TextSelectionGroup, original: (any TextSelectionGroupDelegate)?, chat: LodyChatView) {
    self.group = group
    self.original = original
    self.chat = chat
  }

  func detach() {
    if let group, group.delegate === self {
      group.delegate = original
    }
  }

  func textSelectionGroupDidChangeSelection(_ group: TextSelectionGroup) {
    original?.textSelectionGroupDidChangeSelection(group)
    chat?.textSelectionGroupDidChangeSelection(group)
  }

  func textSelectionGroup(_ group: TextSelectionGroup, didDragSelectionIn label: TextLabelView, at location: CGPoint) {
    original?.textSelectionGroup(group, didDragSelectionIn: label, at: location)
  }

  func textSelectionGroup(_ group: TextSelectionGroup, editMenuForSuggestedActions suggestedActions: [UIMenuElement]) -> UIMenu? {
    let base = original?.textSelectionGroup(group, editMenuForSuggestedActions: suggestedActions)
    let actions = base?.children ?? suggestedActions
    return chat?.textSelectionGroup(group, editMenuForSuggestedActions: actions) ?? base
  }
}

// Only adjacent rendered Markdown rows share a group. Do not silently copy past
// user bubbles, tools, or unloaded history. Table cells keep their own group
// (for Copy as Markdown and horizontal drag-scroll), proxied here to add Quote.
extension LodyChatView: TextSelectionGroupDelegate {
  func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
    if !collectionView.visibleCells.contains(where: { $0 === cell }) {
      (cell as? ChatMarkdownCell)?.clearSelection()
      (cell as? ChatPlanCell)?.clearSelection()
    }
  }

  func refreshMarkdownSelections() {
    var runs: [String: [TextLabelView]] = [:]
    var visibleTables: [ObjectIdentifier: TextSelectionGroup] = [:]
    var previous: IndexPath?
    var key = ""
    for index in collection.indexPathsForVisibleItems.sorted() {
      let cell = collection.cellForItem(at: index)
      if let cell = cell as? ChatMarkdownCell, let row = cell.row {
        if previous?.section != index.section || previous?.item != index.item - 1 {
          key = row.id
        }
        runs[key, default: []].append(contentsOf: cell.selectionLabels)
        for label in cell.codeSelectionLabels {
          runs["code:\(ObjectIdentifier(label))"] = [label]
        }
        for group in cell.tableSelectionGroups {
          visibleTables[ObjectIdentifier(group)] = group
        }
        previous = index
      } else if let cell = cell as? ChatPlanCell, let row = cell.row {
        // Keep plan cards scoped to their own selection group rather than bridging adjacent rows.
        previous = nil
        if !cell.selectionLabels.isEmpty {
          runs["plan:\(row.id)"] = cell.selectionLabels
        }
        for label in cell.codeSelectionLabels {
          runs["code:\(ObjectIdentifier(label))"] = [label]
        }
        for group in cell.tableSelectionGroups {
          visibleTables[ObjectIdentifier(group)] = group
        }
      } else {
        previous = nil
      }
    }
    // A lone label joins a group of one too, so every agent passage offers Quote in its menu.
    for (key, group) in markdownSelections where runs[key] == nil {
      group.labels = []
      markdownSelections[key] = nil
    }
    for (key, labels) in runs {
      let group = markdownSelections[key] ?? TextSelectionGroup()
      group.delegate = self
      // Assigning labels clears selection. Keep it through ordinary layouts and
      // text streaming; reset only when a row/block is replaced or leaves view.
      if !group.labels.elementsEqual(labels, by: ===) { group.labels = labels }
      markdownSelections[key] = group
    }
    for (id, proxy) in tableSelections where visibleTables[id] == nil {
      proxy.detach()
      tableSelections[id] = nil
    }
    for (id, group) in visibleTables {
      if let proxy = tableSelections[id] {
        if group.delegate !== proxy {
          if !(group.delegate is ChatTableSelectionDelegate) { proxy.original = group.delegate }
          group.delegate = proxy
        }
      } else {
        let original = (group.delegate as? ChatTableSelectionDelegate)?.original ?? group.delegate
        let proxy = ChatTableSelectionDelegate(group: group, original: original, chat: self)
        group.delegate = proxy
        tableSelections[id] = proxy
      }
    }
  }

  /// Litext clears a selection only for taps on its own labels; a tap anywhere else in the
  /// transcript (another row, the gaps between rows) clears it too. Taps on the selection keep it.
  @objc func clearMarkdownSelections(_ tap: UITapGestureRecognizer) {
    let groups = Array(markdownSelections.values) + tableSelections.values.compactMap(\.group)
    for group in groups where group.hasSelection
      && !group.labels.contains(where: { $0.window != nil && $0.selectionContains(tap.location(in: $0)) }) {
      group.clearSelection()
    }
  }

  func textSelectionGroupDidChangeSelection(_ group: TextSelectionGroup) {
    if group.hasSelection { pauseTracking() }
  }

  func textSelectionGroup(_ group: TextSelectionGroup, didDragSelectionIn label: TextLabelView, at location: CGPoint) {
    ChatTableViewport.markdown(from: label)?.textLabelView(label, didDragSelectionAt: location)
  }

  /// The system selection menu with Quote beside Copy (web message quotes). The selected text
  /// is read from the group, never through the pasteboard.
  func textSelectionGroup(_ group: TextSelectionGroup, editMenuForSuggestedActions suggestedActions: [UIMenuElement]) -> UIMenu? {
    guard composer.canQuote else { return nil }
    let quote = UIAction(title: String(localized: "native.chat.quote.action", bundle: .lody), image: UIImage(systemName: "quote.opening")) { [weak self, weak group] _ in
      guard let self, let group, let text = group.selectedPlainText() else { return }
      group.clearSelection()
      self.composer.beginQuote(text)
    }
    var children = suggestedActions
    children.insert(quote, at: min(1, children.count))
    return UIMenu(children: children)
  }
}
