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
  private(set) var hubState = HubState.pending
  private var deviceToken: String?
  private var pushToStartToken: String?
  private var activities: [String: String] = [:]
  private var userId: String?
  private var upload: Task<Void, Never>?
  /// A push can wake the app just long enough to report a new activity token;
  /// a short background allowance lets that report reach the hub.
  private var uploadAllowance = UIBackgroundTaskIdentifier.invalid
  private var uploadGeneration = 0
  private static let log = Logger(subsystem: "app.innei.lody", category: "lan-push")

  var active: Bool { invite != nil }

  /// Reads the joined LAN; `false` leaves push to the hosted provider.
  @discardableResult
  func start() -> Bool {
    guard let invite = try? LanHub.read() else { return false }
    let changed = self.invite != invite
    self.invite = invite
    if changed {
      hubState = .pending
      userId = invite.userId
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
    upload?.cancel()
    upload = nil
    guard let invite, let deviceToken else {
      reset()
      return
    }
    reset()
    _ = try? await Self.send(invite: invite, method: "DELETE", body: ["deviceToken": deviceToken])
  }

  private func reset() {
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
        Self.log.error("registration failed: \(error.localizedDescription, privacy: .public)")
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
    let settings = LiveActivities.shared
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
      "liveActivities": settings.enabled,
      "activities": activities,
      "liveActivityCopy": settings.remoteCopy,
      "liveActivityLabels": settings.remoteLabels,
    ]
    if let pushToStartToken { body["pushToStartToken"] = pushToStartToken }
    return body
  }

  private static func send(invite: LanInvite, method: String, body: [String: Any]) async throws -> [String: Any] {
    guard let url = URL(string: "\(invite.url)/push/devices") else { throw URLError(.badURL) }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
    request.httpMethod = method
    request.setValue("Bearer \(invite.token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, response) = try await URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
      .data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    // A host from before push answers 404: it is reachable but cannot push.
    if status == 404 { return ["configured": false] }
    guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
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
