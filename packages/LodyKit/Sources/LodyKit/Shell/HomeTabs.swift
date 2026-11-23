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
      guard canCreate != oldValue else { return }
      floatingCreate?.isEnabled = canCreate
      if #available(iOS 18.4, *) { tab(forIdentifier: createTabIdentifier)?.isEnabled = canCreate }
    }
  }
  private static let createID = "home-new-session"
  private var createTabIdentifier = HomeTabsController.createID
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
    // `mode` is iOS 18; earlier systems only have the classic tab bar.
    if #available(iOS 18.0, *) { mode = .tabBar }
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
    // already resolved a tab's provider. Each navigation keeps its original tab:
    // UIKit rejects a controller resolved by one UITab being handed to another, so a
    // second compact install (folding an iPhone Duo again) must reuse the first tabs.
    let navigations = HomeTab.allCases.map { ($0, navigation($0)) }
    if #available(iOS 18.0, *) {
      if tabs.isEmpty { installTabs(navigations) }
    } else if viewControllers == nil {
      // Classic tab bar items carry the same titles, icons and identifiers.
      for (index, (destination, controller)) in navigations.enumerated() {
        let item = UITabBarItem(title: destination.title, image: destination.icon.uiImage, tag: index)
        item.accessibilityIdentifier = "home-tab-\(destination)"
        controller.tabBarItem = item
      }
      viewControllers = navigations.map(\.1)
    }
    // Lists keep their last rows clear of the floating create action.
    if floatingCreate != nil {
      for (destination, controller) in navigations {
        controller.additionalSafeAreaInsets.bottom = destination == .settings ? 0 : Self.floatingSize + Self.floatingMargin
      }
    }
  }

  @available(iOS 18.0, *)
  private func installTabs(_ navigations: [(HomeTab, UINavigationController)]) {
    var built = navigations.map { destination, controller in
      let tab = UITab(title: destination.title, image: destination.icon.uiImage,
        identifier: "home-tab-\(destination)") { _ in controller }
      tab.accessibilityIdentifier = tab.identifier
      return tab
    }
    if #available(iOS 26.0, *), floatingCreate == nil {
      let create: UITab
      if #available(iOS 27.0, *) {
        create = UITab(title: String(localized: "tabs.newSession", bundle: .lody), image: LodyIcon.compose.uiImage,
          identifier: Self.createID) { _ in UIViewController() }
      } else {
        let search = UISearchTab { _ in UIViewController() }
        search.automaticallyActivatesSearch = true
        search.title = String(localized: "tabs.newSession", bundle: .lody)
        search.image = LodyIcon.compose.uiImage
        create = search
      }
      create.accessibilityIdentifier = Self.createID
      createTabIdentifier = create.identifier
      built.append(create)
    }
    tabs = built
    // Apply disabled state only after assigning `tabs`: installing an iOS 26 UISearchTab
    // with `isEnabled = false` leaves its minimized button stuck disabled when re-enabled.
    if #available(iOS 18.4, *), !canCreate { tab(forIdentifier: createTabIdentifier)?.isEnabled = false }
    // iOS 27 supports a separate prominent action without misrepresenting it as Search.
    if #available(iOS 27.0, *) { prominentTabIdentifier = Self.createID }
  }

  func show(_ destination: HomeTab) {
    if #available(iOS 18.0, *) {
      selectedTab = tab(forIdentifier: "home-tab-\(destination)")
    } else {
      selectedIndex = HomeTab.allCases.firstIndex(of: destination) ?? 0
    }
    if #available(iOS 26.0, *) { tabBarMinimizeBehavior = destination == .chats ? .onScrollDown : .never }
    updateCreate(destination)
  }

  /// The create action keeps the compose glyph; on Schedules it adds a schedule, elsewhere it starts a chat.
  private func updateCreate(_ destination: HomeTab) {
    let title = String(localized: String.LocalizationValue(destination == .schedules ? "schedules.new" : "tabs.newSession"), bundle: .lody)
    if #available(iOS 18.0, *) { tab(forIdentifier: createTabIdentifier)?.title = title }
    floatingCreate?.accessibilityLabel = title
    floatingCreate?.isHidden = destination == .settings
  }

  @available(iOS 18.0, *)
  func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
    if tab.identifier == createTabIdentifier { if canCreate { onCreate() }; return false }
    return true
  }

  @available(iOS 18.0, *)
  func tabBarController(_ tabBarController: UITabBarController, didSelectTab selectedTab: UITab, previousTab: UITab?) {
    guard let destination = HomeTab.allCases.first(where: { selectedTab.identifier == "home-tab-\($0)" }) else { return }
    didSelect(destination)
  }

  // The create action never exists as a classic tab bar item (the floating
  // button covers it below iOS 26), so every classic selection is a real tab.
  func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
    guard let index = viewControllers?.firstIndex(of: viewController),
          index < HomeTab.allCases.count else { return }
    didSelect(HomeTab.allCases[index])
  }

  private func didSelect(_ destination: HomeTab) {
    if #available(iOS 26.0, *) { tabBarMinimizeBehavior = destination == .chats ? .onScrollDown : .never }
    updateCreate(destination)
    onSelect(destination)
  }

  @objc private func longPressed(_ gesture: UILongPressGestureRecognizer) {
    guard gesture.state == .began else { return }
    if #available(iOS 18.0, *) {
      guard selectedTab?.identifier == "home-tab-settings" else { return }
    } else {
      guard selectedIndex == HomeTab.allCases.firstIndex(of: .settings) else { return }
    }
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
