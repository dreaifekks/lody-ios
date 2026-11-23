import OneSignalFramework
import UserNotifications
import UIKit

/// Process-owned listener: notification clicks can precede scene restoration.
/// Lody Cloud pushes through OneSignal or direct APNs; a LAN pushes through its own hub (`LanPush`).
@MainActor
final class PushNotifications: NSObject, OSNotificationClickListener, OSNotificationLifecycleListener, OSPushSubscriptionObserver, UNUserNotificationCenterDelegate {
  static let shared = PushNotifications()
  private(set) var configured = false
  /// The active provider is LAN; a Cloud SDK initialized before joining remains opted out.
  private(set) var lanMode = false
  var providerReady: Bool { lanMode || configured }
  private var userId: String?
  private var clicks = PushClickBuffer()
  var onClickAvailable: (() -> Void)?
  var visibleRoute = ""
  private let activityTokens = ActivityPushTokens()
  private var registered = false
  private var sdkStarted = false
  private var sdkDelegate: (any UNUserNotificationCenterDelegate)?
  private var selectedProvider: PushRegistration.Provider?
  private var identityEpoch = 0
  private var launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  /// The last catalog the data runtime sent and when, for settling LAN permission notifications on foreground.
  private var permissionCatalog: (json: String, at: Date)?
  private static var installation: String {
    let key = "lody.push.installation.v1"
    if let saved = UserDefaults.standard.string(forKey: key), UUID(uuidString: saved) != nil { return saved }
    let id = UUID().uuidString
    UserDefaults.standard.set(id, forKey: key)
    return id
  }
  private lazy var registration: PushRegistration = PushRegistration(installation: Self.installation, call: { session, kind, path, args in
    // Capture the credential once: never borrow a newly logged-in account's JWT.
    let auth = try await GitHubCloud.request("https://backend.lody.ai/api/auth/convex/token", token: session.credential) as? [String: Any]
    guard let jwt = auth?["token"] as? String, !jwt.isEmpty else { throw GitHubCloud.failure() }
    let result = try await GitHubCloud.request("https://convex.lody.ai/api/\(kind)", token: jwt,
      body: ["path": path, "format": "convex_encoded_json", "args": [args]]) as? [String: Any]
    guard result?["status"] as? String == "success", let value = result?["value"] else { throw GitHubCloud.failure() }
    return try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
  }, changed: { [weak self] provider, registered in
    guard let self, !self.lanMode else { return }
    let previous = self.selectedProvider
    self.activityTokens.configure(provider == .apns && self.registration.authorized ? self.registration.session : nil)
    self.selectedProvider = provider
    self.configured = provider != nil
    self.registered = registered
    if provider == .oneSignal {
      self.startSDK()
      self.configured = self.sdkStarted
      if let delegate = self.sdkDelegate { UNUserNotificationCenter.current().delegate = delegate }
      if self.sdkStarted, let user = self.userId {
        OneSignal.login(user)
        if self.registration.authorized { OneSignal.User.pushSubscription.optIn() }
        else { OneSignal.User.pushSubscription.optOut() }
        self.evaluateSubscription(OneSignal.User.pushSubscription.id)
      }
    } else {
      if self.sdkStarted {
        OneSignal.User.pushSubscription.optOut()
        OneSignal.logout()
      }
      UNUserNotificationCenter.current().delegate = self
      if provider == .apns, self.registration.authorized,
         previous != .apns || !self.registration.hasDeviceToken || !UIApplication.shared.isRegisteredForRemoteNotifications {
        UIApplication.shared.registerForRemoteNotifications()
      }
    }
  }, failure: {
    DiagnosticsStore.shared.record("notification", "registration_unconfirmed")
  })
  #if DEBUG
  private var verificationShown = false
  var onRegistered: (() -> Void)?
  #endif

  func start(_ options: [UIApplication.LaunchOptionsKey: Any]?) {
    if LodyUIVerify.enabled || LodyUIVerify.offline { return }
    launchOptions = options
    UNUserNotificationCenter.current().delegate = self
    do {
      if try LanHub.read() != nil { _ = startLan(); return }
    } catch {
      // A locked/unavailable Keychain is not evidence that this is a Cloud account.
      return
    }
    PushPermissionLaunchRequest.perform {
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
        Task { @MainActor in self.refresh() }
      }
    }
  }

  /// Switch active push delivery to the joined LAN hub and opt out any initialized Cloud SDK.
  @discardableResult
  func startLan() -> Bool {
    if LodyUIVerify.enabled || LodyUIVerify.offline { return false }
    guard (try? LanHub.read()) != nil else { return false }
    if !lanMode {
      identityEpoch += 1
      clicks.identify(nil)
      visibleRoute = ""
      clearDelivered()
      activityTokens.configure(nil)
      registration.identify(user: nil, credential: nil)
      selectedProvider = nil
      if sdkStarted {
        OneSignal.User.pushSubscription.optOut()
        OneSignal.logout()
      }
      lanMode = true
      UNUserNotificationCenter.current().delegate = self
      PushPermissionLaunchRequest.perform {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { accepted, _ in
          Task { @MainActor in
            guard self.lanMode else { return }
            if accepted { UIApplication.shared.registerForRemoteNotifications() }
            LanPush.shared.sync()
          }
        }
      }
    }
    let started = LanPush.shared.start()
    if started {
      ConversationActivities.shared.reconcileLanTokens()
    }
    return started
  }

  func stopLan() {
    guard lanMode else { return }
    identityEpoch += 1
    clicks.identify(nil)
    userId = nil
    visibleRoute = ""
    lanMode = false
    LanPush.shared.stop()
    ConversationActivities.shared.reconcileLanTokens()
    UNUserNotificationCenter.current().delegate = self
    permissionCatalog = nil
    clearDelivered()
  }

  private func startSDK() {
    guard !lanMode, !sdkStarted, let appId = Bundle.main.object(forInfoDictionaryKey: "LodyOneSignalAppId") as? String,
          UUID(uuidString: appId) != nil else { return }
    sdkStarted = true
    OneSignal.Debug.setLogLevel(.LL_NONE)
    OneSignal.initialize(appId, withLaunchOptions: launchOptions)
    if ConversationActivities.supported {
      OneSignal.LiveActivities.setup(LodyConversationLiveActivityAttributes.self)
    }
    OneSignal.User.pushSubscription.addObserver(self)
    evaluateSubscription(OneSignal.User.pushSubscription.id)
    OneSignal.Notifications.addClickListener(self)
    OneSignal.Notifications.addForegroundLifecycleListener(self)
    sdkDelegate = UNUserNotificationCenter.current().delegate
  }

  nonisolated func onPushSubscriptionDidChange(state: OSPushSubscriptionChangedState) {
    let id = state.current.id
    Task { @MainActor in
      guard !self.lanMode else { return }
      self.evaluateSubscription(id)
    }
  }

  private func evaluateSubscription(_ id: String?) {
    guard !lanMode, registration.provider == .oneSignal else { return }
    registered = PushClickBuffer.isRegistered(id)
    DiagnosticsStore.shared.record("notification", "subscription_observed", fields: ["registered": String(registered)])
    #if DEBUG
    if registered { onRegistered?() }
    #endif
  }

  #if DEBUG
  func verify(from controller: UIViewController) {
    guard !lanMode, registration.provider == .oneSignal, configured, registered, !verificationShown, controller.presentedViewController == nil, controller.viewIfLoaded?.window != nil else { return }
    verificationShown = true
    let alert = UIAlertController(title: "Your OneSignal SDK integration is complete!", message: "You can now send Push Notifications & In-App Messages through OneSignal. Tap below to enable push notifications.", preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Got it", style: .default) { _ in
      OneSignal.Notifications.requestPermission({ _ in }, fallbackToSettings: false)
    })
    controller.present(alert, animated: true)
  }
  #endif

  func forgetDevice() async {
    await LanPush.shared.leave()
    identify(nil, credential: nil, refreshProvider: false)
  }

  func identify(_ id: String?, credential: String? = nil, refreshProvider: Bool = true) {
    guard !LodyUIVerify.enabled, !LodyUIVerify.offline else { return }
    if refreshProvider {
      do {
        if try LanHub.read() != nil { _ = startLan() }
        else { stopLan() }
      } catch { return }
    }
    if lanMode {
      let previous = userId
      if previous != id {
        identityEpoch += 1
        visibleRoute = ""
        permissionCatalog = nil
        clearDelivered()
      }
      userId = id
      clicks.identify(id)
      LanPush.shared.identify(id)
      return
    }
    if userId != id || registration.session?.credential != credential {
      identityEpoch += 1
      clearDelivered()
      visibleRoute = ""
    }
    userId = id
    clicks.identify(id)
    let changed = registration.session?.user != id || registration.session?.credential != credential
    registration.identify(user: id, credential: credential)
    if changed { refresh() }
  }

  func refresh() {
    guard !lanMode else { return }
    let epoch = identityEpoch
    Task { @MainActor in
      let settings = await UNUserNotificationCenter.current().notificationSettings()
      guard !self.lanMode, epoch == self.identityEpoch else { return }
      self.registration.refresh(authorized: [UNAuthorizationStatus.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus))
    }
  }

  func deviceToken(_ data: Data) {
    if lanMode {
      LanPush.shared.didRegister(data)
      return
    }
    // OneSignal's optIn re-registers with APNs and lands here too; refreshing on an
    // unchanged token would loop through login/optIn and the backend every few seconds.
    guard registration.deviceToken(data.map { String(format: "%02x", $0) }.joined(), bundle: Bundle.main.bundleIdentifier) else { return }
    refresh()
  }

  func registrationFailed() {
    if lanMode {
      LanPush.shared.didFailToRegister()
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
        if LanPush.shared.hubState == .unreachable { LanPush.shared.sync() }
        let hub = LanPush.shared.hubState
        completion(["configured": true, "permission": permission, "registered": hub == .ready, "hub": hub.rawValue])
        return
      }
      self.refresh()
      DiagnosticsStore.shared.record("notification", "status", fields: ["configured": String(self.configured), "permission": permission, "registered": String(self.registered)])
      completion(["configured": self.configured, "permission": permission, "registered": self.registered])
    }
  }

  func request(_ completion: @escaping @MainActor (Bool) -> Void) {
    guard let requestedUser = userId else { completion(false); return }
    let epoch = identityEpoch
    let wasLAN = lanMode
    Task { @MainActor in
      let accepted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
      guard epoch == self.identityEpoch, self.lanMode == wasLAN, self.userId == requestedUser else { completion(false); return }
      if self.lanMode {
        if accepted { UIApplication.shared.registerForRemoteNotifications() }
        LanPush.shared.sync()
      } else {
        self.refresh()
      }
      completion(accepted)
    }
  }

  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
    let info = notification.request.content.userInfo
    let recipient = info["recipientUserId"] as? String
    let route = info["route"] as? String
    let resolved = info["lodyKind"] as? String == PermissionNotices.resolved
    let identifier = notification.request.identifier
    return await MainActor.run {
      if self.lanMode {
        guard self.userId != nil, recipient == nil || recipient == self.userId else { return [] }
        if resolved {
          UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
          return []
        }
        guard route == nil || self.visibleRoute.isEmpty || route != self.visibleRoute else { return [] }
        return [.banner, .list, .sound]
      }
      guard self.registration.provider == .apns,
            PushClickBuffer.shouldDisplay(userId: self.userId, recipient: recipient,
              route: route, visibleRoute: self.visibleRoute) else { return [] }
      return [.banner, .list, .sound, .badge]
    }
  }

  // Not the async variant: it completes on a cooperative thread, and UIKit's completion
  // updates the app snapshot, which aborts off the main thread when a notification is tapped.
  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                          withCompletionHandler completionHandler: @escaping () -> Void) {
    let data = response.notification.request.content.userInfo
    let opened = response.actionIdentifier == UNNotificationDefaultActionIdentifier
    let payload = opened ? PushClickBuffer.payload(data) : nil
    let rawRoute = data["route"] as? String
    let rawRecipient = data["recipientUserId"] as? String
    let id = (data["custom"] as? [String: Any])?["i"] as? String ?? response.notification.request.identifier
    nonisolated(unsafe) let completionHandler = completionHandler
    Task { @MainActor in
      if self.lanMode {
        if opened, let route = rawRoute, let owner = rawRecipient ?? self.userId, !owner.isEmpty {
          self.clicks.receive(id: id, route: route, userId: owner)
          self.onClickAvailable?()
        }
      } else if let payload {
        self.clicks.receive(id: id, route: payload.route, userId: payload.recipient)
        self.onClickAvailable?()
      }
      completionHandler()
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

  func readPending() -> [String: String]? { clicks.pending }
  func acknowledge(_ id: String) {
    DiagnosticsStore.shared.record("notification", "click_acknowledged", fields: ["message": id, "current": String(clicks.pending?["id"] == id)])
    clicks.acknowledge(id)
  }

  nonisolated func onClick(event: OSNotificationClickEvent) {
    let id = event.notification.notificationId
    let route = event.notification.additionalData?["route"] as? String
    let recipient = event.notification.additionalData?["recipientUserId"] as? String
    Task { @MainActor in
      guard !self.lanMode else { return }
      DiagnosticsStore.shared.record("notification", "click_received", fields: ["message": id ?? "", "appState": String(UIApplication.shared.applicationState.rawValue)])
      guard let id, let route, route.utf8.count <= 2048,
            let owner = recipient, !owner.isEmpty else {
        DiagnosticsStore.shared.record("notification", "click_rejected", fields: ["message": id ?? "", "reason": "invalid_payload"])
        return
      }
      self.clicks.receive(id: id, route: route, userId: owner)
      if self.clicks.pending?["id"] == id {
        DiagnosticsStore.shared.record("notification", "click_buffered", fields: ["message": id])
      } else {
        DiagnosticsStore.shared.record("notification", "click_rejected", fields: ["message": id, "reason": "invalid_payload"])
      }
      self.onClickAvailable?()
    }
  }

  nonisolated func onWillDisplay(event: OSNotificationWillDisplayEvent) {
    event.preventDefault()
    let route = event.notification.additionalData?["route"] as? String
    let recipient = event.notification.additionalData?["recipientUserId"] as? String
    let id = event.notification.notificationId ?? ""
    nonisolated(unsafe) let event = event
    Task { @MainActor in
      DiagnosticsStore.shared.record("notification", "foreground_received", fields: ["message": id])
      guard !self.lanMode, self.registration.provider == .oneSignal,
            PushClickBuffer.shouldDisplay(userId: self.userId, recipient: recipient, route: route, visibleRoute: self.visibleRoute) else {
        DiagnosticsStore.shared.record("notification", "foreground_suppressed", fields: ["message": id])
        return
      }
      DiagnosticsStore.shared.record("notification", "foreground_display_requested", fields: ["message": id])
      event.notification.display()
    }
  }

  private func clearDelivered() {
    UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    UNUserNotificationCenter.current().setBadgeCount(0)
  }
}

@MainActor
final class PushLifecycle {
  func applicationDidEnterBackground(_ application: UIApplication) {
    DiagnosticsStore.shared.record("app", "background", fields: ["appState": String(application.applicationState.rawValue)])
    DiagnosticsStore.shared.flush()
  }

  func applicationDidBecomeActive(_ application: UIApplication) {
    DiagnosticsStore.shared.record("app", "foreground", fields: ["appState": String(application.applicationState.rawValue)])
    LanPush.shared.endBackgroundWake()
    if PushNotifications.shared.lanMode {
      _ = LanPush.shared.start()
      ConversationActivities.shared.recoverLanTokens()
      LanPush.shared.sync()
    }
    PushNotifications.shared.status { _ in }
    PushNotifications.shared.withdrawSettledPermissions()
  }

  func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    DiagnosticsStore.shared.keepAlive(application)
    DiagnosticsStore.shared.record("app", "launch", fields: ["appState": String(application.applicationState.rawValue), "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""])
    PushNotifications.shared.start(launchOptions)
    return true
  }
}
