import LodyDesignSystem
import UIKit

/// Reports each finished layout pass. `scrollViewDidScroll` runs before UIKit moves a pinned
/// header, so geometry compared against the current offset must be read from here.
final class ChatListCollectionView: UICollectionView {
  var onLayout: (() -> Void)?

  override func layoutSubviews() {
    super.layoutSubviews()
    onLayout?()
  }

  /// A label's ⋯ menu keeps its 44 pt target although it overhangs the compact label, ahead of
  /// the rows and spacing it overlaps.
  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard self.point(inside: point, with: event) else { return nil }
    for case let header as ChatSectionHeaderCell in visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionHeader) {
      let button = header.menuButton
      guard !header.isHidden, !button.isHidden, button.bounds.contains(button.convert(point, from: self)) else { continue }
      return button
    }
    return super.hitTest(point, with: event)
  }
}

/// A group label. A pin section's ⋯ menu is a UIKit button centred on the label, so its full touch
/// target does not set the label's height.
final class ChatSectionHeaderCell: UICollectionViewListCell {
  let menuButton = UIButton(type: .system)

  override init(frame: CGRect) {
    super.init(frame: frame)
    menuButton.setImage(UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)), for: .normal)
    menuButton.tintColor = LodyUIColor.iconSecondary
    menuButton.showsMenuAsPrimaryAction = true
    menuButton.accessibilityLabel = String(localized: "home.pins.menu", bundle: .lody)
    menuButton.isHidden = true
    addSubview(menuButton)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  func setMenu(_ actions: [LodyListAction], groupId: String, onAction: @escaping (String) -> Void) {
    menuButton.isHidden = actions.isEmpty
    menuButton.accessibilityIdentifier = "label-menu:" + groupId
    menuButton.menu = actions.isEmpty ? nil : UIMenu(children: actions.map { action in
      UIAction(
        title: action.title, image: UIImage(systemName: action.symbol),
        attributes: action.destructive ? .destructive : []
      ) { _ in onAction(action.id) }
    })
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let size = LodySize.touchTarget
    menuButton.frame = CGRect(x: bounds.maxX - LodySpacing.xs - size, y: bounds.midY - size / 2, width: size, height: size)
    bringSubviewToFront(menuButton)
  }
}
