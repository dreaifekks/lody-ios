import ExpoModulesCore
import OneSignalFramework
import UserNotifications
import UIKit

/// Process-owned listener: notification clicks can precede the React bridge.
/// Lody Cloud pushes through OneSignal; a LAN pushes through its own hub
/// (`LanPush`), and then this object is the notification center delegate.
@MainActor
final class PushNotifications: NSObject, OSNotificationClickListener, OSNotificationLifecycleListener, OSPushSubscriptionObserver, OSUserStateObserver, UNUserNotificationCenterDelegate {
  static let shared = PushNotifications()
  private(set) var configured = false
  /// A LAN hub delivers this device's pushes; OneSignal stays uninitialized.
  private(set) var lanMode = false
  /// Some provider can take Live Activity tokens.
  var providerReady: Bool { configured || lanMode }
  private var userId: String?
  private var clicks = PushClickBuffer()
  var onClickAvailable: (() -> Void)?
  var visibleRoute = ""
  private var registered = false
  /// The last catalog the data runtime sent and when, for settling permission
  /// notifications again on foreground.
  private var permissionCatalog: (json: String, at: Date)?
  #if DEBUG
  private var verificationShown = false
  var onRegistered: (() -> Void)?
  #endif

  func start(_ options: [UIApplication.LaunchOptionsKey: Any]?) {
    if LodyUIVerify.enabled || LodyUIVerify.offline { return }
    if startLan() { return }
    guard !configured, let appId = Bundle.main.object(forInfoDictionaryKey: "LodyOneSignalAppId") as? String,
          UUID(uuidString: appId) != nil else { return }
    configured = true
    OneSignal.Debug.setLogLevel(.LL_NONE)
    OneSignal.initialize(appId, withLaunchOptions: options)
    PushPermissionLaunchRequest.perform {
      OneSignal.Notifications.requestPermission({ _ in }, fallbackToSettings: false)
    }
    OneSignal.User.pushSubscription.addObserver(self)
    OneSignal.User.addObserver(self)
    evaluateSubscription(OneSignal.User.pushSubscription.id)
    OneSignal.Notifications.addClickListener(self)
    OneSignal.Notifications.addForegroundLifecycleListener(self)
  }

  /// Switches this process to LAN push. OneSignal swizzles the delegate and
  /// app delegate once initialized, so a process that started it keeps it
  /// until the next launch.
  @discardableResult
  func startLan() -> Bool {
    if LodyUIVerify.enabled || LodyUIVerify.offline { return false }
    guard !configured, LanPush.shared.start() else { return false }
    if !lanMode {
      lanMode = true
      // Set during launch so a click that launched the app is not lost.
      UNUserNotificationCenter.current().delegate = self
      PushPermissionLaunchRequest.perform {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
      }
    }
    LiveActivities.shared.start()
    return true
  }

  func stopLan() {
    guard lanMode else { return }
    lanMode = false
    permissionCatalog = nil
    clearDelivered()
  }

  nonisolated func onPushSubscriptionDidChange(state: OSPushSubscriptionChangedState) {
    let id = state.current.id
    Task { @MainActor in self.evaluateSubscription(id) }
  }

  nonisolated func onUserStateDidChange(state: OSUserChangedState) {
    // A background push-to-start launch may restore SDK identity before RN runs.
    Task { @MainActor in LiveActivities.shared.start() }
  }

  private func evaluateSubscription(_ id: String?) {
    registered = PushClickBuffer.isRegistered(id)
    #if DEBUG
    if registered { onRegistered?() }
    #endif
  }

  #if DEBUG
  func verify(from controller: UIViewController) {
    guard configured, registered, !verificationShown, controller.presentedViewController == nil, controller.viewIfLoaded?.window != nil else { return }
    verificationShown = true
    let alert = UIAlertController(title: "Your OneSignal SDK integration is complete!", message: "You can now send Push Notifications & In-App Messages through OneSignal. Tap below to enable push notifications.", preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Got it", style: .default) { _ in
      OneSignal.Notifications.requestPermission({ _ in }, fallbackToSettings: false)
    })
    controller.present(alert, animated: true)
  }
  #endif

  func identify(_ id: String?) {
    if lanMode {
      let previous = userId
      userId = id
      clicks.identify(id)
      LiveActivities.shared.identify(id)
      LanPush.shared.identify(id)
      if id == nil || (previous != nil && previous != id) {
        visibleRoute = ""
        permissionCatalog = nil
        clearDelivered()
      }
      if id != nil { LiveActivities.shared.start() }
      return
    }
    guard configured else { return }
    let previous = userId ?? OneSignal.User.externalId
    userId = id
    clicks.identify(id)
    LiveActivities.shared.identify(id)
    if let id, !id.isEmpty {
      if let previous, previous != id { clearDelivered() }
      OneSignal.login(id)
      LiveActivities.shared.start()
      // Never trigger the system permission prompt as a side effect of login.
      if OneSignal.Notifications.permission { OneSignal.User.pushSubscription.optIn() }
    } else {
      visibleRoute = ""
      if previous != nil { OneSignal.logout() }
      OneSignal.User.pushSubscription.optOut()
      clearDelivered()
    }
  }

  func status(_ completion: @escaping @MainActor ([String: any Sendable]) -> Void) {
    Task { @MainActor in
      let settings = await UNUserNotificationCenter.current().notificationSettings()
      let permission: String
      switch settings.authorizationStatus {
      case .notDetermined: permission = "notDetermined"
      case .denied: permission = "denied"
      case .authorized, .provisional, .ephemeral: permission = "authorized"
      @unknown default: permission = "denied"
      }
      if self.lanMode {
        if permission == "authorized" { UIApplication.shared.registerForRemoteNotifications() }
        let hub = LanPush.shared.hubState
        completion(["configured": true, "permission": permission, "registered": hub == .ready, "hub": hub.rawValue])
        return
      }
      if self.configured, self.userId != nil, permission == "authorized" {
        OneSignal.User.pushSubscription.optIn()
      }
      completion(["configured": self.configured, "permission": permission, "registered": self.registered])
    }
  }

  func request(_ completion: @escaping @MainActor (Bool) -> Void) {
    if lanMode {
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { accepted, _ in
        Task { @MainActor in
          if accepted { UIApplication.shared.registerForRemoteNotifications() }
          completion(accepted)
        }
      }
      return
    }
    guard configured, let requestedUser = userId else { completion(false); return }
    OneSignal.Notifications.requestPermission({ accepted in
      Task { @MainActor in
        if accepted, self.userId == requestedUser { OneSignal.User.pushSubscription.optIn() }
        completion(accepted)
      }
    }, fallbackToSettings: false)
  }

  func readPending() -> [String: String]? { clicks.pending }
  func acknowledge(_ id: String) { clicks.acknowledge(id) }

  nonisolated func onClick(event: OSNotificationClickEvent) {
    let id = event.notification.notificationId
    let route = event.notification.additionalData?["route"] as? String
    let recipient = event.notification.additionalData?["recipientUserId"] as? String
    Task { @MainActor in
      guard let id, let route, route.utf8.count <= 2048,
            let owner = recipient ?? self.userId ?? OneSignal.User.externalId, !owner.isEmpty else { return }
      self.clicks.receive(id: id, route: route, userId: owner)
      self.onClickAvailable?()
    }
  }

  nonisolated func onWillDisplay(event: OSNotificationWillDisplayEvent) {
    event.preventDefault()
    let route = event.notification.additionalData?["route"] as? String
    let recipient = event.notification.additionalData?["recipientUserId"] as? String
    nonisolated(unsafe) let event = event
    Task { @MainActor in
      guard self.userId != nil,
            recipient == nil || recipient == self.userId,
            self.visibleRoute.isEmpty || route != self.visibleRoute else { return }
      event.notification.display()
    }
  }

  // MARK: LAN delivery. The hub puts `route` and `recipientUserId` at the top level.

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    let info = notification.request.content.userInfo
    let route = info["route"] as? String
    let recipient = info["recipientUserId"] as? String
    if info["lodyKind"] as? String == PermissionNotices.resolved {
      // Answered on another device: show nothing and take the request it
      // replaces out of Notification Center.
      center.removeDeliveredNotifications(withIdentifiers: [notification.request.identifier])
      completionHandler([])
      return
    }
    nonisolated(unsafe) let completionHandler = completionHandler
    Task { @MainActor in
      // The session already on screen needs no banner.
      guard self.userId != nil,
            recipient == nil || recipient == self.userId,
            route == nil || self.visibleRoute.isEmpty || route != self.visibleRoute else {
        completionHandler([])
        return
      }
      completionHandler([.banner, .list, .sound])
    }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let id = response.notification.request.identifier
    let opened = response.actionIdentifier == UNNotificationDefaultActionIdentifier
    let info = response.notification.request.content.userInfo
    let route = info["route"] as? String
    let recipient = info["recipientUserId"] as? String
    nonisolated(unsafe) let completionHandler = completionHandler
    Task { @MainActor in
      defer { completionHandler() }
      guard opened, let route, let owner = recipient ?? self.userId, !owner.isEmpty else { return }
      self.clicks.receive(id: id, route: route, userId: owner)
      self.onClickAvailable?()
    }
  }

  /// Removes permission notifications that ask nothing any more: every
  /// resolution the hub sent, and requests whose session the latest catalog
  /// shows no longer waiting. Runs on each catalog and on foreground.
  func withdrawSettledPermissions(catalogJSON: String? = nil) {
    if let catalogJSON { permissionCatalog = (catalogJSON, Date()) }
    guard lanMode, let userId, !userId.isEmpty else { return }
    let catalog = permissionCatalog
    UNUserNotificationCenter.current().getDeliveredNotifications { @Sendable notifications in
      let notices = notifications.map {
        PermissionNotices.Delivered(
          identifier: $0.request.identifier,
          userInfo: $0.request.content.userInfo,
          threadId: $0.request.content.threadIdentifier,
          date: $0.date
        )
      }.filter(\.isPermission)
      guard !notices.isEmpty else { return }
      // Parsed here, off the main thread, and only when there is something to settle.
      var waiting: [String: Bool]?
      if let catalog, let root = try? JSONSerialization.jsonObject(with: Data(catalog.json.utf8)) as? [String: Any],
         let sessions = root["sessions"] as? [[String: Any]] {
        waiting = PermissionNotices.waitingOnUser(sessions: sessions)
      }
      let ids = PermissionNotices.withdrawable(notices, userId: userId, waiting: waiting, catalogAt: catalog?.at)
      guard !ids.isEmpty else { return }
      Task { @MainActor in
        guard self.lanMode, self.userId == userId else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
      }
    }
  }

  private func clearDelivered() {
    UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    UNUserNotificationCenter.current().setBadgeCount(0)
  }
}

public final class PushAppDelegateSubscriber: ExpoAppDelegateSubscriber {
  public func applicationDidBecomeActive(_ application: UIApplication) {
    PushNotifications.shared.status { _ in }
    PushNotifications.shared.withdrawSettledPermissions()
    LiveActivities.shared.start()
  }

  public func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    PushNotifications.shared.start(launchOptions)
    LiveActivities.shared.start()
    return true
  }

  public func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    MainActor.assumeIsolated {
      guard PushNotifications.shared.lanMode else { return }
      LanPush.shared.didRegister(deviceToken)
    }
  }
}
