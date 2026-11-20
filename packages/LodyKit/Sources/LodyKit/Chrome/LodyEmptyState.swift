import UIKit

/// Cross-system model for empty, loading and failure placeholders. The
/// controller helpers render it as `UIContentUnavailableConfiguration` on
/// iOS 17+ and as `LodyEmptyStateView` below; manually managed sites use
/// `LodyEmptyStateView`, which hosts the system view on iOS 17+.
struct LodyEmptyConfiguration {
  var image: UIImage?
  var text: String?
  var secondaryText: String?
  /// `nil` keeps the system text style for the empty or loading state.
  var textFont: UIFont?
  var textColor: UIColor?
  var button = Self.defaultButton(secondary: false)
  var secondaryButton = Self.defaultButton(secondary: true)
  var buttonAction: (@MainActor () -> Void)?
  var secondaryButtonAction: (@MainActor () -> Void)?
  var loading = false
  var backgroundColor: UIColor?

  /// The system's own button styles on iOS 17+ (identical for the empty and
  /// loading states); earlier systems use the closest public styles.
  private static func defaultButton(secondary: Bool) -> UIButton.Configuration {
    if #available(iOS 17.0, *) {
      let empty = UIContentUnavailableConfiguration.empty()
      return secondary ? empty.secondaryButton : empty.button
    }
    return secondary ? .plain() : .gray()
  }

  @available(iOS 17.0, *)
  func system() -> UIContentUnavailableConfiguration {
    var configuration = loading ? UIContentUnavailableConfiguration.loading() : .empty()
    if !loading { configuration.image = image }
    configuration.text = text
    configuration.secondaryText = secondaryText
    if let textFont { configuration.textProperties.font = textFont }
    if let textColor { configuration.textProperties.color = textColor }
    configuration.button = button
    configuration.secondaryButton = secondaryButton
    if let buttonAction {
      configuration.buttonProperties.primaryAction = UIAction { _ in
        MainActor.assumeIsolated { buttonAction() }
      }
    }
    if let secondaryButtonAction {
      configuration.secondaryButtonProperties.primaryAction = UIAction { _ in
        MainActor.assumeIsolated { secondaryButtonAction() }
      }
    }
    if let backgroundColor {
      configuration.background.backgroundColor = backgroundColor
    }
    return configuration
  }
}

/// Placeholder view for manually managed sites. iOS 17+ hosts
/// `UIContentUnavailableView`; earlier systems draw a symbol or spinner, title,
/// message and up to two actions in a stack centered inside the view, which
/// its host sizes to the covered area.
final class LodyEmptyStateView: UIView {
  var configuration: LodyEmptyConfiguration { didSet { apply() } }

  private let stack = UIStackView()
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let symbol = UIImageView()
  private let title = UILabel()
  private let message = UILabel()
  private let action = UIButton(type: .system)
  private let secondaryAction = UIButton(type: .system)

  /// iOS 17+ hosts the system view so every site keeps its native rendering.
  private var systemView: UIView?

  init(configuration: LodyEmptyConfiguration = .init()) {
    self.configuration = configuration
    super.init(frame: .zero)
    if #available(iOS 17.0, *) {
      let system = UIContentUnavailableView(configuration: configuration.system())
      system.translatesAutoresizingMaskIntoConstraints = false
      addSubview(system)
      NSLayoutConstraint.activate([
        system.topAnchor.constraint(equalTo: topAnchor),
        system.leadingAnchor.constraint(equalTo: leadingAnchor),
        system.trailingAnchor.constraint(equalTo: trailingAnchor),
        system.bottomAnchor.constraint(equalTo: bottomAnchor),
      ])
      systemView = system
      return
    }
    symbol.contentMode = .scaleAspectFit
    symbol.tintColor = .secondaryLabel
    symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 40)
    title.textAlignment = .center
    title.numberOfLines = 0
    title.adjustsFontForContentSizeCategory = true
    message.textAlignment = .center
    message.numberOfLines = 0
    message.adjustsFontForContentSizeCategory = true
    message.font = .preferredFont(forTextStyle: .subheadline)
    message.textColor = .secondaryLabel
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = 12
    for view in [spinner, symbol, title, message, action, secondaryAction] {
      stack.addArrangedSubview(view)
    }
    stack.setCustomSpacing(6, after: title)
    stack.setCustomSpacing(20, after: message)
    stack.setCustomSpacing(8, after: action)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
      stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 16),
      stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16),
      symbol.widthAnchor.constraint(lessThanOrEqualToConstant: 80),
      symbol.heightAnchor.constraint(lessThanOrEqualToConstant: 80),
      title.widthAnchor.constraint(equalTo: stack.widthAnchor),
      message.widthAnchor.constraint(equalTo: stack.widthAnchor),
    ])
    action.addTarget(self, action: #selector(primaryTapped), for: .primaryActionTriggered)
    secondaryAction.addTarget(self, action: #selector(secondaryTapped), for: .primaryActionTriggered)
    apply()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private static func defaultTitleFont(loading: Bool) -> UIFont {
    if loading { return .preferredFont(forTextStyle: .subheadline) }
    let title = UIFont.preferredFont(forTextStyle: .title2)
    return title.fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: 0) } ?? title
  }

  @objc private func primaryTapped() { configuration.buttonAction?() }
  @objc private func secondaryTapped() { configuration.secondaryButtonAction?() }

  private func apply() {
    if #available(iOS 17.0, *), let system = systemView as? UIContentUnavailableView {
      system.configuration = configuration.system()
      return
    }
    backgroundColor = configuration.backgroundColor
    spinner.isHidden = !configuration.loading
    if configuration.loading { spinner.startAnimating() } else { spinner.stopAnimating() }
    symbol.isHidden = configuration.loading || configuration.image == nil
    symbol.image = configuration.image
    title.isHidden = (configuration.text ?? "").isEmpty
    title.text = configuration.text
    // Matches the system defaults: a bold title for empty states, secondary
    // body text while loading.
    title.font = configuration.textFont ?? Self.defaultTitleFont(loading: configuration.loading)
    title.textColor = configuration.textColor ?? (configuration.loading ? .secondaryLabel : .label)
    message.isHidden = (configuration.secondaryText ?? "").isEmpty
    message.text = configuration.secondaryText
    action.isHidden = (configuration.button.title ?? "").isEmpty
    action.configuration = configuration.button
    secondaryAction.isHidden = (configuration.secondaryButton.title ?? "").isEmpty
    secondaryAction.configuration = configuration.secondaryButton
  }
}

nonisolated(unsafe) private var lodyEmptyStateViewKey: UInt8 = 0
nonisolated(unsafe) private var lodyEmptyStateConfigKey: UInt8 = 0

extension UIViewController {
  /// Assigns a `UIContentUnavailableConfiguration` on iOS 17+; on earlier
  /// systems covers `view` with a `LodyEmptyStateView`. `nil` clears the state.
  var lodyContentUnavailable: LodyEmptyConfiguration? {
    get { objc_getAssociatedObject(self, &lodyEmptyStateConfigKey) as? LodyEmptyConfiguration }
    set {
      objc_setAssociatedObject(self, &lodyEmptyStateConfigKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
      if #available(iOS 17.0, *) {
        contentUnavailableConfiguration = newValue?.system()
        return
      }
      let stored = objc_getAssociatedObject(self, &lodyEmptyStateViewKey) as? LodyEmptyStateView
      if let newValue {
        let unavailable = stored ?? LodyEmptyStateView()
        unavailable.configuration = newValue
        if unavailable.superview == nil {
          unavailable.translatesAutoresizingMaskIntoConstraints = false
          view.addSubview(unavailable)
          // Edge constraints on a scroll view act on its content size; the
          // frame guide keeps the state covering the visible area instead.
          if let scroll = view as? UIScrollView {
            let frame = scroll.frameLayoutGuide
            NSLayoutConstraint.activate([
              unavailable.topAnchor.constraint(equalTo: frame.topAnchor),
              unavailable.leadingAnchor.constraint(equalTo: frame.leadingAnchor),
              unavailable.trailingAnchor.constraint(equalTo: frame.trailingAnchor),
              unavailable.bottomAnchor.constraint(equalTo: frame.bottomAnchor),
            ])
          } else {
            NSLayoutConstraint.activate([
              unavailable.topAnchor.constraint(equalTo: view.topAnchor),
              unavailable.leadingAnchor.constraint(equalTo: view.leadingAnchor),
              unavailable.trailingAnchor.constraint(equalTo: view.trailingAnchor),
              unavailable.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
          }
        }
        // Like the system overlay, the state covers content added after it.
        view.bringSubviewToFront(unavailable)
        objc_setAssociatedObject(self, &lodyEmptyStateViewKey, unavailable, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
      } else {
        stored?.removeFromSuperview()
        objc_setAssociatedObject(self, &lodyEmptyStateViewKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
      }
    }
  }
}
