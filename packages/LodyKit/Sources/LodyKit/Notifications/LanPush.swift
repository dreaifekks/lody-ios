import Foundation
import os
import UIKit

/// Push on a LAN: the hub of the LAN talks to APNs, so this device registers
/// its APNs and Live Activity tokens there. Each registration replaces the
/// previous one; the LAN token never leaves native code.
@MainActor
final class LanPush {
  enum HubState: String { case pending, ready, noKey, unreachable }

  static let shared = LanPush()
  private(set) var invite: LanInvite?
  static let changed = Notification.Name("LodyLANPushDidChange")
  private(set) var hubState = HubState.pending {
    didSet { if oldValue != hubState { NotificationCenter.default.post(name: Self.changed, object: nil) } }
  }
  private var deviceToken: String?
  private var pushToStartToken: String?
  private var activities: [String: String] = [:]
  private var userId: String?
  private var upload: Task<Void, Never>?
  /// A push can wake the app just long enough to report a new activity token;
  /// a short background allowance lets that report reach the hub.
  private var uploadAllowance = UIBackgroundTaskIdentifier.invalid
  private var uploadGeneration = 0
  private var leaving = false
  private static let log = Logger(subsystem: "app.innei.lody", category: "lan-push")

  var active: Bool { invite != nil }

  /// Reads the joined LAN; `false` leaves push to the hosted provider.
  @discardableResult
  func start() -> Bool {
    guard !leaving, let invite = try? LanHub.read() else { return false }
    let changed = self.invite != invite
    self.invite = invite
    if changed {
      hubState = .pending
      userId = invite.userId
      // A hub that moved knows no tokens yet; the APNs token itself is unchanged.
      sync()
    }
    UIApplication.shared.registerForRemoteNotifications()
    return true
  }

  func didRegister(_ token: Data) {
    let hex = Self.hex(token)
    guard hex != deviceToken else { return }
    deviceToken = hex
    sync()
  }

  func identify(_ id: String?) {
    guard userId != id else { return }
    userId = id
    sync()
  }

  func setPushToStart(_ token: Data?) {
    let hex = token.map(Self.hex)
    guard hex != pushToStartToken else { return }
    pushToStartToken = hex
    sync()
  }

  func enter(_ activityId: String, token: Data) {
    let hex = Self.hex(token)
    guard activities[activityId] != hex else { return }
    activities[activityId] = hex
    sync()
  }

  func exit(_ activityId: String) {
    guard activities.removeValue(forKey: activityId) != nil else { return }
    sync()
  }

  /// Forgets this device on the hub before the LAN credential is dropped.
  func leave() async {
    leaving = true
    defer { leaving = false }
    let previous = upload
    previous?.cancel()
    upload = nil
    let oldInvite = invite
    let oldToken = deviceToken
    reset()
    await previous?.value
    guard let oldInvite, let oldToken else { return }
    _ = try? await Self.send(invite: oldInvite, method: "DELETE", body: ["deviceToken": oldToken])
  }

  /// Stops an already-forgotten provider when Auth publishes its replacement.
  func stop() {
    upload?.cancel()
    upload = nil
    reset()
  }

  private func reset() {
    uploadGeneration += 1
    endUploadAllowance()
    invite = nil
    hubState = .pending
    pushToStartToken = nil
    activities = [:]
    userId = nil
  }

  /// Coalesces bursts of token changes into one registration.
  func sync() {
    guard let invite, let deviceToken, let userId, !userId.isEmpty else { return }
    upload?.cancel()
    let body = registration(invite: invite, deviceToken: deviceToken, userId: userId)
    if uploadAllowance == .invalid {
      uploadAllowance = UIApplication.shared.beginBackgroundTask(withName: "lan-push-registration") { [weak self] in
        MainActor.assumeIsolated { self?.endUploadAllowance() }
      }
    }
    uploadGeneration += 1
    let generation = uploadGeneration
    upload = Task { @MainActor in
      // Only the latest registration releases the allowance.
      defer { if uploadGeneration == generation { endUploadAllowance() } }
      try? await Task.sleep(for: .milliseconds(300))
      guard !Task.isCancelled else { return }
      let state: HubState
      do {
        let answer = try await Self.send(invite: invite, method: "PUT", body: body)
        state = answer["configured"] as? Bool == true ? .ready : .noKey
      } catch {
        Self.log.error("registration failed (code \((error as NSError).code, privacy: .public))")
        state = .unreachable
      }
      guard !Task.isCancelled, self.invite == invite else { return }
      hubState = state
    }
  }

  private func endUploadAllowance() {
    guard uploadAllowance != .invalid else { return }
    UIApplication.shared.endBackgroundTask(uploadAllowance)
    uploadAllowance = .invalid
  }

  private func registration(invite: LanInvite, deviceToken: String, userId: String) -> [String: Any] {
    var body: [String: Any] = [
      "deviceToken": deviceToken,
      "environment": ApsEnvironment.current,
      "bundleId": Bundle.main.bundleIdentifier ?? "",
      "userId": userId,
      "workspaceId": invite.workspaceId,
      "workspaceSlug": LanInvite.workspaceSlug,
      "workspaceName": invite.displayName,
      "locale": Locale.preferredLanguages.first ?? "en",
      "alerts": true,
      "liveActivities": ConversationActivities.supported && LodyPreferences.liveActivitiesEnabled,
      "activities": activities,
      "liveActivityCopy": Self.remoteCopy,
      "liveActivityLabels": Self.remoteLabels,
    ]
    if let pushToStartToken { body["pushToStartToken"] = pushToStartToken }
    return body
  }

  /// Localized copy for activities the LAN hub updates while the app sleeps.
  private static var remoteCopy: [String: String] {
    [
      "stale": String(localized: "native.liveActivity.stale", bundle: .lody),
      "empty": String(localized: "native.liveActivity.empty", bundle: .lody),
      "others": String(localized: "native.liveActivity.others", bundle: .lody),
      "lastSync": String(localized: "native.liveActivity.lastSync", bundle: .lody),
      "openHint": String(localized: "native.liveActivity.openHint", bundle: .lody),
      "runningSummary": String(localized: "native.liveActivity.runningSummary", bundle: .lody),
      "completedSummary": String(localized: "native.liveActivity.completedSummary", bundle: .lody),
      "completedLabel": String(localized: "native.liveActivity.status.unread", bundle: .lody),
      "failedLabel": String(localized: "native.liveActivity.status.failed", bundle: .lody),
      "failedSummary": String(localized: "native.liveActivity.failedSummary", bundle: .lody),
      "elapsed": String(localized: "native.liveActivity.caption.elapsed", bundle: .lody),
      "waiting": String(localized: "native.liveActivity.caption.waiting", bundle: .lody),
      "took": String(localized: "native.liveActivity.caption.took", bundle: .lody),
      "allow": String(localized: "native.liveActivity.allow", bundle: .lody),
      "deny": String(localized: "native.liveActivity.deny", bundle: .lody),
      "smallAttention": String(localized: "native.liveActivity.small.attention", bundle: .lody),
      "smallWaiting": String(localized: "native.liveActivity.small.waiting", bundle: .lody),
      "smallDone": String(localized: "native.liveActivity.small.done", bundle: .lody),
      "smallFailed": String(localized: "native.liveActivity.small.failed", bundle: .lody),
      "smallStale": String(localized: "native.liveActivity.small.stale", bundle: .lody),
    ]
  }

  private static var remoteLabels: [String: String] {
    let attention = String(localized: "native.liveActivity.status.attention", bundle: .lody)
    return [
      "permission": attention,
      "question": attention,
      "running": String(localized: "native.liveActivity.status.running", bundle: .lody),
      "unread": String(localized: "native.liveActivity.status.unread", bundle: .lody),
    ]
  }

  private static func send(
    invite: LanInvite,
    method: String,
    path: String = "/push/devices",
    body: [String: Any]
  ) async throws -> [String: Any] {
    guard let url = URL(string: "\(invite.url)\(path)") else { throw URLError(.badURL) }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
    request.httpMethod = method
    request.setValue("Bearer \(invite.token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (data, response) = try await session.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    // A host from before push answers 404: it is reachable but cannot push.
    if status == 404 { return ["configured": false] }
    guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
  }

  /// Hands a choice made on the Live Activity to the member that asked; the
  /// agent goes on there. Throws when the hub cannot take it.
  func respondPermission(sessionId: String, requestId: String, optionId: String) async throws {
    guard !leaving, let invite = invite ?? (try? LanHub.read()) else { throw URLError(.userAuthenticationRequired) }
    let answer = try await Self.send(
      invite: invite,
      method: "POST",
      path: "/push/permission",
      body: ["sessionId": sessionId, "requestId": requestId, "optionId": optionId]
    )
    guard !leaving, (try? LanHub.read()) == invite else { throw URLError(.userAuthenticationRequired) }
    guard answer["ok"] as? Bool == true else { throw URLError(.cannotLoadFromNetwork) }
  }

  static func hex(_ token: Data) -> String {
    token.map { String(format: "%02x", $0) }.joined()
  }
}

/// The LAN credential is for the hub alone; never follow it elsewhere.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
    nil
  }
}
