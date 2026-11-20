import LodyDesignSystem
import UIKit

/// iPhone Home's top-level destinations. iPad keeps the split view and does not show tabs.
enum HomeTab: CaseIterable, Sendable {
  case chats, schedules, settings

  var icon: LodyIcon {
    switch self {
    case .chats: .sessions
    case .schedules: .clock
    case .settings: .settings
    }
  }

  var title: String {
    switch self {
    case .chats: String(localized: "home.tab.chats", bundle: .lody)
    case .schedules: String(localized: "schedules.title", bundle: .lody)
    case .settings: String(localized: "tabs.settings", bundle: .lody)
    }
  }
}

/// UIKit owns tab layout, minimization and the selected icon throughout each transition.
@MainActor
final class HomeTabsController: UITabBarController, UITabBarControllerDelegate {
  var onSelect: (HomeTab) -> Void = { _ in }
  var onCreate: () -> Void = {}
  var onDebug: () -> Void = {}
  var canCreate = false {
    didSet {
      floatingCreate?.isEnabled = canCreate
      if #available(iOS 18.4, *) { tab(forIdentifier: Self.createID)?.isEnabled = canCreate }
    }
  }
  private static let createID = "home-new-session"
  private var homeTabs: [UITab] = []
  /// Before iOS 26 the create action floats above the tab bar's trailing edge instead of taking a tab.
  private lazy var floatingCreate: UIButton? = Self.makeFloatingCreate()
  private static let floatingSize: CGFloat = 56
  private static let floatingMargin: CGFloat = 16

  private static func makeFloatingCreate() -> UIButton? {
    if #available(iOS 26.0, *) { return nil }
    var configuration = UIButton.Configuration.lodyProminent()
    configuration.image = LodyIcon.compose.uiImage?.withRenderingMode(.alwaysTemplate)
    configuration.cornerStyle = .capsule
    let button = UIButton(configuration: configuration)
    button.accessibilityIdentifier = createID
    button.isEnabled = false
    button.layer.shadowColor = UIColor.black.cgColor
    button.layer.shadowOpacity = 0.18
    button.layer.shadowRadius = 8
    button.layer.shadowOffset = CGSize(width: 0, height: 3)
    return button
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    delegate = self
    mode = .tabBar
    if #available(iOS 26.0, *) { tabBarMinimizeBehavior = .onScrollDown }
    tabBar.tintColor = LodyUIColor.accentFg
    tabBar.unselectedItemTintColor = LodyUIColor.iconSecondary
    tabBar.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:))))
    if let floatingCreate {
      floatingCreate.addAction(UIAction { [weak self] _ in
        guard let self, self.canCreate else { return }
        self.onCreate()
      }, for: .primaryActionTriggered)
      floatingCreate.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(floatingCreate)
      NSLayoutConstraint.activate([
        floatingCreate.widthAnchor.constraint(equalToConstant: Self.floatingSize),
        floatingCreate.heightAnchor.constraint(equalToConstant: Self.floatingSize),
        floatingCreate.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -Self.floatingMargin),
        floatingCreate.bottomAnchor.constraint(equalTo: tabBar.topAnchor, constant: -Self.floatingMargin),
      ])
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // UIKit inserts the selected tab's view on each switch; keep the action above it.
    if let floatingCreate { view.bringSubviewToFront(floatingCreate) }
  }

  func install(navigation: @escaping (HomeTab) -> UINavigationController) {
    // Restore roots moved into the regular-width detail column even when UIKit has
    // already resolved a tab's provider. Each navigation keeps its original UITab.
    let navigations = HomeTab.allCases.map { ($0, navigation($0)) }
    if homeTabs.isEmpty {
      homeTabs = navigations.map { destination, controller in
        let tab = UITab(title: destination.title, image: destination.icon.uiImage,
          identifier: "home-tab-\(destination)") { _ in controller }
        tab.accessibilityIdentifier = tab.identifier
        return tab
      }
      if floatingCreate == nil {
        let create = UITab(title: String(localized: "tabs.newSession", bundle: .lody), image: LodyIcon.compose.uiImage,
          identifier: Self.createID) { _ in UIViewController() }
        create.accessibilityIdentifier = Self.createID
        homeTabs.append(create)
      }
    }
    // Lists keep their last rows clear of the floating create action.
    if floatingCreate != nil {
      for (destination, controller) in navigations {
        controller.additionalSafeAreaInsets.bottom = destination == .settings ? 0 : Self.floatingSize + Self.floatingMargin
      }
    }
    tabs = homeTabs
    // iOS 27 supports a separate prominent action without misrepresenting it as Search.
    if #available(iOS 27.0, *) { prominentTabIdentifier = Self.createID }
  }

  func show(_ destination: HomeTab) {
    selectedTab = tab(forIdentifier: "home-tab-\(destination)")
    if #available(iOS 26.0, *) { tabBarMinimizeBehavior = destination == .chats ? .onScrollDown : .never }
    updateCreate(destination)
  }

  /// The create action keeps the compose glyph; on Schedules it adds a schedule, elsewhere it starts a chat.
  private func updateCreate(_ destination: HomeTab) {
    let title = String(localized: String.LocalizationValue(destination == .schedules ? "schedules.new" : "tabs.newSession"), bundle: .lody)
    tab(forIdentifier: Self.createID)?.title = title
    floatingCreate?.accessibilityLabel = title
    floatingCreate?.isHidden = destination == .settings
  }

  func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
    if tab.identifier == Self.createID { if canCreate { onCreate() }; return false }
    return true
  }

  func tabBarController(_ tabBarController: UITabBarController, didSelectTab selectedTab: UITab, previousTab: UITab?) {
    guard let destination = HomeTab.allCases.first(where: { selectedTab.identifier == "home-tab-\($0)" }) else { return }
    if #available(iOS 26.0, *) { tabBarMinimizeBehavior = destination == .chats ? .onScrollDown : .never }
    updateCreate(destination)
    onSelect(destination)
  }

  @objc private func longPressed(_ gesture: UILongPressGestureRecognizer) {
    guard gesture.state == .began, selectedTab?.identifier == "home-tab-settings" else { return }
    onDebug()
  }
}

/// The split view needs a navigation host to push its detail on compact width.
/// The tabs already own navigation bars; hide the outer bar whenever they return.
@MainActor
final class HomeCompactNavigation: UINavigationController, UINavigationControllerDelegate {
  override func viewDidLoad() {
    super.viewDidLoad()
    delegate = self
    PageHeaderPopGestureDelegate.install(on: self)
  }

  func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
    PageHeaderPopGestureDelegate.install(on: self)
  }

  func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
    let page = (viewController as? UINavigationController)?.topViewController ?? viewController
    setNavigationBarHidden(viewController is HomeTabsController || (page as? LodyPageController)?.ownsHeader == true, animated: animated)
  }
}
