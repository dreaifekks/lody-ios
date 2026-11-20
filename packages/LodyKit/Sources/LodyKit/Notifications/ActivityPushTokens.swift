@preconcurrency import ActivityKit
import Foundation

/// Direct APNs has separate device, push-to-start, and per-activity tokens.
@MainActor
final class ActivityPushTokens {
  private typealias Live = Activity<LodyConversationLiveActivityAttributes>
  private var session: PushRegistration.Session?
  private var retryOnRefresh = false
  private var observers: [Task<Void, Never>] = []
  private var updates: [String: Task<Void, Never>] = [:]

  func configure(_ next: PushRegistration.Session?) {
    guard next != session || retryOnRefresh else { return }
    retryOnRefresh = false
    observers.forEach { $0.cancel() }
    updates.values.forEach { $0.cancel() }
    observers.removeAll()
    updates.removeAll()
    session = next
    guard let next else { return }
    // ActivityKit tokens only exist where Live Activities can run.
    guard ConversationActivities.supported else { return }
    for activity in Live.activities { observe(activity, session: next) }
    observers.append(Task {
      for await activity in Live.activityUpdates {
        guard !Task.isCancelled else { return }
        observe(activity, session: next)
      }
    })
    if #available(iOS 17.2, *) {
      observers.append(Task {
        if let token = Live.pushToStartToken { await upload(token, session: next) }
        for await token in Live.pushToStartTokenUpdates {
          guard !Task.isCancelled else { return }
          await upload(token, session: next)
        }
      })
    }
  }

  private func observe(_ activity: Live, session: PushRegistration.Session) {
    let attributes = activity.attributes
    guard attributes.activityId == "lody-conversations:v5:\(attributes.workspaceId):\(session.user)",
          updates[activity.id] == nil else { return }
    updates[activity.id] = Task {
      if let token = activity.pushToken { await upload(token, session: session, activity: activity) }
      for await token in activity.pushTokenUpdates {
        guard !Task.isCancelled else { return }
        await upload(token, session: session, activity: activity)
      }
      if !Task.isCancelled { updates.removeValue(forKey: activity.id) }
    }
  }

  private func upload(_ token: Data, session: PushRegistration.Session, activity: Live? = nil) async {
    guard self.session == session, !Task.isCancelled, let site = URL(string: BackendEnvironment.site) else { return }
    var body = ["installationId": session.installation, "purpose": activity == nil ? "activity-start" : "activity",
                "language": Locale.preferredLanguages.first ?? "en", "token": token.map { String(format: "%02x", $0) }.joined()]
    if let activity {
      body["activityId"] = activity.attributes.activityId
      body["workspaceId"] = activity.attributes.workspaceId
    }
    var request = URLRequest(url: site.appendingPathComponent("api/live-activity/push-token"), timeoutInterval: 15)
    request.httpMethod = "POST"
    request.setValue("Bearer \(session.credential)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    do {
      request.httpBody = try JSONEncoder().encode(body)
      let (_, response) = try await URLSession.shared.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    } catch {
      guard !Task.isCancelled, self.session == session else { return }
      retryOnRefresh = true
      DiagnosticsStore.shared.record("notification", "activity_token_unconfirmed")
    }
  }
}
