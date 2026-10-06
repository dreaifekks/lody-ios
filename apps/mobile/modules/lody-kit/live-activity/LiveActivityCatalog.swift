import Foundation

extension LodyActivityAttributes {
  static func activityId(workspaceId: String, userId: String) -> String {
    "lody-conversations:v5:\(workspaceId):\(userId)"
  }
}

enum LiveActivityCatalog {
  private typealias Item = LodyActivityAttributes.ContentState.Item

  struct Labels: Sendable {
    var permission: String
    var running: String
    var stale: String
    var empty: String
    var others: String
    var lastSync: String
    var openHint: String
    var runningSummary: String = "{count} running"
    var completedSummary: String = "{count} tasks finished"
    var completed: String = "Completed"
    var failed: String = "Failed"
    var failedSummary: String = "{count} tasks failed"
    var elapsed: String = "elapsed"
    var waiting: String = "waiting"
    var took: String = "took"
    var allow: String = "Allow"
    var deny: String = "Deny"
  }

  static let runningStatuses: Set<String> = ["running", "initializing", "processing", "in_progress", "queued"]
  static let attentionStatuses: Set<String> = ["requestPermission", "waiting"]
  /// Lody's `HEARTBEAT_TTL_MS`. A session whose machine stamped `lastRunningSeen`
  /// longer ago than this is not live, whatever status it was left in.
  static let heartbeatTTL: Double = 180_000
  private static let glyphs = ["codex": "CX", "claude": "CC"]

  static func state(catalogJSON: String, labels: Labels, now: Date = Date()) -> LodyActivityAttributes.ContentState {
    let root = (try? JSONSerialization.jsonObject(with: Data(catalogJSON.utf8))) as? [String: Any]
    let sessions = (root?["sessions"] as? [[String: Any]]) ?? []
    return state(sessions: sessions, labels: labels, now: now)
  }

  static func state(sessions: [[String: Any]], labels: Labels, now: Date = Date()) -> LodyActivityAttributes.ContentState {
    let requestedAt = now.timeIntervalSince1970 * 1000
    let items = sessions.compactMap { item($0, labels: labels, requestedAt: requestedAt) }
    var counts = LodyActivityAttributes.ContentState.Counts()
    counts.permission = items.count { $0.status == .permission }
    counts.running = items.count { $0.status == .running }
    var copy = LodyActivityAttributes.ContentState.Copy(stale: labels.stale, empty: labels.empty, others: labels.others, lastSync: labels.lastSync, openHint: labels.openHint)
    copy.runningSummary = labels.runningSummary
    copy.completedSummary = labels.completedSummary
    copy.completedLabel = labels.completed
    copy.failedLabel = labels.failed
    copy.failedSummary = labels.failedSummary
    copy.elapsed = labels.elapsed
    copy.waiting = labels.waiting
    copy.took = labels.took
    copy.allow = labels.allow
    copy.deny = labels.deny
    return LodyActivityAttributes.ContentState(
      totalCount: items.count,
      statusCounts: counts,
      items: items,
      permissionAlert: nil,
      copy: copy
    )
  }

  /// The catalog the app reads holds no reasoning, current tool or permission
  /// choices; a LAN host pushes them. A local refresh keeps what the host sent
  /// for a session that is still in the same state.
  static func carryingRemoteDetail(
    _ state: LodyActivityAttributes.ContentState,
    from previous: LodyActivityAttributes.ContentState
  ) -> LodyActivityAttributes.ContentState {
    var merged = state
    let earlier = Dictionary(previous.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    for index in merged.items.indices {
      guard let before = earlier[merged.items[index].id], before.status == merged.items[index].status else { continue }
      merged.items[index].machineName = merged.items[index].machineName ?? before.machineName
      merged.items[index].activity = merged.items[index].activity ?? before.activity
      merged.items[index].thought = merged.items[index].thought ?? before.thought
      if merged.items[index].permissionOptions == nil {
        merged.items[index].permissionOptions = before.permissionOptions
        merged.items[index].permissionRequestId = merged.items[index].permissionRequestId ?? before.permissionRequestId
        merged.items[index].permissionCommand = merged.items[index].permissionCommand ?? before.permissionCommand
      }
    }
    return merged
  }

  static func failedSessionIds(sessions: [[String: Any]]) -> Set<String> {
    Set(sessions.compactMap { session in
      guard session["status"] as? String == "error", let id = session["id"] as? String else { return nil }
      return id
    })
  }

  private static func item(_ session: [String: Any], labels: Labels, requestedAt: Double) -> Item? {
    guard let id = session["id"] as? String, session["archived"] as? Bool != true else { return nil }
    let awaiting = session["awaitingUserSince"] as? Double
    let lastRunningSeen = session["lastRunningSeen"] as? Double
    let status = resolveStatus(awaiting: awaiting, status: session["status"] as? String, lastRunningSeen: lastRunningSeen, now: requestedAt)
    guard let status else { return nil }
    let agent = session["agentType"] as? String ?? session["cliType"] as? String ?? ""
    let lastMessageAt = session["lastMessageAt"] as? Double
    let stamps = [awaiting, lastMessageAt].compactMap { $0 }
    return Item(
      id: id,
      status: status,
      statusLabel: status == .permission ? labels.permission : labels.running,
      permissionRequestId: nil,
      permissionCommand: nil,
      agentLogoKind: agent,
      agentLogoText: glyph(agent),
      title: session["title"] as? String ?? "",
      updatedAt: stamps.max() ?? requestedAt,
      updatedAtLabel: "",
      startedAt: startedAt(status: status, awaiting: awaiting, lastRunningSeen: lastRunningSeen, lastMessageAt: lastMessageAt)
    )
  }

  // lastMessageAt is written when a turn completes, so a lastRunningSeen behind it
  // belongs to an earlier turn and must not seed this one's timer.
  static func startedAt(status: LodyActivityAttributes.ContentState.Item.Status, awaiting: Double?, lastRunningSeen: Double?, lastMessageAt: Double?) -> Double? {
    let turnStart = lastRunningSeen.flatMap { $0 >= (lastMessageAt ?? 0) ? $0 : nil }
    switch status {
    case .permission, .question: return awaiting ?? turnStart
    case .running: return turnStart
    case .unread, .failed: return nil
    }
  }

  /// Lody's `resolveStatus` without presence (`live-activity-summary.ts`): an
  /// active status counts only while its heartbeat is fresh
  /// (`isSessionActiveWithHeartbeat`), so a machine that dropped off mid-turn
  /// or mid-request ends the activity instead of holding it open. Lody shows a
  /// question as a permission request; `awaitingUserSince` only marks a live
  /// session as waiting, it never revives one whose heartbeat stopped.
  /// Times are milliseconds against the device clock; Lody compares with its
  /// server-corrected clock, so a device clock skewed by minutes skews this.
  static func resolveStatus(awaiting: Double?, status: String?, lastRunningSeen: Double?, now: Double) -> LodyActivityAttributes.ContentState.Item.Status? {
    guard let status, attentionStatuses.contains(status) || runningStatuses.contains(status) else { return nil }
    guard isHeartbeatFresh(lastRunningSeen, now: now) else { return nil }
    if attentionStatuses.contains(status) || awaiting != nil { return .permission }
    return .running
  }

  static func isHeartbeatFresh(_ lastRunningSeen: Double?, now: Double) -> Bool {
    guard let lastRunningSeen, lastRunningSeen.isFinite else { return false }
    return now - lastRunningSeen < heartbeatTTL
  }

  /// When the first session that counts as live now stops counting without any
  /// catalog change: a machine that went silent writes nothing more.
  static func nextHeartbeatExpiry(sessions: [[String: Any]], now: Date = Date()) -> Double? {
    let at = now.timeIntervalSince1970 * 1000
    return sessions.compactMap { session -> Double? in
      guard session["archived"] as? Bool != true, let seen = session["lastRunningSeen"] as? Double,
            resolveStatus(awaiting: session["awaitingUserSince"] as? Double, status: session["status"] as? String, lastRunningSeen: seen, now: at) != nil
      else { return nil }
      return seen + heartbeatTTL
    }.min()
  }

  private static func glyph(_ agent: String) -> String {
    if let known = glyphs[agent.lowercased()] { return known }
    let letters = agent.filter(\.isLetter).prefix(2).uppercased()
    return letters.isEmpty ? "AC" : letters
  }
}
