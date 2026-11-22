import UIKit

extension UIView {
  /// `UIView.animate(springDuration:bounce:)` is iOS 17. Earlier systems use
  /// the damping-based spring API; a zero bounce maps to a critical damp.
  static func lodySpring(
    duration: TimeInterval,
    bounce: CGFloat,
    initialSpringVelocity: CGFloat = 0,
    delay: TimeInterval = 0,
    options: UIView.AnimationOptions = [],
    animations: @escaping () -> Void,
    completion: ((Bool) -> Void)? = nil
  ) {
    if #available(iOS 17.0, *) {
      animate(springDuration: duration, bounce: bounce, initialSpringVelocity: initialSpringVelocity,
              delay: delay, options: options, animations: animations, completion: completion)
    } else {
      animate(withDuration: duration, delay: delay,
              usingSpringWithDamping: max(0.01, 1 - bounce), initialSpringVelocity: initialSpringVelocity,
              options: options, animations: animations, completion: completion)
    }
  }
}
