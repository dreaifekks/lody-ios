import UIKit

extension UICollectionView {
  func deselectOnReturn(animated: Bool, coordinator: UIViewControllerTransitionCoordinator?) {
    guard let selected = indexPathsForSelectedItems, !selected.isEmpty else { return }
    guard let coordinator else {
      selected.forEach { deselectItem(at: $0, animated: animated) }
      return
    }
    let started = coordinator.animate(alongsideTransition: { [weak self] _ in
      selected.forEach { self?.deselectItem(at: $0, animated: animated) }
    }, completion: { [weak self] context in
      guard context.isCancelled, let self else { return }
      for path in selected where path.section < numberOfSections && path.item < numberOfItems(inSection: path.section) {
        selectItem(at: path, animated: false, scrollPosition: [])
      }
    })
    if !started { selected.forEach { deselectItem(at: $0, animated: animated) } }
  }

  func clearSelection(animated: Bool) {
    indexPathsForSelectedItems?.forEach { deselectItem(at: $0, animated: animated) }
  }
}
