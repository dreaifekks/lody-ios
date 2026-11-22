import LodyDesignSystem
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

// The Home list in the mobile design language, on iPhone and in the iPad / iPhone Duo split. Reference design:
// the native mobile chat-list layout.
//
// It renders the same `InboxSections` projection as the other list hosts and emits
// the same `rowPress` / `rowAction` events, so `InboxController` keeps owning state,
// preferences and actions. Status replaces the trailing age when a chat needs
// attention; collapsed groups show their count and most urgent
// state. Cells are UIKit list cells (selection, swipe actions, context menus) whose
// content is SwiftUI on design-system tokens.
//
// With `status` hooks (Home), a long press opens the full action menu and moving while still
// pressed turns the lifted row into a UIKit drag across sections: drops become runtime commands,
// and the list keeps incoming layouts back until the drag ends.
@MainActor
final class ChatListView: UIView, UICollectionViewDelegate {
  private enum Kind { case header, link, session, more }

  private struct Item: Hashable {
    let section: String
    let row: String
  }

  private struct Entry {
    let kind: Kind
    let row: LodyListRow
    /// nil when the group cannot collapse.
    let expanded: Bool?
    let canToggle: Bool
    /// An expanded family's first child carries the family's collapse chevron.
    var firstChild = false
  }

  var forwarded: ((String, [String: Any]) -> Void)?
  private(set) var collection: UICollectionView!
  private var dataSource: UICollectionViewDiffableDataSource<String, Item>!
  private var entries: [Item: Entry] = [:]
  private var moveDirections: [String: StatusViewMoveDirections] = [:]
  private var titles: [String: String] = [:]
  /// Each labelled section's row count, shown beside a collapsed label.
  private var titleCounts: [String: String] = [:]
  /// Each labelled section's ⋯ menu (pin section management).
  private var titleMenus: [String: [LodyListAction]] = [:]
  /// Repository of each project group's label (project grouping), drawn as its logo.
  private var titleRepositories: [String: String] = [:]
  private let placeholder = UILabel()
  private let topBackdrop = LodyPinnedLabelBackdrop()
  private var placeholderText = ""
  var owners: [String: WorkspaceMember] = [:] { didSet { if owners != oldValue { detailsChanged() } } }
  private var details = ChatRowDetails.stored
  /// The last projection, re-applied when an opener folds or unfolds.
  private var lastSections: [LodyListSection] = []
  /// Openers whose nested chats are hidden; default unfolded, as on web. Stored per device.
  private var foldedOpeners = Set(UserDefaults.standard.stringArray(forKey: ChatListView.foldedKey) ?? [])
  private static let foldedKey = "homeFoldedOpeners"
  /// Home group labels the person collapsed; their headers stay, their rows leave the list.
  private let groupFolds = ChatGroupFolds()
  /// Whether the projection has any row, collapsed or not (the empty-state text hides otherwise).
  private var hasRows = false
  /// UIKit owns a single section header and its push-off at the next section.
  /// Search labels remain in the flow and never collapse.
  var pinsGroupLabels = true {
    didSet {
      guard pinsGroupLabels != oldValue else { return }
      groupFolds.enabled = pinsGroupLabels
      collection.collectionViewLayout.invalidateLayout()
      updateBackdrop()
    }
  }
  var projectIndexEnabled = false {
    didSet {
      guard projectIndexEnabled != oldValue else { return }
      projectIndex.cancel()
      rebuildProjectIndex()
    }
  }
  /// Archived mode: a darker, greyer page and grey titles, so the archive never reads as the inbox.
  var archivedStyle = false {
    didSet {
      guard archivedStyle != oldValue else { return }
      backgroundColor = archivedStyle ? LodyUIColor.bgArchived : LodyUIColor.bgBase
      topBackdrop.archived = archivedStyle
      groupFolds.scope = archivedStyle ? "archived:" : ""
      var snapshot = dataSource.snapshot()
      snapshot.reconfigureItems(snapshot.itemIdentifiers)
      dataSource.apply(snapshot, animatingDifferences: false)
    }
  }
  /// The conversation shown beside the list (iPad and unfolded iPhone Duo split); it stays highlighted.
  var selectedRowId = "" {
    didSet {
      guard selectedRowId != oldValue else { return }
      var snapshot = dataSource.snapshot()
      let affected = snapshot.itemIdentifiers.filter { $0.row == selectedRowId || $0.row == oldValue }
      guard !affected.isEmpty else { return }
      snapshot.reconfigureItems(affected)
      dataSource.apply(snapshot, animatingDifferences: false)
    }
  }
  private lazy var projectIndex = InboxProjectIndex(scroll: collection)
  private var applyingSections = false
  private var sectionGeneration = 0
  private var detailsObserver: NSObjectProtocol?
  /// Status view hooks; nil leaves rows undraggable and the context menu flat.
  var status: ChatListStatusHooks? {
    didSet { collection.dragInteractionEnabled = status != nil }
  }
  /// The root row being dragged; incoming sections wait in `deferredSections` until it lands.
  private var dragging: Item?
  private var deferredSections: [LodyListSection]?
  private var lastDropTarget: StatusViewCommand?
  private let dropFeedback = UISelectionFeedbackGenerator()
  private var dragScroll: CADisplayLink?
  private var dragScrollSpeed: CGFloat = 0
  /// The drop session the edge scroll belongs to, so the target and haptics follow the rows that
  /// scroll under a finger that stays still.
  private weak var scrollingDrop: UIDropSession?
  /// The opener whose opened children leave the list while it is dragged, so the family moves as one.
  private var liftedFamily: String?
  private var resignObserver: NSObjectProtocol?
  private var menuPress: Item?
  private let rowMenuButton = UIButton(type: .system)
  private lazy var rowMenuPress = ChatRowMenuPress(target: self, action: #selector(finishRowMenuPress(_:)))

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = LodyUIColor.bgBase
    var config = UICollectionLayoutListConfiguration(appearance: .plain)
    config.showsSeparators = false
    config.backgroundColor = .clear
    config.headerMode = .supplementary
    config.headerTopPadding = 0
    config.trailingSwipeActionsConfigurationProvider = { [weak self] path in self?.swipe(path, leading: false) }
    config.leadingSwipeActionsConfigurationProvider = { [weak self] path in self?.swipe(path, leading: true) }
    let layout = UICollectionViewCompositionalLayout { [weak self] index, environment in
      let id = self?.dataSource?.sectionIdentifier(for: index)
      let title = id.flatMap { self?.titles[$0] } ?? ""
      var sectionConfig = config
      // Untitled first sections start at the navigation safe area without a blank header.
      if index == 0 && title.isEmpty { sectionConfig.headerMode = .none }
      let section = NSCollectionLayoutSection.list(using: sectionConfig, layoutEnvironment: environment)
      section.interGroupSpacing = 0
      section.boundarySupplementaryItems.forEach {
        $0.pinToVisibleBounds = self?.pinsGroupLabels == true && !title.isEmpty
        $0.zIndex = 2
      }
      return section
    }
    // Group spacing belongs between sections, not inside the pinned label.
    let layoutConfiguration = UICollectionViewCompositionalLayoutConfiguration()
    layoutConfiguration.interSectionSpacing = LodySpacing.md
    layout.configuration = layoutConfiguration
    let collection = ChatListCollectionView(frame: bounds, collectionViewLayout: layout)
    collection.onLayout = { [weak self] in
      self?.updateBackdrop()
      self?.refreshProjectIndex()
    }
    self.collection = collection
    collection.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    collection.backgroundColor = .clear
    collection.delegate = self
    collection.dragDelegate = self
    collection.dropDelegate = self
    collection.dragInteractionEnabled = false
    collection.accessibilityIdentifier = "home-chat-list"
    addSubview(collection)
    // iOS 17.4+ opens the row's menu on a stationary release so a held press drags first. Earlier
    // systems cannot present a menu from code, so they keep the system context menu, which still
    // turns into the drag when the lifted row moves.
    if #available(iOS 17.4, *) {
      rowMenuPress.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
      rowMenuPress.delegate = self
      collection.addGestureRecognizer(rowMenuPress)
      rowMenuButton.showsMenuAsPrimaryAction = true
      rowMenuButton.isUserInteractionEnabled = false
      rowMenuButton.accessibilityElementsHidden = true
      addSubview(rowMenuButton)
    }
    topBackdrop.layer.zPosition = 1
    topBackdrop.isHidden = true
    collection.addSubview(topBackdrop)
    let cell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
      self?.configure(cell, item)
    }
    let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
      elementKind: UICollectionView.elementKindSectionHeader
    ) { [weak self] view, _, path in
      let id = self?.dataSource.sectionIdentifier(for: path.section)
      let title = id.flatMap { self?.titles[$0] } ?? ""
      let repository = id.flatMap { self?.titleRepositories[$0] } ?? ""
      let count = id.flatMap { self?.titleCounts[$0] } ?? ""
      let menu = id.flatMap { self?.titleMenus[$0] } ?? []
      guard let folds = self?.groupFolds else { return }
      view.contentConfiguration = UIHostingConfiguration {
        SectionTitle(
          text: title, repository: repository, count: count, menu: menu, folds: folds, groupId: id ?? "",
          onMenu: { [weak self] action in
            if let id { self?.forwarded?("sectionAction", ["id": id, "actionId": action]) }
          }
        ) { [weak self] in
          if let id { self?.toggleGroup(id) }
        }
      }
      .margins(.all, 0)
      view.backgroundConfiguration = .clear()
      view.layer.zPosition = 2
    }
    dataSource = UICollectionViewDiffableDataSource(collectionView: collection) { view, path, item in
      view.dequeueConfiguredReusableCell(using: cell, for: path, item: item)
    }
    dataSource.supplementaryViewProvider = { view, _, path in
      view.dequeueConfiguredReusableSupplementary(using: header, for: path)
    }

    placeholder.font = LodyTextStyle.body.uiFont
    placeholder.textColor = LodyUIColor.textSecondary
    placeholder.textAlignment = .center
    placeholder.numberOfLines = 0
    placeholder.adjustsFontForContentSizeCategory = true
    placeholder.isHidden = true
    addSubview(placeholder)
    projectIndex.accessibilityLabel = String(localized: "inbox.projectIndex.accessibility", bundle: .lody)
    projectIndex.accessibilityHint = String(localized: "inbox.projectIndex.hint", bundle: .lody)
    projectIndex.jump = { [weak self] in self?.jumpToSection($0) }
    addSubview(projectIndex)
    detailsObserver = NotificationCenter.default.addObserver(forName: .lodyChatRowDetailsChanged, object: nil, queue: .main) {
      [weak self] _ in MainActor.assumeIsolated { self?.detailsChanged() }
    }
    // A modal, the app switcher or a call interrupts the drag; the edge scroll must not keep running.
    resignObserver = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) {
      [weak self] _ in MainActor.assumeIsolated { self?.stopDragScroll() }
    }
  }

  isolated deinit {
    if let detailsObserver { NotificationCenter.default.removeObserver(detailsObserver) }
    if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
  }

  /// The view menu changed which details rows show: re-render visible rows in place.
  private func detailsChanged() {
    details = ChatRowDetails.stored
    var snapshot = dataSource.snapshot()
    snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { entries[$0]?.kind == .session })
    dataSource.apply(snapshot, animatingDifferences: false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func layoutSubviews() {
    super.layoutSubviews()
    if projectIndex.frame.size != bounds.size { projectIndex.cancel() }
    collection.frame = bounds
    projectIndex.frame = bounds
    refreshProjectIndex()
    updateBackdrop()
    let inset = LodyLayout.listEdgeX * 2
    placeholder.frame = CGRect(x: inset, y: bounds.midY - 60, width: max(0, bounds.width - inset * 2), height: 120)
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil { stopDragScroll() }
  }

  func setPlaceholder(_ value: String) {
    placeholderText = value
    updatePlaceholder()
  }

  func setSections(_ sections: [LodyListSection]) {
    // A drag holds the rows it was lifted from; the newest projection lands when it ends.
    if dragging != nil {
      deferredSections = sections
      return
    }
    deferredSections = nil
    apply(sections)
  }

  private func apply(_ sections: [LodyListSection]) {
    projectIndex.cancel()
    projectIndex.update([])
    applyingSections = true
    sectionGeneration += 1
    let generation = sectionGeneration
    lastSections = sections
    hasRows = sections.contains { !$0.rows.isEmpty }
    var snapshot = NSDiffableDataSourceSnapshot<String, Item>()
    var next: [Item: Entry] = [:]
    var nextTitles: [String: String] = [:]
    var nextRepositories: [String: String] = [:]
    var nextCounts: [String: String] = [:]
    var nextMenus: [String: [LodyListAction]] = [:]
    for section in sections where !section.rows.isEmpty || (section.keepsEmpty && !section.header.isEmpty) {
      snapshot.appendSections([section.id])
      // Only flat sections (inbox buckets, search) carry a text header; groups use their parent row.
      nextTitles[section.id] = section.rows.first?.parent == true ? "" : section.header
      nextCounts[section.id] = section.headerValue
      if !section.headerMenu.isEmpty { nextMenus[section.id] = section.headerMenu }
      // Project grouping: the root row keeps its raw repository, never a cross-project child's.
      if section.id.hasPrefix("group:"), section.id != "group:\(InboxSections.chatId)",
         let repository = section.rows.first?.repository, !repository.isEmpty {
        nextRepositories[section.id] = repository
      }
      // A collapsed group keeps its label, which UIKit still lays out for an empty section.
      if !(nextTitles[section.id] ?? "").isEmpty, groupFolds.isCollapsed(section.id) { continue }
      let children = section.rows.contains { !$0.parent }
      var previous: String?
      for row in section.rows {
        let item = Item(section: section.id, row: row.id)
        let entry: Entry
        if row.parent {
          entry = Entry(kind: .header, row: row, expanded: section.headerExpanded, canToggle: section.headerExpanded != nil && children)
        } else if section.headerExpanded == false {
          continue
        } else if row.image == "folder" {
          entry = Entry(kind: .link, row: row, expanded: nil, canToggle: false)
        } else if row.id.hasPrefix("project:") || row.id.hasPrefix("view:") {
          entry = Entry(kind: .more, row: row, expanded: nil, canToggle: false)
        } else if !row.parentId.isEmpty, foldedOpeners.contains(row.parentId) || row.parentId == liftedFamily {
          continue
        } else if row.treeParent {
          // The parent keeps its own state; hidden children have a separate summary.
          let open = !foldedOpeners.contains(row.id)
          entry = Entry(kind: .session, row: row, expanded: open, canToggle: true)
        } else {
          entry = Entry(
            kind: .session, row: row, expanded: nil, canToggle: false,
            firstChild: !row.parentId.isEmpty && row.parentId == previous)
        }
        guard next[item] == nil else { continue }
        next[item] = entry
        previous = row.id
        snapshot.appendItems([item], toSection: section.id)
      }
    }
    let nextMoveDirections = status?.moveDirections() ?? [:]
    let changed = Set(next.keys).filter { key in
      guard let old = entries[key], let new = next[key] else { return false }
      return !Self.same(old.row, new.row, old.expanded, new.expanded) || old.firstChild != new.firstChild
        || moveDirections[key.row] != nextMoveDirections[key.row]
    }
    // Recreate cells when commands change to discard the previous swipe presentation.
    let actionsChanged = Set(next.keys).filter { key in
      guard let old = entries[key], let new = next[key] else { return false }
      return old.row.actions != new.row.actions || old.row.leadingActions != new.row.leadingActions
    }
    entries = next
    moveDirections = nextMoveDirections
    // Header content is not part of the item snapshot; reload labels whose count or menu changed.
    let headersChanged = Set(nextTitles.keys).filter { nextCounts[$0] != titleCounts[$0] || nextMenus[$0] != titleMenus[$0] }
    titles = nextTitles
    titleRepositories = nextRepositories
    titleCounts = nextCounts
    titleMenus = nextMenus
    snapshot.reloadItems(Array(actionsChanged))
    snapshot.reconfigureItems(Array(changed.subtracting(actionsChanged)))
    let current = Set(dataSource.snapshot().sectionIdentifiers)
    let reloadedHeaders = snapshot.sectionIdentifiers.filter { current.contains($0) && headersChanged.contains($0) }
    if !reloadedHeaders.isEmpty { snapshot.reloadSections(reloadedHeaders) }
    dataSource.apply(snapshot, animatingDifferences: window != nil && !UIAccessibility.isReduceMotionEnabled) { [weak self] in
      guard let self, self.sectionGeneration == generation else { return }
      self.applyingSections = false
      self.updateBackdrop()
      self.rebuildProjectIndex()
    }
    updateBackdrop()
    updatePlaceholder()
  }

  private func rebuildProjectIndex() {
    guard !applyingSections else { return }
    let snapshot = dataSource.snapshot()
    let sections = Dictionary(lastSections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let items: [InboxProjectIndex.Item] = projectIndexEnabled ? snapshot.sectionIdentifiers.compactMap { id in
      // Collapsed groups have no items but stay destinations through their label.
      guard let section = sections[id] else { return nil }
      let tints = section.rows.flatMap { [$0.imageTint, $0.collapsedImageTint] }
      let tint = ["danger", "warning", "blue"].first(where: tints.contains)
        ?? (section.rows.contains(where: \.unread) ? "blue" : "")
      let symbol = ["pinned": "pin.fill", "group:chat": "bubble.left" ][id] ?? ""
      // HomeRows preserves raw repository identity even when grouping hides row.place.
      // Use the root, never a cross-project opened child or Pinned's first row.
      let repository = section.rows.first?.repository ?? ""
      let image = symbol.isEmpty ? RepositoryImages.url(repository)?.absoluteString ?? "" : ""
      return InboxProjectIndex.Item(id: id, title: section.header, symbol: symbol, tint: tint, image: image)
    } : []
    projectIndex.update(items)
    collection.showsVerticalScrollIndicator = items.count < 2
    refreshProjectIndex()
  }

  private func refreshProjectIndex() {
    guard !applyingSections else { return }
    let top = collection.contentOffset.y + collection.adjustedContentInset.top
    let path = collection.indexPathsForVisibleItems.filter { path in
      (collection.layoutAttributesForItem(at: path)?.frame.maxY ?? 0) > top
    }.min()
    let id = path.flatMap { dataSource.itemIdentifier(for: $0)?.section }
    projectIndex.refresh(current: id)
  }

  func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    refreshProjectIndex()
    projectIndex.setScrolling(true)
  }

  func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    if !decelerate { projectIndex.setScrolling(false) }
  }

  func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    projectIndex.setScrolling(false)
  }

  private func jumpToSection(_ id: String) {
    guard projectIndexEnabled, !applyingSections else { return }
    let snapshot = dataSource.snapshot()
    guard let sectionIndex = snapshot.indexOfSection(id) else { return }
    // Item geometry is unpinned and belongs to the committed snapshot. Never query
    // supplementary attributes with a path retained across a diffable update.
    let header = collection.collectionViewLayout.layoutAttributesForSupplementaryView(
      ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: sectionIndex)
    )
    let top: CGFloat
    if let item = snapshot.itemIdentifiers(inSection: id).first, let path = dataSource.indexPath(for: item),
       let attributes = collection.layoutAttributesForItem(at: path) {
      top = attributes.frame.minY - (header?.frame.height ?? 0)
    } else if let header, snapshot.numberOfItems(inSection: id) == 0 {
      // A collapsed group has only its label; with no rows below it the label is not pinned.
      top = header.frame.minY
    } else {
      return
    }
    let lower = -collection.adjustedContentInset.top
    let upper = max(lower, collection.contentSize.height - collection.bounds.height + collection.adjustedContentInset.bottom)
    let y = min(upper, max(lower, top - collection.adjustedContentInset.top))
    collection.setContentOffset(CGPoint(x: collection.contentOffset.x, y: y), animated: false)
    collection.layoutIfNeeded()
  }

  private func toggleOpener(_ id: String) {
    if foldedOpeners.remove(id) == nil { foldedOpeners.insert(id) }
    UserDefaults.standard.set(Array(foldedOpeners).sorted(), forKey: Self.foldedKey)
    setSections(lastSections)
  }

  /// The label's chevron turns while the group's rows animate out of or into the list.
  private func toggleGroup(_ id: String) {
    groupFolds.toggle(id)
    setSections(lastSections)
  }

  private func updateBackdrop() {
    topBackdrop.update(in: collection, pinsLabels: pinsGroupLabels)
  }

  private static func same(_ a: LodyListRow, _ b: LodyListRow, _ ea: Bool?, _ eb: Bool?) -> Bool {
    a.title == b.title && a.subtitle == b.subtitle && a.unread == b.unread && a.imageTint == b.imageTint
      && a.value == b.value && a.place == b.place && a.placeIsRepo == b.placeIsRepo && a.repository == b.repository && a.branch == b.branch && a.prStatus == b.prStatus && a.prCI == b.prCI
      && a.collapsedImageTint == b.collapsedImageTint && a.collapsedBadge == b.collapsedBadge
      && a.valueSymbol == b.valueSymbol && a.accessibilityValue == b.accessibilityValue && a.menuActions == b.menuActions
      && a.badge == b.badge && a.pinned == b.pinned && a.parentId == b.parentId && a.lastChild == b.lastChild && a.treeParent == b.treeParent && a.childCount == b.childCount && a.highlight == b.highlight && ea == eb
  }

  private func updatePlaceholder() {
    placeholder.text = placeholderText
    placeholder.isHidden = hasRows || placeholderText.isEmpty
  }

  // MARK: Cells

  private func configure(_ cell: UICollectionViewListCell, _ item: Item) {
    guard let entry = entries[item] else { return }
    let muted = archivedStyle
    let current = entry.kind == .session && entry.row.id == selectedRowId
    let emit: (String) -> Void = { [weak self] action in
      self?.forwarded?("rowAction", ["id": entry.row.id, "actionId": action])
    }
    cell.contentConfiguration = UIHostingConfiguration {
      // UI Verify and VoiceOver tooling address rows by their stable row id.
      switch entry.kind {
      case .header:
        GroupHeader(row: entry.row, expanded: entry.expanded, canToggle: entry.canToggle, onAction: emit)
          .accessibilityIdentifier(entry.row.id)
      case .link:
        GroupHeader(row: entry.row, expanded: nil, canToggle: false, onAction: emit)
          .accessibilityIdentifier(entry.row.id)
      case .session:
        ChatRowContent(
          row: entry.row, details: details, owner: owners[entry.row.id], muted: muted,
          expanded: entry.canToggle ? entry.expanded : nil,
          onOpen: { [weak self] in self?.openSelecting(item, id: entry.row.id) },
          onToggle: { [weak self] in self?.toggleOpener(entry.row.id) },
          collapseFamily: entry.firstChild ? { [weak self] in self?.toggleOpener(entry.row.parentId) } : nil,
          moveUp: moveDirections[item.row]?.up == true ? move(item.row, up: true) : nil,
          moveDown: moveDirections[item.row]?.down == true ? move(item.row, up: false) : nil
        )
        .accessibilityAddTraits(current ? .isSelected : [])
        .accessibilityIdentifier(entry.row.id)
      case .more: MoreRowContent(title: entry.row.title).accessibilityIdentifier(entry.row.id)
      }
    }
    .margins(.all, 0)
    .minSize(height: entry.kind == .session && !entry.row.parentId.isEmpty ? LodySize.controlMd : LodySize.listRow)
    cell.accessories = []
    // iOS highlights rows on press; Android uses ripple.
    // The archived page is already as grey as fill.pressed, so it highlights with a translucent fill.
    let pressed = archivedStyle ? LodyUIColor.fillSelected : LodyUIColor.fillPressed
    // The SwiftUI content is the row's one accessibility element (label, value, selection, actions);
    // the cell stays a container so VoiceOver and UI checks never find a second, unlabelled button.
    cell.isAccessibilityElement = false
    cell.configurationUpdateHandler = { cell, state in
      var background = UIBackgroundConfiguration.clear()
      background.backgroundColor = state.isHighlighted || state.isSelected ? pressed : current ? LodyUIColor.fillSelected : .clear
      cell.backgroundConfiguration = background
    }
  }

  private func move(_ id: String, up: Bool) -> () -> Void {
    { [weak self] in
      guard let status = self?.status, let command = status.step(id, up) else { return }
      status.perform(command)
    }
  }

  // MARK: Interaction

  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    guard let item = dataSource.itemIdentifier(for: indexPath), let entry = entries[item] else {
      collectionView.deselectItem(at: indexPath, animated: true)
      return
    }
    if entry.kind != .session { collectionView.deselectItem(at: indexPath, animated: true) }
    if entry.kind == .header, entry.canToggle, let expanded = entry.expanded {
      forwarded?("rowPress", ["id": entry.row.id, "expanded": !expanded])
    } else {
      forwarded?("rowPress", ["id": entry.row.id])
    }
  }

  private func openSelecting(_ item: Item, id: String) {
    if let path = dataSource.indexPath(for: item) { collection.selectItem(at: path, animated: false, scrollPosition: []) }
    forwarded?("rowPress", ["id": id])
  }

  private func swipe(_ path: IndexPath, leading: Bool) -> UISwipeActionsConfiguration? {
    guard let item = dataSource.itemIdentifier(for: path), let entry = entries[item], entry.kind == .session else { return nil }
    let actions = (leading ? entry.row.leadingActions : entry.row.actions).map { action in
      let contextual = UIContextualAction(style: action.destructive ? .destructive : .normal, title: action.title) { [weak self] _, _, done in
        self?.forwarded?("rowAction", ["id": entry.row.id, "actionId": action.id])
        done(true)
      }
      contextual.image = UIImage(systemName: action.symbol)
      if !action.destructive { contextual.backgroundColor = Self.swipeTint(action.tint) }
      return contextual
    }
    guard !actions.isEmpty else { return nil }
    let config = UISwipeActionsConfiguration(actions: actions)
    config.performsFirstActionWithFullSwipe = false
    return config
  }

  private static func swipeTint(_ tint: String) -> UIColor {
    tint == "yellow" ? .systemYellow : LodyUIColor.accentSolid
  }

  func collectionView(
    _ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint
  ) -> UIContextMenuConfiguration? {
    guard let path = indexPaths.first, let item = dataSource.itemIdentifier(for: path) else { return nil }
    // While a finger is down on a movable row, the system menu would interpret motion over
    // its actions as selection. Let UIKit drag first and open the menu on a stationary release.
    if #available(iOS 17.4, *), rowMenuPress.isTrackingTouch, draggable(item) { return nil }
    guard let menu = rowMenu(item) else { return nil }
    return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
  }

  private func rowMenu(_ item: Item) -> UIMenu? {
    guard let entry = entries[item] else { return nil }
    let row = entry.row
    let leading = entry.kind == .session ? status?.menu(row.id) ?? [] : []
    guard !row.menuActions.isEmpty || !leading.isEmpty else { return nil }
    let rest: [UIMenuElement] = row.menuActions.map { action in
      UIAction(
        title: action.title, image: UIImage(systemName: action.symbol),
        attributes: action.destructive ? .destructive : []
      ) { [weak self] _ in self?.forwarded?("rowAction", ["id": row.id, "actionId": action.id]) }
    }
    guard !leading.isEmpty else { return UIMenu(children: rest) }
    return UIMenu(children: [UIMenu(options: .displayInline, children: leading), UIMenu(options: .displayInline, children: rest)])
  }

  override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard gestureRecognizer === rowMenuPress else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
    guard let path = collection.indexPathForItem(at: gestureRecognizer.location(in: collection)),
      let item = dataSource.itemIdentifier(for: path)
    else { return false }
    return draggable(item)
  }

  /// A held press that never became a drag opens the row's menu on release. Whether the finger
  /// moved is UIKit's call: a drag that begins clears `menuPress` (`dragSessionWillBegin`), so there
  /// is no distance threshold of our own that could disagree with UIKit's lift threshold.
  @objc private func finishRowMenuPress(_ press: UILongPressGestureRecognizer) {
    switch press.state {
    case .began:
      if let path = collection.indexPathForItem(at: press.location(in: collection)), let item = dataSource.itemIdentifier(for: path) {
        menuPress = item
      }
    case .ended:
      defer { menuPress = nil }
      guard let item = menuPress, dragging == nil,
        draggable(item), let path = dataSource.indexPath(for: item),
        let cell = collection.cellForItem(at: path), let menu = rowMenu(item)
      else { return }
      rowMenuButton.menu = menu
      if #available(iOS 17.4, *) {
        rowMenuButton.frame = convert(cell.bounds, from: cell)
        rowMenuButton.performPrimaryAction()
      }
    case .changed:
      break
    default:
      menuPress = nil
    }
  }
}

extension ChatListView: UIGestureRecognizerDelegate {
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
    gestureRecognizer === rowMenuPress
  }
}

private final class ChatRowMenuPress: UILongPressGestureRecognizer {
  private(set) var isTrackingTouch = false

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    isTrackingTouch = true
    super.touchesBegan(touches, with: event)
  }

  override func reset() {
    super.reset()
    isTrackingTouch = false
  }
}

// MARK: - Drag and drop

/// What Home's Status view adds to the list: the status part of a row's context menu, which drops
/// are allowed, accessibility moves, and running the resulting command (which holds the dropped
/// order until the catalog reads it back).
struct ChatListStatusHooks {
  /// Leading context menu elements for a row: Later ▸, Settle / Move to Focus, Pin, Move to section ▸, Move to top.
  var menu: @MainActor (_ rowId: String) -> [UIMenuElement]
  /// Whether a root row may be lifted at all.
  var canDrag: @MainActor (_ rowId: String) -> Bool
  /// The command for dropping root row `rowId` into list section `sectionId` in front of `beforeId`; nil forbids the drop.
  var drop: @MainActor (_ rowId: String, _ sectionId: String, _ beforeId: String?) -> StatusViewCommand?
  var moveDirections: @MainActor () -> [String: StatusViewMoveDirections]
  /// Accessibility Move up / Move down; nil at an edge.
  var step: @MainActor (_ rowId: String, _ up: Bool) -> StatusViewCommand?
  var perform: @MainActor (StatusViewCommand) -> Void
}

extension ChatListView: UICollectionViewDragDelegate, UICollectionViewDropDelegate {
  private func draggable(_ item: Item) -> Bool {
    // Only top-level conversations move; opened children travel with their opener.
    guard let entry = entries[item], entry.kind == .session, entry.row.parentId.isEmpty else { return false }
    return status?.canDrag(item.row) == true
  }

  func collectionView(_ collectionView: UICollectionView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
    guard dragging == nil, let item = dataSource.itemIdentifier(for: indexPath), draggable(item)
    else { return [] }
    let drag = UIDragItem(itemProvider: NSItemProvider(object: "" as NSString))
    drag.localObject = item.row
    session.localContext = item
    return [drag]
  }

  func collectionView(_ collectionView: UICollectionView, dragSessionWillBegin session: UIDragSession) {
    guard let item = session.localContext as? Item else { return }
    menuPress = nil
    lastDropTarget = nil
    dropFeedback.prepare()
    // Opened children travel with their opener: they leave the list for the drag and return with
    // the next projection, instead of staying behind while the opener moves.
    if entries[item]?.row.treeParent == true, !foldedOpeners.contains(item.row) {
      liftedFamily = item.row
      apply(lastSections)
    }
    dragging = item
  }

  func collectionView(_ collectionView: UICollectionView, dragSessionIsRestrictedToDraggingApplication session: UIDragSession) -> Bool { true }

  func collectionView(_ collectionView: UICollectionView, dragSessionAllowsMoveOperation session: UIDragSession) -> Bool { true }

  func collectionView(_ collectionView: UICollectionView, dragPreviewParametersForItemAt indexPath: IndexPath) -> UIDragPreviewParameters? {
    guard let cell = collectionView.cellForItem(at: indexPath) else { return nil }
    let parameters = UIDragPreviewParameters()
    parameters.visiblePath = UIBezierPath(roundedRect: cell.bounds, cornerRadius: LodyRadius.md)
    parameters.backgroundColor = archivedStyle ? LodyUIColor.bgArchived : LodyUIColor.bgBase
    return parameters
  }

  func collectionView(_ collectionView: UICollectionView, dragSessionDidEnd session: UIDragSession) {
    stopDragScroll()
    dragging = nil
    lastDropTarget = nil
    let restoresFamily = liftedFamily != nil
    liftedFamily = nil
    if let deferredSections {
      setSections(deferredSections)
    } else if restoresFamily {
      apply(lastSections)
    }
  }

  func collectionView(_ collectionView: UICollectionView, canHandle session: UIDropSession) -> Bool {
    session.localDragSession != nil && dragging != nil
  }

  func collectionView(_ collectionView: UICollectionView, dropSessionDidExit session: UIDropSession) {
    stopDragScroll()
    lastDropTarget = nil
  }

  func collectionView(
    _ collectionView: UICollectionView, dropSessionDidUpdate session: UIDropSession, withDestinationIndexPath destinationIndexPath: IndexPath?
  ) -> UICollectionViewDropProposal {
    guard dragging != nil else { return UICollectionViewDropProposal(operation: .forbidden) }
    let point = session.location(in: collectionView)
    scrollingDrop = session
    updateDragScroll(at: point)
    let target = dropTarget(at: point, suggested: destinationIndexPath)
    updateDropFeedback(target?.command)
    guard let target else { return UICollectionViewDropProposal(operation: .forbidden) }
    // Between rows the list opens a gap where the row will land; on a label or a collapsed group
    // there is no row position to open.
    return UICollectionViewDropProposal(operation: .move, intent: target.betweenRows ? .insertAtDestinationIndexPath : .unspecified)
  }

  func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
    stopDragScroll()
    guard let status, let moving = dragging,
      let command = dropTarget(at: coordinator.session.location(in: collectionView), suggested: coordinator.destinationIndexPath)?.command,
      case let .move(_, area, _) = command, let drag = coordinator.items.first?.dragItem
    else { return }
    // Apply the held order now, then animate the lifted row into its new cell.
    dragging = nil
    liftedFamily = nil
    status.perform(command)
    if let path = dataSource.indexPath(for: Item(section: area.sectionId, row: moving.row)) {
      coordinator.drop(drag, toItemAt: path)
    } else if let label = header(of: area.sectionId) {
      // A collapsed group has no cell for the row: settle the lifted copy into its label, never the
      // cancel animation that would read as a refused drop.
      let center = CGPoint(x: label.frame.midX, y: label.frame.midY)
      coordinator.drop(drag, to: UIDragPreviewTarget(container: collectionView, center: center, transform: CGAffineTransform(scaleX: 0.1, y: 0.1)))
    }
  }

  private func header(of sectionId: String) -> UICollectionReusableView? {
    guard let section = dataSource.snapshot().indexOfSection(sectionId) else { return nil }
    return collection.supplementaryView(forElementKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: section))
  }

  private func updateDropFeedback(_ command: StatusViewCommand?) {
    guard command != lastDropTarget else { return }
    lastDropTarget = command
    guard command != nil else { return }
    dropFeedback.selectionChanged()
    dropFeedback.prepare()
  }

  private func updateDragScroll(at point: CGPoint) {
    let inset = collection.adjustedContentInset
    let safeArea = collection.safeAreaInsets
    let edge: CGFloat = 64
    let fromTop = point.y - (collection.bounds.minY + max(inset.top, safeArea.top))
    let fromBottom = collection.bounds.maxY - max(inset.bottom, safeArea.bottom) - point.y
    let top = min(edge, max(0, fromTop))
    let bottom = min(edge, max(0, fromBottom))
    dragScrollSpeed = (top - bottom) / edge * 420
    // At the end of the content the edge band is just rows: hovering them must not count as scrolling.
    let minimum = -inset.top
    let maximum = max(minimum, collection.contentSize.height - collection.bounds.height + inset.bottom)
    if (dragScrollSpeed < 0 && collection.contentOffset.y <= minimum) || (dragScrollSpeed > 0 && collection.contentOffset.y >= maximum) {
      dragScrollSpeed = 0
    }
    guard dragScrollSpeed != 0 else {
      stopDragScroll()
      return
    }
    guard dragScroll == nil else { return }
    let link = CADisplayLink(target: self, selector: #selector(advanceDragScroll(_:)))
    dragScroll = link
    link.add(to: .main, forMode: .common)
  }

  @objc private func advanceDragScroll(_ link: CADisplayLink) {
    let inset = collection.adjustedContentInset
    let offset = collection.contentOffset
    let minimum = -inset.top
    let maximum = max(minimum, collection.contentSize.height - collection.bounds.height + inset.bottom)
    let y = min(maximum, max(minimum, offset.y + dragScrollSpeed * (link.targetTimestamp - link.timestamp)))
    guard y != offset.y else { return stopDragScroll() }
    collection.contentOffset.y = y
    // UIKit only reports finger movement; rows scrolling under a still finger change the target too.
    if let session = scrollingDrop, dragging != nil {
      updateDropFeedback(dropTarget(at: session.location(in: collection), suggested: nil)?.command)
    }
  }

  private func stopDragScroll() {
    dragScroll?.invalidate()
    dragScroll = nil
  }

  /// The command a drop at `point` would run, and whether it lands between two rows (where the list
  /// opens a gap) rather than on a label or a collapsed group.
  private func dropTarget(at point: CGPoint, suggested: IndexPath?) -> (command: StatusViewCommand, betweenRows: Bool)? {
    guard let status, let moving = dragging else { return nil }
    let snapshot = dataSource.snapshot()
    let headerKind = UICollectionView.elementKindSectionHeader
    // UIKit suggests an item index. Use the visible header when it covers the finger so even an
    // empty section is a target, and use the actual row midpoint for insertion above or below.
    let header = collection.indexPathsForVisibleSupplementaryElements(ofKind: headerKind).first { path in
      collection.supplementaryView(forElementKind: headerKind, at: path)?.frame.contains(point) == true
    }
    let row = collection.indexPathForItem(at: point)
    guard let destination = header ?? row ?? suggested else { return nil }
    guard destination.section < snapshot.numberOfSections else { return nil }
    let section = snapshot.sectionIdentifiers[destination.section]
    let before: String?
    let collapsed = groupFolds.isCollapsed(section)
    if collapsed {
      let rows = lastSections.first { $0.id == section }?.rows ?? []
      before = rows.first { $0.parentId.isEmpty && !$0.id.hasPrefix("view:") && $0.id != moving.row }?.id
    } else {
      let items = snapshot.itemIdentifiers(inSection: section)
      let roots = Set(items.filter { entries[$0]?.kind == .session && entries[$0]?.row.parentId.isEmpty == true }.map(\.row))
      let family = Set(items.filter { entries[$0]?.row.parentId == moving.row }.map(\.row))
      var index = header == nil ? destination.item : 0
      if header == nil, let row, let cell = collection.cellForItem(at: row) {
        if point.y >= cell.frame.midY { index += 1 }
        if let source = items.firstIndex(of: moving), source < index { index -= 1 }
      }
      before = StatusViewPlanning.beforeId(moving: moving.row, family: family, items: items.map(\.row), roots: roots, index: index)
    }
    guard let command = status.drop(moving.row, section, before) else { return nil }
    return (command, header == nil && !collapsed)
  }
}

// MARK: - Content

/// The status mark a chat shows, matching the web `SessionRowStatusIndicator` and its priority:
/// failed (circle alert, danger) > waiting for permission (hand) > working (grid) > unread (dot).
/// Idle and done chats show nothing. Shared with the conversation's Tabs panel.
enum Attention {
  case failed, waiting, working, unread

  /// A session's mark, as its row in the Chats list shows it.
  init?(_ session: SessionItem) {
    self.init(tint: SessionState(session).tint, unread: SessionRows.needsEmphasis(session))
  }

  init?(tint: String, unread: Bool) {
    switch tint {
    case "danger": self = .failed
    case "warning": self = .waiting
    case "blue": self = .working
    default:
      guard unread else { return nil }
      self = .unread
    }
  }

  /// The web draws a 12 px mark in a 14 px box beside 14 px text.
  static let size = LodyIconSize.xs + LodySpacing.xxs
}

private struct Glyph: View {
  let icon: LodyIcon
  var size: CGFloat = LodyIconSize.md
  var color: Color = LodyColor.iconPrimary

  var body: some View {
    icon.image.resizable().renderingMode(.template).foregroundStyle(color).frame(width: size, height: size)
  }
}

struct AttentionGlyph: View {
  let attention: Attention

  var body: some View {
    switch attention {
    case .failed: Glyph(icon: .alert, size: Attention.size, color: LodyColor.dangerDefault)
    case .waiting: Glyph(icon: .hand, size: Attention.size, color: LodyColor.accentDefault)
    case .working: LodyWorkingGrid(size: Attention.size, color: LodyColor.accentDefault)
    case .unread: Circle().fill(LodyColor.accentDefault).frame(width: LodySize.dot, height: LodySize.dot)
    }
  }
}

private struct GroupHeader: View {
  let row: LodyListRow
  let expanded: Bool?
  let canToggle: Bool
  let onAction: (String) -> Void

  private var icon: LodyIcon {
    switch row.image {
    case "bubble.left": .session
    case "pin.fill": .pin
    default: .folder
    }
  }

  /// The group's own new-chat action, surfaced as the trailing button.
  private var compose: LodyListAction? {
    row.menuActions.first { $0.id == "newSession" || $0.id == "newChat" }
  }

  var body: some View {
    HStack(spacing: LodyLayout.listRowGap) {
      Glyph(icon: icon)
      Text(row.title)
        .lodyTextStyle(.groupLabel)
        .foregroundStyle(LodyColor.textTertiary)
        .lineLimit(1)
      Spacer(minLength: LodySpacing.sm)
      if expanded == false || !canToggle, !row.badge.isEmpty, row.badge != "0" {
        if let attention = Attention(tint: row.imageTint, unread: false) { AttentionGlyph(attention: attention) }
        Text(row.badge)
          .lodyTextStyle(.footnote)
          .foregroundStyle(LodyColor.textTertiary)
          .monospacedDigit()
      }
      if let compose {
        Button { onAction(compose.id) } label: { Glyph(icon: .compose, color: LodyColor.iconSecondary) }
          .buttonStyle(.borderless)
          .frame(width: LodySize.touchTarget, height: LodySize.touchTarget)
          .accessibilityLabel(compose.title)
      } else {
        Color.clear.frame(width: LodySpacing.xs, height: 1)
      }
    }
    .padding(.leading, LodyLayout.listEdgeX)
    .padding(.trailing, LodySpacing.xs)
    .frame(maxWidth: .infinity, minHeight: LodySize.listRow, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.isHeader)
    .accessibilityValue(accessibilityValue)
  }

  private var accessibilityValue: String {
    guard canToggle, let expanded else { return row.badge }
    if expanded { return String(localized: "native.list.expanded", bundle: .lody) }
    let state = String(localized: "native.list.collapsed", bundle: .lody)
    return [state, row.badge].filter { !$0.isEmpty }.joined(separator: ", ")
  }
}

/// Which details a chat row's second line shows. Chosen from the Home view menu and persisted;
/// with none selected (or nothing to show for a row) the row is a single title line.
struct ChatRowDetails: OptionSet, Sendable {
  let rawValue: Int
  static let project = ChatRowDetails(rawValue: 1 << 0)
  static let pullRequest = ChatRowDetails(rawValue: 1 << 1)
  static let branch = ChatRowDetails(rawValue: 1 << 2)
  static let defaults: ChatRowDetails = [.project, .pullRequest]

  private static let key = "homeChatRowDetails"

  static var stored: ChatRowDetails {
    guard UserDefaults.standard.object(forKey: key) != nil else { return defaults }
    return ChatRowDetails(rawValue: UserDefaults.standard.integer(forKey: key))
  }

  static func store(_ value: ChatRowDetails) {
    UserDefaults.standard.set(value.rawValue, forKey: key)
    NotificationCenter.default.post(name: .lodyChatRowDetailsChanged, object: nil)
  }
}

extension Notification.Name {
  static let lodyChatRowDetailsChanged = Notification.Name("LodyChatRowDetailsChanged")
}

/// Line 1: title · status or updated time. Line 2 (aligned with the title): folder or
/// repository mark · project · branch, with the pull request mark trailing.
private struct ChatRowContent: View {
  let row: LodyListRow
  let details: ChatRowDetails
  var owner: WorkspaceMember?
  /// Archived list: the title drops to grey ink so every row reads as archived.
  var muted = false
  /// Set on a row with nested chats: whether they are shown. While folded, a "› 4 opened chats"
  /// line below the row stands for the family; once expanded that line gives way to the children,
  /// the first of which carries the collapse chevron. Parent and child status marks stay trailing.
  var expanded: Bool?
  let onOpen: () -> Void
  var onToggle: () -> Void = {}
  /// Set on an expanded family's first child: its leading chevron folds the family.
  var collapseFamily: (() -> Void)?
  /// Status view reordering for VoiceOver (every drag has an accessible alternative).
  var moveUp: (() -> Void)?
  var moveDown: (() -> Void)?

  private var project: String { details.contains(.project) ? row.place : "" }
  private var branch: String { details.contains(.branch) ? row.branch : "" }
  private var pullRequest: PullRequestMark? { details.contains(.pullRequest) ? PullRequestMark(row.prStatus, ci: row.prCI) : nil }
  /// The detail line needs a project or branch; a PR mark alone stays on the title line, before the age.
  private var hasDetailLine: Bool { !project.isEmpty || !branch.isEmpty }
  private var inlinePullRequest: PullRequestMark? { attention == nil && (snippet != nil || !hasDetailLine) ? pullRequest : nil }

  private var attention: Attention? { Attention(tint: row.imageTint, unread: row.unread) }
  private var nested: Bool { !row.parentId.isEmpty }

  /// Search results keep their match snippet in place of the detail line.
  private var snippet: String? {
    row.wrapSubtitle && !row.subtitle.isEmpty ? row.subtitle : nil
  }

  var body: some View {
    // Reserve separate space for navigation and disclosure; the family target must not
    // consume the opener's bottom padding.
    VStack(alignment: .leading, spacing: 0) {
      if expanded == false {
        // Adjacent SwiftUI buttons arbitrate touch tolerance together. Leaving the
        // opener to UIKit cell selection lets disclosure steal taps above its bounds.
        Button(action: onOpen) {
          content().contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        familyToggle
      } else if let collapseFamily {
        // The leading gutter (chevron) folds the family; the rest of the row opens the child.
        Button(action: onOpen) {
          content(gutter: false).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, Self.childIndent)
        .overlay(alignment: .leading) {
          Button(action: collapseFamily) {
            Color.clear.frame(width: Self.childIndent).contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityHidden(true)
        }
      } else {
        content()
      }
    }
    // A little air between an expanded family and the next conversation; children stay tight.
    .padding(.bottom, nested && row.lastChild ? LodySpacing.sm : 0)
    .backgroundPreferenceValue(ChatRowTitleBounds.self) { anchor in
      GeometryReader { geometry in
        if nested, let anchor, collapseFamily != nil {
          // The first child: the family's collapse chevron sits on the trunk, level with the title.
          let turn = geometry[anchor].midY
          ZStack(alignment: .topLeading) {
            if !row.lastChild {
              Path { path in
                path.move(to: CGPoint(x: Self.railX, y: turn + Self.chevronSize / 2 + LodySpacing.xs))
                path.addLine(to: CGPoint(x: Self.railX, y: geometry.size.height))
              }
              .stroke(LodyColor.borderDefault, style: StrokeStyle(lineWidth: Self.railWidth, lineCap: .round))
            }
            chevron(expanded: true)
              .position(x: Self.railX, y: turn)
          }
        } else if nested, let anchor {
          let turn = geometry[anchor].midY
          Path { path in
            let fork = max(0, turn - LodySpacing.md)
            path.move(to: CGPoint(x: Self.railX, y: 0))
            path.addLine(to: CGPoint(x: Self.railX, y: fork))
            path.addCurve(to: CGPoint(x: ChatRowContent.childIndent - LodySpacing.sm, y: turn),
              control1: CGPoint(x: Self.railX, y: turn - LodyRadius.sm),
              control2: CGPoint(x: Self.railX + LodySpacing.xs, y: turn))
            if !row.lastChild {
              path.move(to: CGPoint(x: Self.railX, y: fork))
              path.addLine(to: CGPoint(x: Self.railX, y: geometry.size.height))
            }
          }
          .stroke(LodyColor.borderDefault, style: StrokeStyle(lineWidth: Self.railWidth, lineCap: .round, lineJoin: .round))
        }
      }
      .allowsHitTesting(false)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel([owner?.name, row.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
    .accessibilityValue(
      [row.badge, project, branch, pullRequest?.label ?? "", familyLabel, row.accessibilityValue].filter { !$0.isEmpty }.joined(separator: ", ")
    )
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { onOpen() }
    .accessibilityActions {
      if let expanded {
        Button(String(localized: String.LocalizationValue(expanded ? "home.tree.collapse" : "home.tree.expand"), bundle: .lody), action: onToggle)
      }
      if let collapseFamily {
        Button(String(localized: "home.tree.collapse", bundle: .lody), action: collapseFamily)
      }
      if let moveUp { Button(String(localized: "home.status.moveUp", bundle: .lody), action: moveUp) }
      if let moveDown { Button(String(localized: "home.status.moveDown", bundle: .lody), action: moveDown) }
    }
  }

  /// `gutter: false` drops the leading inset when the first child's collapse target owns it.
  private func content(gutter: Bool = true) -> some View {
    HStack(alignment: .center, spacing: 0) {
      if nested, gutter { Color.clear.frame(width: Self.childLevel, height: 1) }
      VStack(alignment: .leading, spacing: LodySpacing.xxs) {
        HStack(alignment: .center, spacing: LodySpacing.sm) {
          Text(row.title)
            .lodyTextStyle(nested ? .callout : row.unread ? .bodyEmphasis : .body)
            .fontWeight(nested && row.unread ? .semibold : nil)
            .foregroundStyle(muted ? LodyColor.textTertiary : LodyColor.textPrimary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
          // The text inside sets the stack's baseline, so the PR mark centres on the age.
          if let attention {
            AttentionGlyph(attention: attention).frame(width: LodyIconSize.md, height: LodyIconSize.md)
          } else if inlinePullRequest != nil || !row.value.isEmpty {
            HStack(spacing: LodySpacing.xs) {
              inlinePullRequest?.glyph
              if !row.valueSymbol.isEmpty {
                // The Later countdown: a clock before the time left, in neutral ink.
                Image(systemName: row.valueSymbol)
                  .font(.system(size: 11, weight: .medium))
                  .foregroundStyle(LodyColor.textTertiary)
              }
              if !row.value.isEmpty {
                Text(row.value)
                  .lodyTextStyle(.footnote)
                  .foregroundStyle(LodyColor.textTertiary)
                  .monospacedDigit()
              }
            }
            .fixedSize()
          }
          if let owner { ChatOwnerAvatar(member: owner) }
        }
        .anchorPreference(key: ChatRowTitleBounds.self, value: .bounds) { $0 }
        if let snippet {
          Text(snippet).lodyTextStyle(.footnote).foregroundStyle(LodyColor.textSecondary).lineLimit(2)
        } else if hasDetailLine {
          detailLine
        }
      }
    }
    .padding(.leading, gutter ? LodyLayout.listEdgeX : 0)
    .padding(.trailing, LodyLayout.listEdgeX)
    .padding(.vertical, snippet != nil || hasDetailLine ? LodySpacing.sm : 0)
    .frame(maxWidth: .infinity, minHeight: nested ? LodySize.controlMd : LodySize.listRow, alignment: .leading)
  }

  /// Child count and expanded state for VoiceOver; the toggle is an accessibility action.
  private var familyLabel: String {
    guard let expanded else { return "" }
    let count = String.localizedStringWithFormat(String(localized: "home.tree.count", bundle: .lody), row.childCount)
    let state = String(localized: String.LocalizationValue(expanded ? "home.tree.expanded" : "home.tree.collapsed"), bundle: .lody)
    return count + ", " + state
  }

  /// The family chevron sits at the opener's title edge; the rail runs down its centre.
  private static let chevronSize = LodyIconSize.xs
  private static let railWidth = LodySpacing.xxs / 2
  private static let railX = LodyLayout.listEdgeX + chevronSize / 2
  /// One nesting level: how far a child's title steps in.
  static let childLevel = LodyLayout.childIndent - LodyLayout.screenPaddingX
  /// A nested title's leading edge: the list edge plus one level.
  static let childIndent = LodyLayout.listEdgeX + childLevel

  private func chevron(expanded: Bool) -> some View {
    Image(systemName: "chevron.right")
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(LodyColor.iconSecondary)
      .frame(width: Self.chevronSize, height: Self.chevronSize)
      .rotationEffect(.degrees(expanded ? 90 : 0))
  }

  /// A folded family's line; the whole line expands its children, the opener above opens the chat.
  private var familyToggle: some View {
    Button(action: onToggle) {
      HStack(spacing: LodySpacing.xs) {
        chevron(expanded: false)
        Text(String.localizedStringWithFormat(String(localized: "home.tree.count", bundle: .lody), row.childCount))
          .lodyTextStyle(.footnote)
          .foregroundStyle(LodyColor.textSecondary)
          .monospacedDigit()
        Spacer(minLength: LodySpacing.sm)
        if let status = Attention(tint: row.collapsedImageTint, unread: false) {
          AttentionGlyph(attention: status)
            .frame(width: LodyIconSize.md, height: LodyIconSize.md)
        }
      }
      .padding(.horizontal, LodyLayout.listEdgeX)
      .padding(.vertical, LodySpacing.xs)
      // The child-row height: a full list row left a wide gap below the count line.
      .frame(maxWidth: .infinity, minHeight: LodySize.controlMd, alignment: .topLeading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityHidden(true)
  }

  private var detailLine: some View {
    HStack(spacing: LodySpacing.xs) {
      if !project.isEmpty {
        if row.placeIsRepo {
          RepositoryIcon(repository: row.repository, size: LodyIconSize.xxs)
        } else {
          Glyph(icon: .folder, size: LodyIconSize.xxs, color: LodyColor.iconSecondary)
        }
        Text(project).lodyTextStyle(.footnote).foregroundStyle(LodyColor.textSecondary).lineLimit(1)
      }
      if !branch.isEmpty {
        Glyph(icon: .branch, size: LodyIconSize.xxs, color: LodyColor.iconTertiary)
          .padding(.leading, project.isEmpty ? 0 : LodySpacing.xs)
        Text(branch).lodyTextStyle(.footnote).foregroundStyle(LodyColor.textTertiary).lineLimit(1).truncationMode(.middle)
      }
      Spacer(minLength: LodySpacing.sm)
      pullRequest?.glyph
    }
    .frame(maxWidth: .infinity)
  }
}

private struct ChatRowTitleBounds: PreferenceKey {
  static var defaultValue: Anchor<CGRect>? { nil }
  static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
    value = nextValue() ?? value
  }
}

/// The web `SessionPrIcon` states: open, merged, closed, draft.
private struct PullRequestMark {
  let status: String
  let label: String
  let ci: PullRequestCI?

  var glyph: some View { LodyPullRequestIcon(status: status, ci: ci?.rawValue).fixedSize() }

  init?(_ status: String, ci: String = "") {
    guard ["open", "merged", "closed", "draft"].contains(status) else { return nil }
    self.status = status
    self.ci = PullRequestCI(rawValue: ci)
    let pr = String(localized: String.LocalizationValue("home.pr." + status), bundle: .lody)
    label = self.ci.map { pr + ", " + String(localized: String.LocalizationValue("home.ci." + $0.rawValue), bundle: .lody) } ?? pr
  }
}

private struct MoreRowContent: View {
  let title: String

  var body: some View {
    Text(title)
      .lodyTextStyle(.body)
      .foregroundStyle(LodyColor.textTertiary)
      .padding(.leading, ChatRowContent.childIndent)
      .frame(maxWidth: .infinity, minHeight: LodySize.listRow, alignment: .leading)
      .accessibilityAddTraits(.isButton)
  }
}

/// Home group labels the person collapsed, stored per device by section id. Headers observe it,
/// so a toggle turns the chevron of the label already on screen.
@MainActor
private final class ChatGroupFolds: ObservableObject {
  private static let key = "homeCollapsedGroups"
  /// Groups that start collapsed (Later, Settled) and the person opened.
  private static let expandedKey = "homeExpandedGroups"
  @Published private var collapsed = Set(UserDefaults.standard.stringArray(forKey: ChatGroupFolds.key) ?? [])
  @Published private var expanded = Set(UserDefaults.standard.stringArray(forKey: ChatGroupFolds.expandedKey) ?? [])
  /// Home labels collapse; search labels do not.
  @Published var enabled = true
  /// Archived buckets reuse the activity ids, so they fold separately.
  @Published var scope = ""

  private func startsCollapsed(_ id: String) -> Bool { scope.isEmpty && InboxSections.collapsedByDefault.contains(id) }

  func isCollapsed(_ id: String) -> Bool {
    guard enabled else { return false }
    return startsCollapsed(id) ? !expanded.contains(scope + id) : collapsed.contains(scope + id)
  }

  func toggle(_ id: String) {
    let key = scope + id
    if startsCollapsed(id) {
      if expanded.remove(key) == nil { expanded.insert(key) }
      UserDefaults.standard.set(Array(expanded).sorted(), forKey: Self.expandedKey)
    } else {
      if collapsed.remove(key) == nil { collapsed.insert(key) }
      UserDefaults.standard.set(Array(collapsed).sorted(), forKey: Self.key)
    }
  }
}

private struct SectionTitle: View {
  let text: String
  var repository = ""
  /// Shown beside the label while the group is collapsed.
  var count = ""
  /// The label's ⋯ menu (pin section management).
  var menu: [LodyListAction] = []
  @ObservedObject var folds: ChatGroupFolds
  let groupId: String
  var onMenu: (String) -> Void = { _ in }
  let onToggle: () -> Void

  var body: some View {
    if text.isEmpty {
      Color.clear.frame(height: LodySpacing.sm)
    } else if folds.enabled {
      let collapsed = folds.isCollapsed(groupId)
      HStack(spacing: 0) {
        Button(action: onToggle) {
          label(chevron: collapsed)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(
          [String(localized: String.LocalizationValue(collapsed ? "native.list.collapsed" : "native.list.expanded"), bundle: .lody), collapsed ? count : ""]
            .filter { !$0.isEmpty }.joined(separator: ", ")
        )
        .accessibilityIdentifier("label:" + groupId)
        if !menu.isEmpty { sectionMenu }
      }
    } else {
      label(chevron: nil)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("label:" + groupId)
    }
  }

  private var sectionMenu: some View {
    Menu {
      ForEach(menu, id: \.id) { action in
        Button(role: action.destructive ? .destructive : nil) { onMenu(action.id) } label: {
          Label(action.title, systemImage: action.symbol)
        }
      }
    } label: {
      Image(systemName: "ellipsis")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(LodyColor.iconSecondary)
        .frame(width: LodySize.touchTarget, height: LodySize.touchTarget)
        .contentShape(Rectangle())
    }
    .accessibilityLabel(String(localized: "home.pins.menu", bundle: .lody))
    .accessibilityIdentifier("label-menu:" + groupId)
    .padding(.trailing, LodySpacing.xs)
  }

  /// `chevron` is the collapsed state when the group can fold: pointing down while open, right when collapsed.
  private func label(chevron collapsed: Bool?) -> some View {
    HStack(spacing: LodySpacing.xs) {
      if !repository.isEmpty {
        // The project's logo in its original colours, unlike the muted row marks.
        RepositoryIcon(repository: repository, muted: false)
      }
      Text(text)
        .lodyTextStyle(.groupLabel)
        .foregroundStyle(LodyColor.textTertiary)
      if let collapsed {
        Image(systemName: "chevron.right")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(LodyColor.textTertiary)
          .rotationEffect(.degrees(collapsed ? 0 : 90))
          .animation(LodySpring.snappy, value: collapsed)
          .accessibilityHidden(true)
        if collapsed, !count.isEmpty, count != "0" {
          Text(count)
            .lodyTextStyle(.footnote)
            .foregroundStyle(LodyColor.textTertiary)
            .monospacedDigit()
            .accessibilityHidden(true)
        }
      }
    }
    .padding(.horizontal, LodyLayout.listEdgeX)
    .padding(.top, LodySpacing.xs)
    .padding(.bottom, LodySpacing.xs)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// Compact person identity; shares the native image cache with message avatars.
struct ChatOwnerAvatar: View {
  let member: WorkspaceMember
  @State private var loaded: UIImage?
  @State private var loadedURL: URL?
  private var url: URL? { member.image.flatMap(URL.init(string:)) }
  private var initial: String { String(member.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased() }
  var body: some View {
    Group {
      if let url, loadedURL == url, let loaded {
        Image(uiImage: loaded).resizable().scaledToFill()
      } else {
        Text(initial.isEmpty ? "?" : initial)
          .lodyTextStyle(.caption).foregroundStyle(LodyColor.textSecondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity).background(LodyColor.fillSecondary)
      }
    }
    .frame(width: LodyIconSize.md, height: LodyIconSize.md).clipShape(Circle())
    .accessibilityLabel(member.name)
    .task(id: url) {
      guard let url else { return }
      if let image = LodyListPhoto.image(for: url, shape: .original, ready: { image in
        loadedURL = url; loaded = image
      }) { loadedURL = url; loaded = image }
    }
  }
}
