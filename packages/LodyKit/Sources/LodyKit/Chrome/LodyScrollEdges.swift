import UIKit

/// Native scroll owners configure UIKit directly.
@MainActor
enum LodyScrollEdges {
  static let ownerChanged = Notification.Name("LodyContentScrollViewChanged")

  static func bind(_ scrollView: UIScrollView, to owner: UIViewController) {
    guard owner.contentScrollView(for: .top) !== scrollView ||
      owner.contentScrollView(for: .bottom) !== scrollView else { return }
    owner.setContentScrollView(scrollView, for: .top)
    owner.setContentScrollView(scrollView, for: .bottom)
    NotificationCenter.default.post(name: ownerChanged, object: owner)
  }

  static func unbind(_ scrollView: UIScrollView, from owner: UIViewController) {
    var changed = false
    for edge in [NSDirectionalRectEdge.top, .bottom] where owner.contentScrollView(for: edge) === scrollView {
      owner.setContentScrollView(nil, for: edge)
      changed = true
    }
    if changed { NotificationCenter.default.post(name: ownerChanged, object: owner) }
  }

  static func navigation(_ scrollView: UIScrollView) {
    guard #available(iOS 26.0, *) else { return }
    scrollView.topEdgeEffect.isHidden = false
    scrollView.topEdgeEffect.style = .soft
    floatingControls(scrollView)
  }

  static func chat(_ scrollView: UIScrollView) {
    guard #available(iOS 26.0, *) else { return }
    scrollView.topEdgeEffect.isHidden = false
    scrollView.topEdgeEffect.style = .soft
    scrollView.bottomEdgeEffect.isHidden = true
  }

  static func grouped(_ scrollView: UIScrollView) {
    navigation(scrollView)
  }

  static func floatingControls(_ scrollView: UIScrollView) {
    guard #available(iOS 26.0, *) else { return }
    scrollView.bottomEdgeEffect.isHidden = false
    scrollView.bottomEdgeEffect.style = .soft
  }

  /// Systems before iOS 26 have no soft scroll edges.
  static func setEdgesHidden(_ scrollView: UIScrollView?, top: Bool? = nil, bottom: Bool? = nil) {
    guard #available(iOS 26.0, *), let scrollView else { return }
    if let top { scrollView.topEdgeEffect.isHidden = top }
    if let bottom { scrollView.bottomEdgeEffect.isHidden = bottom }
  }

  /// Lets UIKit shape the soft edge of `scrollView` around a floating `container`.
  static func shape(_ container: UIView, around scrollView: UIScrollView?, edge: UIRectEdge) {
    guard #available(iOS 26.0, *) else { return }
    let existing = container.interactions.compactMap { $0 as? UIScrollEdgeElementContainerInteraction }.first
    guard scrollView != nil || existing != nil else { return }
    let interaction = existing ?? UIScrollEdgeElementContainerInteraction()
    interaction.scrollView = scrollView
    interaction.edge = edge
    if interaction.view == nil { container.addInteraction(interaction) }
  }
}
