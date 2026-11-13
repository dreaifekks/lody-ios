import LodyCore
import UIKit

/// One scene owns the runtime and the application coordinators, independently of page lifetimes.
@MainActor
public final class LodyApplication {
  public static let shared = LodyApplication()
  private let accent = LodyAccentLifecycle()
  private let push = PushLifecycle()

  public func launch(_ application: UIApplication, options: [UIApplication.LaunchOptionsKey: Any]?) {
    _ = accent.application(application, didFinishLaunchingWithOptions: options)
    _ = push.application(application, didFinishLaunchingWithOptions: options)
  }
  public func active() { accent.applicationDidBecomeActive(.shared); push.applicationDidBecomeActive(.shared); shares.wake() }
  public func background() { push.applicationDidEnterBackground(.shared) }

  private let runtime = DataRuntime(localStore: .shared)
  private var observers: [NSObjectProtocol] = []
  private var onboarding: PageContainerController?
  private var link: (route: String, user: String?)?
  private var identified: String?
  private var hasIdentified = false
  private let shares = ShareInboxCoordinator()

  public func start(in window: UIWindow) {
    precondition(observers.isEmpty, "Lody supports one active scene")
    PageFactory.debugSceneFactory = DebugSceneFactory.make
    LodyHosting.current = LodyUIKitHost.shared
    ComposerDictator.defaultEngine = DictationFixture.engine ?? SpeechDictation.shared
    ContentPreviewCoordinator.clearAll()
    if LodyUIVerify.offline { URLProtocol.registerClass(OfflineProbe.self) }
    lodyApplyWindowAccent()
    LiveActivities.shared.syncAppIcon()
    DataRuntime.current = runtime
    AuthSession.shared.stopRuntime = { [weak self] in self?.runtime.stop() }
    OutboxSession.shared.attach(runtime)
    CatalogSession.shared.attach(runtime)
    for name in [Notification.Name.lodyAuthDidChange, .lodyCatalogDidChange, UIApplication.didBecomeActiveNotification] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.reconcile() }
      })
    }
    PushNotifications.shared.onClickAvailable = { [weak self] in self?.reconcile() }
    if LodyUIVerify.enabled {
      DebugSceneCoordinator.start(in: window)
    } else {
      LodyShell.shared.start(in: window, content: HomeController())
      AuthSession.shared.start()
    }
  }

  public func open(_ url: URL) {
    guard let destination = AppLink.parse(url.absoluteString) else { return }
    switch destination {
    case .share: shares.wake()
    case .session:
      // Keep the original encoded route; the routing policy validates it again against the account.
      let tail = String(url.absoluteString.dropFirst(7)).prefix { $0 != "?" && $0 != "#" }
      link = (tail.hasPrefix("/") ? String(tail) : "/" + tail, AuthSession.shared.snapshot.account?.user.id)
      if HomeFixture.active { routeNotification() }
      else { reconcile() }
    case .page(let id, let params):
      if id == "debug" { DebugSceneCoordinator.open(params); return }
      var fields: [String: Any] = params
      if id == "activity" {
        let state = SessionSource.live.state
        fields["userId"] = state.userId; fields["workspaceId"] = state.workspaceId
      }
      let json = SessionController.json(fields)
      LodyShell.shared.openPage(id, params: json, from: nil)
    }
  }

  private func reconcile() {
    guard !LodyUIVerify.enabled else { return }
    let auth = AuthSession.shared.snapshot
    guard auth.localReady, !auth.busy else { return }
    let user = auth.account?.user.id
    if !hasIdentified || identified != user {
      hasIdentified = true
      identified = user
      PushNotifications.shared.identify(user)
    }
    if auth.account == nil {
      shares.stop()
      guard onboarding == nil else { return }
      let regular = HomeController.current?.traitCollection.horizontalSizeClass == .regular
      let page = LodyShell.shared.present(OnboardingController(), title: "", dismissible: false,
        style: regular ? "formSheet" : "pageSheet", headerShown: false)
      onboarding = page
      page.onClose = { [weak self] in self?.onboarding = nil; self?.reconcile() }
      return
    }
    routeNotification()
    shares.reconcile()
  }

  private func routeNotification() {
    let pending = PushNotifications.shared.readPending()
    guard let route = link?.route ?? pending?["route"] else { return }
    let recipient = link == nil ? pending?["userId"] : link?.user
    let state = SessionSource.live.state
    let auth = AuthSession.shared.snapshot
    let context = HomeFixture.active ? HomeFixture.routingContext() : NotificationNavigation.Context(ready: auth.localReady && !auth.busy,
      userId: auth.account?.user.id ?? "", workspaces: auth.account?.workspaces.map { ($0.id, $0.slug) } ?? [],
      selectedId: state.workspaceId, loading: state.loading, connected: state.connected,
      sessionIds: Set(state.catalog.sessions.map(\.id)))
    switch NotificationNavigation.resolve(route: route, recipient: recipient, context: context) {
    case .wait: return
    case .workspace(let id):
      if HomeFixture.active {
        try! HomeFixture.apply("selectWorkspace", ["workspaceId": id])
        routeNotification()
      } else { CatalogSession.shared.selectWorkspace(id) }
      return
    case .session(let id):
      DiagnosticsStore.shared.record("notification", "navigation_opened", fields: [:])
      LodyShell.shared.openSessionFromExternal(id)
    case .discard(let failure):
      DiagnosticsStore.shared.record("notification", "navigation_rejected", fields: ["reason": failure.rawValue])
      let keys: [NotificationNavigation.Failure: String] = [.wrongAccount: "wrongAccount", .unknownRoute: "unknown", .noWorkspace: "noWorkspace", .sessionMissing: "gone"]
      LodyToastOverlay.shared.show(message: String(localized: String.LocalizationValue("notifications.route." + keys[failure]!), bundle: .lody), kind: "error")
    }
    if link != nil { link = nil }
    else if let id = pending?["id"] { PushNotifications.shared.acknowledge(id) }
  }
}
