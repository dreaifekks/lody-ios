import SwiftUI
import UIKit

/// Liquid Glass on iOS 26 and later; the system thin material before it.
@MainActor
enum LodyGlass {
  static func effect(interactive: Bool = false) -> UIVisualEffect {
    guard #available(iOS 26.0, *) else { return UIBlurEffect(style: .systemThinMaterial) }
    let glass = UIGlassEffect(style: .regular)
    glass.isInteractive = interactive
    return glass
  }

  /// Merges neighbouring glass surfaces on iOS 26; earlier systems draw each material alone.
  static func containerEffect(spacing: CGFloat? = nil) -> UIVisualEffect? {
    guard #available(iOS 26.0, *) else { return nil }
    let container = UIGlassContainerEffect()
    if let spacing { container.spacing = spacing }
    return container
  }
}

enum LodyCorners: Equatable {
  case fixed(CGFloat)
  case capsule(maximum: CGFloat? = nil)
  case top(CGFloat)
}

private final class LodyCapsuleCorners: NSObject {
  var observation: NSKeyValueObservation?
}

@MainActor private var capsuleCornersKey: UInt8 = 0

extension UIView {
  /// `cornerConfiguration` on iOS 26; a continuous layer radius (tracking capsules) before it.
  func lodySetCorners(_ corners: LodyCorners) {
    if #available(iOS 26.0, *) {
      switch corners {
      case .fixed(let radius): cornerConfiguration = .corners(radius: .fixed(radius))
      case .capsule(let maximum): cornerConfiguration = maximum.map { .capsule(maximumRadius: $0) } ?? .capsule()
      case .top(let radius):
        let top = UICornerRadius.fixed(radius)
        cornerConfiguration = .corners(topLeftRadius: top, topRightRadius: top, bottomLeftRadius: .fixed(0), bottomRightRadius: .fixed(0))
      }
      return
    }
    layer.cornerCurve = .continuous
    if self is UIVisualEffectView { clipsToBounds = true }
    layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
    objc_setAssociatedObject(self, &capsuleCornersKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    switch corners {
    case .fixed(let radius): layer.cornerRadius = radius
    case .top(let radius):
      layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
      layer.cornerRadius = radius
    case .capsule(let maximum):
      let tracker = LodyCapsuleCorners()
      tracker.observation = layer.observe(\.bounds, options: [.initial, .new]) { layer, _ in
        let radius = min(layer.bounds.width, layer.bounds.height) / 2
        layer.cornerRadius = min(radius, maximum ?? radius)
      }
      objc_setAssociatedObject(self, &capsuleCornersKey, tracker, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
  }
}

extension UIButton.Configuration {
  /// `glass()` on iOS 26; a gray capsule before it.
  static func lodyGlass() -> UIButton.Configuration {
    if #available(iOS 26.0, *) { return .glass() }
    var configuration = UIButton.Configuration.gray()
    configuration.cornerStyle = .capsule
    return configuration
  }

  /// `prominentGlass()` on iOS 26; a filled capsule before it.
  static func lodyProminentGlass() -> UIButton.Configuration {
    if #available(iOS 26.0, *) { return .prominentGlass() }
    var configuration = UIButton.Configuration.filled()
    configuration.cornerStyle = .capsule
    return configuration
  }
}

extension UIBarButtonItem.Style {
  /// `.prominent` on iOS 26; `.done` before it.
  static var lodyProminent: UIBarButtonItem.Style {
    if #available(iOS 26.0, *) { return .prominent }
    return .done
  }
}

extension View {
  /// `glassEffect` on iOS 26; the thin material in the same shape before it.
  @ViewBuilder
  func lodyGlass(interactive: Bool = false, in shape: some Shape) -> some View {
    if #available(iOS 26.0, *) {
      glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
    } else {
      background(.thinMaterial, in: shape)
    }
  }

  /// The glass button style on iOS 26; bordered before it.
  @ViewBuilder
  func lodyGlassButtonStyle() -> some View {
    if #available(iOS 26.0, *) {
      buttonStyle(.glass)
    } else {
      buttonStyle(.bordered)
    }
  }
}

/// `GlassEffectContainer` on iOS 26; the content alone before it.
struct LodyGlassGroup<Content: View>: View {
  var spacing: CGFloat?
  @ViewBuilder var content: Content

  var body: some View {
    if #available(iOS 26.0, *) {
      GlassEffectContainer(spacing: spacing) { content }
    } else {
      content
    }
  }
}
