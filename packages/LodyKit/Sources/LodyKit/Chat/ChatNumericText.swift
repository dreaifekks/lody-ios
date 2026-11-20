import SwiftUI
import UIKit

final class ChatNumericTextModel: ObservableObject {
  @Published var attributed = AttributedString()
  @Published var value = ""
  @Published var shines = false
  @Published var color = Color.primary
}

struct ChatNumericTextBridge: View {
  @ObservedObject var model: ChatNumericTextModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !model.shines || reduceMotion)) { context in
      let period = 1.5
      let progress = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
      let highlight = model.shines && !reduceMotion ? model.color.lodyMixed(with: .white, by: 0.64) : model.color
      Text(model.attributed)
        .foregroundStyle(LinearGradient(
          stops: [
            .init(color: model.color, location: 0.25),
            .init(color: highlight, location: 0.5),
            .init(color: model.color, location: 0.75),
          ],
          startPoint: UnitPoint(x: -1 + 2 * progress, y: 0),
          endPoint: UnitPoint(x: 2 * progress, y: 0)
        ))
        .multilineTextAlignment(.leading)
        .contentTransition(.numericText())
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
  }
}

final class ChatNumericTextHost: UIView {
  private let model: ChatNumericTextModel
  private let hosting: UIHostingController<ChatNumericTextBridge>

  override init(frame: CGRect) {
    let model = ChatNumericTextModel()
    self.model = model
    hosting = UIHostingController(rootView: ChatNumericTextBridge(model: model))
    super.init(frame: frame)
    hosting.safeAreaRegions = []
    hosting.sizingOptions = []
    hosting.view.backgroundColor = .clear
    hosting.view.isOpaque = false
    hosting.view.insetsLayoutMarginsFromSafeArea = false
    hosting.view.isUserInteractionEnabled = false
    hosting.view.isAccessibilityElement = false
    hosting.view.accessibilityElementsHidden = true
    clipsToBounds = true
    isUserInteractionEnabled = false
    isAccessibilityElement = false
    accessibilityElementsHidden = true
    addSubview(hosting.view)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func apply(text: NSAttributedString, animated: Bool, shines: Bool) {
    let styled = NSMutableAttributedString(attributedString: text)
    let color = text.length > 0 ? text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor : nil
    styled.removeAttribute(.foregroundColor, range: NSRange(location: 0, length: styled.length))
    let attributed = AttributedString(styled)
    let value = text.string
    let update = {
      self.model.attributed = attributed
      self.model.value = value
      self.model.shines = shines
      self.model.color = Color(uiColor: color ?? .label)
    }
    let motion = animated
      && window != nil
      && !value.isEmpty
      && !model.value.isEmpty
      && model.value != value
      && !UIAccessibility.isReduceMotionEnabled
    if motion {
      withAnimation(.default, update)
    } else {
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction, update)
    }
  }

  func reset() {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      model.attributed = AttributedString()
      model.value = ""
      model.shines = false
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    hosting.view.frame = bounds
  }

  override func sizeThatFits(_ size: CGSize) -> CGSize {
    hosting.sizeThatFits(
      in: CGSize(width: max(1, size.width), height: UIView.layoutFittingExpandedSize.height)
    )
  }
}

private extension Color {
  /// `Color.mix` is iOS 18; earlier systems blend in UIColor space.
  func lodyMixed(with other: Color, by fraction: Double) -> Color {
    if #available(iOS 18.0, *) { return mix(with: other, by: fraction) }
    let base = UIColor(self)
    let overlay = UIColor(other)
    var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
    var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
    base.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
    overlay.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
    return Color(UIColor(
      red: r1 + (r2 - r1) * fraction,
      green: g1 + (g2 - g1) * fraction,
      blue: b1 + (b2 - b1) * fraction,
      alpha: a1 + (a2 - a1) * fraction))
  }
}
