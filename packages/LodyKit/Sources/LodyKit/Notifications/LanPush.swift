import Foundation
import os
import UIKit
import UserNotifications

/// Persisted APNs device token scoped to the signed build identity and APNs
/// environment so background push-to-start wakeups can upload new Live Activity
/// tokens immediately without blocking on a fresh APNs registration round-trip.
struct LanPushDeviceTokenRecord: Codable, Equatable, Sendable {
  var token: String
  var bundleId: String
  var environment: String

  static func isValidToken(_ token: String) -> Bool {
    guard token.count >= 64, token.count <= 256, token.count.isMultiple(of: 2) else { return false }
    return token.utf8.allSatisfy {
      ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102)
    }
  }

  static func encode(token: String, bundleId: String, environment: String) -> String? {
    guard isValidToken(token), !bundleId.isEmpty, !environment.isEmpty else { return nil }
    let record = Self(token: token.lowercased(), bundleId: bundleId, environment: environment)
    guard let data = try? JSONEncoder().encode(record) else { return nil }
    return String(decoding: data, as: UTF8.self)
  }

  static func decode(_ raw: String?, expectedBundleId: String, expectedEnvironment: String) -> String? {
    guard let raw, !expectedBundleId.isEmpty, !expectedEnvironment.isEmpty,
          let record = try? JSONDecoder().decode(Self.self, from: Data(raw.utf8)),
          record.bundleId == expectedBundleId,
          record.environment == expectedEnvironment,
          isValidToken(record.token) else { return nil }
    return record.token.lowercased()
  }
}

/// Generation-fenced activity token map so an older native ActivityKit instance
/// cannot overwrite or erase a newer replacement that shares the same logical ID.
struct LanPushActivityTokens: Equatable, Sendable {
  private struct Owner: Equatable, Sendable {
    var nativeId: String
    var generation: Int
  }

  private(set) var values: [String: String] = [:]
  private var owners: [String: Owner] = [:]
  private var claimedGenerations: [String: Int] = [:]
  private var nextGeneration = 0

  @discardableResult
  mutating func claim(nativeId: String) -> Int {
    if let existing = claimedGenerations[nativeId] { return existing }
    nextGeneration += 1
    claimedGenerations[nativeId] = nextGeneration
    return nextGeneration
  }

  mutating func release(nativeId: String) {
    claimedGenerations.removeValue(forKey: nativeId)
  }

  mutating func enter(_ activityId: String, hex: String, nativeId: String? = nil) -> Bool {
    if let nativeId {
      let generation = claim(nativeId: nativeId)
      if let owner = owners[activityId], owner.nativeId != nativeId, owner.generation > generation {
        return false
      }
      let changed = values[activityId] != hex
      owners[activityId] = Owner(nativeId: nativeId, generation: generation)
      values[activityId] = hex
      return changed
    }
    guard values[activityId] != hex else { return false }
    values[activityId] = hex
    return true
  }

  mutating func exit(_ activityId: String, ifHex hex: String? = nil, nativeId: String? = nil) -> Bool {
    if let nativeId {
      claimedGenerations.removeValue(forKey: nativeId)
      if let owner = owners[activityId], owner.nativeId != nativeId {
        return false
      }
    }
    guard let current = values[activityId] else {
      if let nativeId, owners[activityId]?.nativeId == nativeId {
        owners.removeValue(forKey: activityId)
      }
      return false
    }
    if let hex, current != hex { return false }
    values.removeValue(forKey: activityId)
    owners.removeValue(forKey: activityId)
    return true
  }

  /// Retires `departingNativeId` and promotes `replacementNativeId` only when the
  /// departing activity was the active owner (or no higher-generation owner exists).
  mutating func replace(
    _ activityId: String,
    departingNativeId: String,
    replacementNativeId: String,
    replacementHex: String
  ) -> Bool {
    claimedGenerations.removeValue(forKey: departingNativeId)
    if owners[activityId]?.nativeId == departingNativeId {
      owners.removeValue(forKey: activityId)
    }
    return enter(activityId, hex: replacementHex, nativeId: replacementNativeId)
  }

  mutating func clear() -> Bool {
    let hadValues = !values.isEmpty
    values.removeAll()
    owners.removeAll()
    claimedGenerations.removeAll()
    return hadValues
  }
}

/// Tracks background push-to-start wake obligations per native ActivityKit
/// instance so an older activity's upload cannot prematurely cut short the
/// background allowance while a newer activity is still waiting for its token.
struct LanPushWakeTracker: Equatable, Sendable {
  private(set) var awaitingToken: Set<String> = []
  private(set) var awaitingUpload: [String: String] = [:]
  private(set) var confirmedUploads = 0

  mutating func reset() {
    awaitingToken.removeAll()
    awaitingUpload.removeAll()
    confirmedUploads = 0
  }

  mutating func markAwaitingToken(nativeId: String) {
    awaitingUpload.removeValue(forKey: nativeId)
    awaitingToken.insert(nativeId)
  }

  mutating func markTokenEntered(nativeId: String, tokenHex: String) {
    awaitingToken.remove(nativeId)
    awaitingUpload[nativeId] = tokenHex
  }

  mutating func markStopped(nativeId: String) {
    awaitingToken.remove(nativeId)
    awaitingUpload.removeValue(forKey: nativeId)
  }

  func coveredEntries(in uploadedActivities: [String: String]) -> [String: String] {
    let uploadedValues = Set(uploadedActivities.values)
    return awaitingUpload.filter { uploadedValues.contains($0.value) }
  }

  mutating func markUploadConfirmed(_ covered: [String: String]) {
    var confirmedAny = false
    for (nativeId, tokenHex) in covered where awaitingUpload[nativeId] == tokenHex {
      awaitingUpload.removeValue(forKey: nativeId)
      confirmedAny = true
    }
    if confirmedAny { confirmedUploads += 1 }
  }

  var hasPendingWork: Bool {
    !awaitingToken.isEmpty || !awaitingUpload.isEmpty
  }

  var canReleaseEarly: Bool {
    !hasPendingWork && confirmedUploads > 0
  }
}

/// Push on a LAN: the hub of the LAN talks to APNs, so this device registers
/// its APNs and Live Activity tokens there. Each registration replaces the
/// previous one; the LAN token never leaves native code.
@MainActor
final class LanPush {
  enum HubState: String { case pending, ready, noKey, unreachable }

  enum SendError: Error {
    case rejected(Int)
    case transient(Int)
  }

  static let shared = LanPush()
  private(set) var invite: LanInvite?
  static let changed = Notification.Name("LodyLANPushDidChange")
  private(set) var hubState = HubState.pending {
    didSet { if oldValue != hubState { NotificationCenter.default.post(name: Self.changed, object: nil) } }
  }
  private var deviceToken: String?
  private var pushToStartToken: String?
  private var activities = LanPushActivityTokens()
  private var userId: String?
  private var upload: Task<Void, Never>?
  /// A push can wake the app just long enough to report a new activity token;
  /// a short background allowance lets that report reach the hub.
  private var uploadAllowance = UIBackgroundTaskIdentifier.invalid
  private var uploadGeneration = 0
  /// Keeps a cold background push-to-start launch alive while ActivityKit
  /// delivers the new activity's per-activity push token and/or APNs finishes.
  private var wakeAllowance = UIBackgroundTaskIdentifier.invalid
  /// Hard upper bound for `wakeAllowance`; never cancelled by early release.
  private var wakeDeadlineTimer: Task<Void, Never>?
  /// Short settle timer after all pending wake uploads are confirmed.
  private var wakeReleaseTimer: Task<Void, Never>?
  private var wakeTracker = LanPushWakeTracker()
  private var leaving = false
  private static let log = Logger(subsystem: "app.innei.lody", category: "lan-push")
  private static let retryDelays: [Duration] = [.zero, .milliseconds(1500), .milliseconds(3500)]

  var active: Bool { invite != nil }

  /// Reads the joined LAN; `false` leaves push to the hosted provider.
  @discardableResult
  func start() -> Bool {
    guard !leaving, let invite = try? LanHub.read() else { return false }
    let changed = self.invite != invite
    self.invite = invite
    if deviceToken == nil {
      deviceToken = Self.readPersistedDeviceToken()
    } else if changed, let deviceToken {
      Self.persistDeviceToken(deviceToken)
    }
    if changed {
      hubState = .pending
      userId = invite.userId
      // A hub that moved knows no tokens yet; the APNs token itself is unchanged.
      sync()
    } else if deviceToken != nil, hubState == .pending || hubState == .unreachable {
      sync()
    }
    if UIApplication.shared.applicationState == .background {
      holdBackgroundWake(waitingForActivityToken: false)
    }
    UIApplication.shared.registerForRemoteNotifications()
    return true
  }

  func didRegister(_ token: Data) {
    let hex = Self.hex(token)
    let changed = hex != deviceToken
    deviceToken = hex
    if changed {
      Self.persistDeviceToken(hex)
      sync()
    } else if invite != nil, hubState != .ready, upload == nil {
      sync()
    }
  }

  func didFailToRegister() {
    guard invite != nil else { return }
    if deviceToken == nil, hubState == .pending {
      hubState = .unreachable
    }
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

  @discardableResult
  func claimActivity(nativeId: String) -> Int {
    activities.claim(nativeId: nativeId)
  }

  func enter(_ activityId: String, token: Data, nativeId: String? = nil) {
    let hex = Self.hex(token)
    let updated = activities.enter(activityId, hex: hex, nativeId: nativeId)
    if let nativeId, wakeAllowance != .invalid {
      let accepted = activities.values[activityId] == hex
      if accepted, (updated || hubState != .ready || upload != nil) {
        wakeReleaseTimer?.cancel()
        wakeReleaseTimer = nil
        wakeTracker.markTokenEntered(nativeId: nativeId, tokenHex: hex)
      } else {
        wakeTracker.markStopped(nativeId: nativeId)
      }
    }
    guard updated else { return }
    sync()
  }

  func markPendingActivity(nativeId: String) {
    guard invite != nil, UIApplication.shared.applicationState == .background else { return }
    wakeReleaseTimer?.cancel()
    wakeReleaseTimer = nil
    wakeTracker.markAwaitingToken(nativeId: nativeId)
  }

  func markActivityStopped(nativeId: String) {
    activities.release(nativeId: nativeId)
    wakeTracker.markStopped(nativeId: nativeId)
  }

  func exit(_ activityId: String, ifToken token: Data? = nil, nativeId: String? = nil) {
    guard activities.exit(activityId, ifHex: token.map(Self.hex), nativeId: nativeId) else { return }
    sync()
  }

  func replaceActivity(
    _ activityId: String,
    departingNativeId: String,
    replacementNativeId: String,
    replacementToken: Data
  ) {
    wakeTracker.markStopped(nativeId: departingNativeId)
    let hex = Self.hex(replacementToken)
    let updated = activities.replace(
      activityId,
      departingNativeId: departingNativeId,
      replacementNativeId: replacementNativeId,
      replacementHex: hex
    )
    if wakeAllowance != .invalid, activities.values[activityId] == hex, (updated || hubState != .ready || upload != nil) {
      wakeReleaseTimer?.cancel()
      wakeReleaseTimer = nil
      wakeTracker.markTokenEntered(nativeId: replacementNativeId, tokenHex: hex)
    }
    guard updated else { return }
    sync()
  }

  func clearActivities() {
    guard activities.clear() else { return }
    sync()
  }

  /// Holds a bounded background task during cold background push-to-start launches
  /// so iOS does not suspend the process before ActivityKit yields the new token.
  func holdBackgroundWake(waitingForActivityToken: Bool) {
    guard invite != nil, UIApplication.shared.applicationState == .background else { return }
    if wakeAllowance == .invalid {
      wakeTracker.reset()
      wakeAllowance = UIApplication.shared.beginBackgroundTask(withName: "lan-push-activity-wake") { [weak self] in
        MainActor.assumeIsolated { self?.endBackgroundWake() }
      }
    }
    guard wakeAllowance != .invalid else { return }
    wakeReleaseTimer?.cancel()
    wakeReleaseTimer = nil
    wakeDeadlineTimer?.cancel()
    let waitSeconds = (waitingForActivityToken || wakeTracker.hasPendingWork) ? 10 : 8
    wakeDeadlineTimer = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(waitSeconds))
      guard !Task.isCancelled else { return }
      self?.endBackgroundWake()
    }
  }

  func endBackgroundWake() {
    wakeDeadlineTimer?.cancel()
    wakeDeadlineTimer = nil
    wakeReleaseTimer?.cancel()
    wakeReleaseTimer = nil
    wakeTracker.reset()
    guard wakeAllowance != .invalid else { return }
    UIApplication.shared.endBackgroundTask(wakeAllowance)
    wakeAllowance = .invalid
  }

  /// Forgets this device on the hub before the LAN credential is dropped.
  func leave() async {
    leaving = true
    defer { leaving = false }
    let previous = upload
    previous?.cancel()
    upload = nil
    let oldInvite = invite
    let oldToken = deviceToken ?? Self.readPersistedDeviceToken()
    try? AuthKeychain.clear(account: AuthKeychain.lanPushDeviceToken)
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
    endBackgroundWake()
    invite = nil
    hubState = .pending
    pushToStartToken = nil
    _ = activities.clear()
    userId = nil
  }

  /// Coalesces bursts of token changes into one registration with bounded retry.
  func sync() {
    guard let invite, deviceToken != nil, let userId, !userId.isEmpty else { return }
    upload?.cancel()
    if uploadAllowance == .invalid {
      uploadAllowance = UIApplication.shared.beginBackgroundTask(withName: "lan-push-registration") { [weak self] in
        MainActor.assumeIsolated {
          self?.upload?.cancel()
          self?.endUploadAllowance()
        }
      }
    }
    uploadGeneration += 1
    let generation = uploadGeneration
    upload = Task { @MainActor in
      // Only the latest registration releases the allowance.
      defer {
        if uploadGeneration == generation {
          upload = nil
          endUploadAllowance()
        }
      }
      try? await Task.sleep(for: .milliseconds(300))
      guard !Task.isCancelled, self.invite == invite else { return }
      let inBackground = UIApplication.shared.applicationState == .background
      let timeout: TimeInterval = inBackground ? 6 : 15
      let result = await self.uploadWithRetry(invite: invite, timeout: timeout)
      guard !Task.isCancelled, self.invite == invite else { return }
      hubState = result.state
      if result.state != .unreachable {
        wakeTracker.markUploadConfirmed(result.coveredWakeEntries)
      }
      if result.state != .unreachable, wakeAllowance != .invalid, wakeTracker.canReleaseEarly {
        wakeReleaseTimer?.cancel()
        wakeReleaseTimer = Task { @MainActor [weak self] in
          try? await Task.sleep(for: .seconds(1))
          guard !Task.isCancelled, let self, !self.wakeTracker.hasPendingWork else { return }
          self.endBackgroundWake()
        }
      }
    }
  }

  private func uploadWithRetry(invite: LanInvite, timeout: TimeInterval) async -> (state: HubState, coveredWakeEntries: [String: String]) {
    for (index, delay) in Self.retryDelays.enumerated() {
      if index > 0 {
        try? await Task.sleep(for: delay)
      }
      guard !Task.isCancelled, self.invite == invite,
            let currentToken = self.deviceToken,
            let currentUserId = self.userId, !currentUserId.isEmpty else {
        return (hubState, [:])
      }
      let settings = await UNUserNotificationCenter.current().notificationSettings()
      guard !Task.isCancelled, self.invite == invite else { return (hubState, [:]) }
      let alertsAuthorized = Self.alertsAuthorized(settings.authorizationStatus)
      let coveredWakeEntries = wakeTracker.coveredEntries(in: activities.values)
      let body = registration(
        invite: invite,
        deviceToken: currentToken,
        userId: currentUserId,
        alerts: alertsAuthorized
      )
      do {
        let answer = try await Self.send(invite: invite, method: "PUT", body: body, timeout: timeout)
        let nextState: HubState = answer["configured"] as? Bool == true ? .ready : .noKey
        return (nextState, coveredWakeEntries)
      } catch let error as SendError {
        if case .rejected(let status) = error {
          Self.log.error("registration rejected (status \(status, privacy: .public))")
          return (.unreachable, [:])
        }
        Self.log.error("registration attempt \(index + 1, privacy: .public) failed (transient)")
      } catch {
        Self.log.error("registration attempt \(index + 1, privacy: .public) failed (code \((error as NSError).code, privacy: .public))")
      }
    }
    return (.unreachable, [:])
  }

  static func alertsAuthorized(_ status: UNAuthorizationStatus) -> Bool {
    switch status {
    case .authorized, .provisional, .ephemeral:
      return true
    case .notDetermined, .denied:
      return false
    @unknown default:
      return false
    }
  }

  static func shouldRetry(httpStatus status: Int) -> Bool {
    status >= 500 || status == 408 || status == 429
  }

  private func endUploadAllowance() {
    guard uploadAllowance != .invalid else { return }
    UIApplication.shared.endBackgroundTask(uploadAllowance)
    uploadAllowance = .invalid
  }

  private func registration(invite: LanInvite, deviceToken: String, userId: String, alerts: Bool) -> [String: Any] {
    var body: [String: Any] = [
      "deviceToken": deviceToken,
      "environment": ApsEnvironment.current,
      "bundleId": Bundle.main.bundleIdentifier ?? "",
      "userId": userId,
      "workspaceId": invite.workspaceId,
      "workspaceSlug": LanInvite.workspaceSlug,
      "workspaceName": invite.displayName,
      "locale": Locale.preferredLanguages.first ?? "en",
      "alerts": alerts,
      "liveActivities": ConversationActivities.supported && LodyPreferences.liveActivitiesEnabled,
      "activities": activities.values,
      "liveActivityLabels": Self.remoteLabels,
    ]
    if let pushToStartToken { body["pushToStartToken"] = pushToStartToken }
    return body
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

  private static func readPersistedDeviceToken() -> String? {
    let bundleId = Bundle.main.bundleIdentifier ?? ""
    guard let raw = try? AuthKeychain.read(account: AuthKeychain.lanPushDeviceToken) else { return nil }
    return LanPushDeviceTokenRecord.decode(raw, expectedBundleId: bundleId, expectedEnvironment: ApsEnvironment.current)
  }

  private static func persistDeviceToken(_ token: String) {
    let bundleId = Bundle.main.bundleIdentifier ?? ""
    guard let encoded = LanPushDeviceTokenRecord.encode(token: token, bundleId: bundleId, environment: ApsEnvironment.current) else { return }
    try? AuthKeychain.save(encoded, account: AuthKeychain.lanPushDeviceToken)
  }

  private static func send(
    invite: LanInvite,
    method: String,
    path: String = "/push/devices",
    body: [String: Any],
    timeout: TimeInterval = 15
  ) async throws -> [String: Any] {
    guard let url = URL(string: "\(invite.url)\(path)") else { throw URLError(.badURL) }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
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
    guard (200..<300).contains(status) else {
      if shouldRetry(httpStatus: status) { throw SendError.transient(status) }
      throw SendError.rejected(status)
    }
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
