import ObjectiveC
import UIKit

/// The traits Lody observes. iOS 17+ registers the matching `UITrait`s with
/// `registerForTraitChanges`; earlier systems compare them in
/// `traitCollectionDidChange`.
enum LodyTrait {
  case userInterfaceStyle, accessibilityContrast, preferredContentSizeCategory, horizontalSizeClass, displayScale

  @available(iOS 17.0, *)
  var system: UITrait {
    switch self {
    case .userInterfaceStyle: UITraitUserInterfaceStyle.self
    case .accessibilityContrast: UITraitAccessibilityContrast.self
    case .preferredContentSizeCategory: UITraitPreferredContentSizeCategory.self
    case .horizontalSizeClass: UITraitHorizontalSizeClass.self
    case .displayScale: UITraitDisplayScale.self
    }
  }

  func changed(from previous: UITraitCollection?, to current: UITraitCollection) -> Bool {
    guard let previous else { return true }
    switch self {
    case .userInterfaceStyle: return previous.userInterfaceStyle != current.userInterfaceStyle
    case .accessibilityContrast: return previous.accessibilityContrast != current.accessibilityContrast
    case .preferredContentSizeCategory: return previous.preferredContentSizeCategory != current.preferredContentSizeCategory
    case .horizontalSizeClass: return previous.horizontalSizeClass != current.horizontalSizeClass
    case .displayScale: return previous.displayScale != current.displayScale
    }
  }
}

private final class LodyTraitHandler {
  let traits: [LodyTrait]
  let fire: (NSObject, UITraitCollection) -> Void

  init(traits: [LodyTrait], fire: @escaping (NSObject, UITraitCollection) -> Void) {
    self.traits = traits
    self.fire = fire
  }
}

nonisolated(unsafe) private var lodyTraitHandlersKey: UInt8 = 0

/// Pre-iOS 17 dispatch. UIView and UIViewController each implement
/// `traitCollectionDidChange:`, so each class's own method gets a block that
/// calls that class's original implementation and then the handlers.
private enum LodyTraitChangeDispatcher {
  static let install: Void = {
    typealias Original = @convention(c) (NSObject, Selector, UITraitCollection?) -> Void
    let selector = #selector(UITraitEnvironment.traitCollectionDidChange(_:))
    for klass in [UIView.self, UIViewController.self] as [AnyClass] {
      guard let method = class_getInstanceMethod(klass, selector) else { continue }
      let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
      let replacement: @convention(block) (NSObject, UITraitCollection?) -> Void = { object, previous in
        original(object, selector, previous)
        dispatch(object, previous: previous)
      }
      let implementation = imp_implementationWithBlock(replacement)
      if !class_addMethod(klass, selector, implementation, method_getTypeEncoding(method)) {
        method_setImplementation(method, implementation)
      }
    }
  }()

  private static func dispatch(_ object: NSObject, previous: UITraitCollection?) {
    guard let handlers = objc_getAssociatedObject(object, &lodyTraitHandlersKey) as? [LodyTraitHandler],
          let current = (object as? UITraitEnvironment)?.traitCollection else { return }
    for handler in handlers where handler.traits.contains(where: { $0.changed(from: previous, to: current) }) {
      handler.fire(object, previous ?? current)
    }
  }

  static func append(_ handler: LodyTraitHandler, to environment: NSObject) {
    _ = install
    let handlers = (objc_getAssociatedObject(environment, &lodyTraitHandlersKey) as? [LodyTraitHandler]) ?? []
    objc_setAssociatedObject(environment, &lodyTraitHandlersKey, handlers + [handler], .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
  }
}

extension UITraitEnvironment where Self: NSObject {
  /// `registerForTraitChanges(_:handler:)` on iOS 17+; earlier systems run the
  /// handler from `traitCollectionDidChange` when a listed trait changed. The
  /// handler receives the previous trait collection on every system.
  /// Subclasses that override `traitCollectionDidChange` must call `super`.
  func lodyObserveTraitChanges(_ traits: [LodyTrait], handler: @escaping (Self, UITraitCollection) -> Void) {
    if #available(iOS 17.0, *), let observable = self as? any UITraitChangeObservable {
      observable.registerForTraitChanges(traits.map(\.system)) { (environment: Self, previous: UITraitCollection) in
        handler(environment, previous)
      }
      return
    }
    LodyTraitChangeDispatcher.append(LodyTraitHandler(traits: traits) { object, previous in
      guard let environment = object as? Self else { return }
      handler(environment, previous)
    }, to: self)
  }

  /// Selector form for `registerForTraitChanges(_:action:)` sites; the action takes no arguments.
  func lodyObserveTraitChanges(_ traits: [LodyTrait], action: Selector) {
    if #available(iOS 17.0, *), let observable = self as? any UITraitChangeObservable {
      observable.registerForTraitChanges(traits.map(\.system), action: action)
      return
    }
    LodyTraitChangeDispatcher.append(LodyTraitHandler(traits: traits) { object, _ in
      if object.responds(to: action) { object.perform(action) }
    }, to: self)
  }
}
