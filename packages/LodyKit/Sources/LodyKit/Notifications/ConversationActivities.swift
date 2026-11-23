@preconcurrency import ActivityKit
import Foundation
@preconcurrency import OneSignalLiveActivities
import UIKit

/// Serialize ActivityKit writes while coalescing catalog changes during an in-flight update.
@MainActor
final class ConversationActivities {
  typealias Attributes = LodyConversationLiveActivityAttributes

  static let shared = ConversationActivities()

  /// Matches Lody LAN Hub's `HEARTBEAT_TTL_MS` (`session-status-machine.ts`)
  /// and `live-activity-summary.ts`. Unlike upstream Cloud, our LAN fork CLI
  /// (`session-active-presence.ts`, `RUNNING_SEEN_REFRESH_MS = 50_000`) refreshes
  /// durable `lastRunningSeen` every ~60s for active LAN sessions specifically
  /// for Live Activities, so long-running turns stay alive while offline hosts
  /// expire after 180s and never fight with Hub's `catchUp`/`sweep` end events.
  static let lanHeartbeatTTL: Double = 180_000
  /// Matches Lody's `hub-push.ts` `STALE_AFTER_S` (30 minutes) so local
  /// updates never shorten the Hub's stale window below its 10-minute refresh cadence.
  static let lanStaleInterval: TimeInterval = 30 * 60
  static let cloudStaleInterval: TimeInterval = 5 * 60

  private static let lanRunningStatuses: Set<String> = [
    "running", "initializing", "processing", "in_progress", "queued",
  ]
  private static let lanAttentionStatuses: Set<String> = [
    "requestPermission", "waiting",
  ]

  /// Live Activities and their Dynamic Island/lock-screen UI require iOS 17;
  /// earlier systems disable the feature entirely so settings can hide it.
  static var supported: Bool {
    if #available(iOS 17.0, *) { return true }
    return false
  }

  private struct LanTrackedActivity {
    let expectedId: String
    let generation: Int
    var lastToken: Data?
    let tokenTask: Task<Void, Never>
    let stateTask: Task<Void, Never>
  }

  private var pending = false
  private var worker: Task<Void, Never>?
  private var heartbeatTask: Task<Void, Never>?
  private var workStarts: [String: Double] = [:]
  private var lanInvite: LanInvite?
  private var lanObservers: [Task<Void, Never>] = []
  private var lanTracked: [String: LanTrackedActivity] = [:]

  static func activityId(workspaceId: String, userId: String) -> String {
    "lody-conversations:v5:\(workspaceId):\(userId)"
  }

  func refresh() {
    reconcileLanTokens()
    pending = true
    guard worker == nil else { return }
    worker = Task {
      while pending {
        pending = false
        await reconcile()
      }
      worker = nil
    }
  }

  /// Called at process launch (including background push-to-start wakeups without
  /// a scene), on LAN auth transitions, and when Live Activities settings change.
  func reconcileLanTokens() {
    guard !LodyUIVerify.enabled, !LodyUIVerify.offline else { return }
    let invite = (Self.supported && LodyPreferences.liveActivitiesEnabled && PushNotifications.shared.lanMode
      && ActivityAuthorizationInfo().areActivitiesEnabled) ? LanPush.shared.invite : nil
    if invite == lanInvite {
      if let invite { syncCurrentLanActivities(invite: invite) }
      return
    }
    tearDownLanObservers()
    lanInvite = invite
    guard let invite else {
      LanPush.shared.setPushToStart(nil)
      LanPush.shared.clearActivities()
      return
    }
    if #available(iOS 17.2, *), let token = Activity<Attributes>.pushToStartToken {
      LanPush.shared.setPushToStart(token)
    }
    let hasPendingActivity = syncCurrentLanActivities(invite: invite)
    lanObservers.append(Task { [weak self] in
      for await activity in Activity<Attributes>.activityUpdates {
        guard !Task.isCancelled else { return }
        self?.observeLan(activity, invite: invite)
      }
    })
    if #available(iOS 17.2, *) {
      lanObservers.append(Task {
        for await token in Activity<Attributes>.pushToStartTokenUpdates {
          guard !Task.isCancelled else { return }
          LanPush.shared.setPushToStart(token)
        }
      })
    }
    if UIApplication.shared.applicationState == .background {
      LanPush.shared.holdBackgroundWake(waitingForActivityToken: hasPendingActivity)
    }
  }

  /// Prunes dead tracked activities and re-checks current tokens on foreground return.
  func recoverLanTokens() {
    reconcileLanTokens()
  }

  private func tearDownLanObservers() {
    lanObservers.forEach { $0.cancel() }
    lanObservers.removeAll()
    for tracked in lanTracked.values {
      tracked.tokenTask.cancel()
      tracked.stateTask.cancel()
    }
    lanTracked.removeAll()
  }

  @discardableResult
  private func syncCurrentLanActivities(invite: LanInvite) -> Bool {
    let expectedId = Self.activityId(workspaceId: invite.workspaceId, userId: invite.userId)
    // Order oldest-first so the newest live activity claims the highest ownership generation.
    let liveActivities = Activity<Attributes>.activities
      .filter { $0.attributes.activityId == expectedId && Self.isLive($0.activityState) }
      .sorted { lhs, rhs in
        if lhs.content.state.updatedAt != rhs.content.state.updatedAt {
          return lhs.content.state.updatedAt < rhs.content.state.updatedAt
        }
        return lhs.id < rhs.id
      }
    let liveIds = Set(liveActivities.map(\.id))
    for nativeId in Array(lanTracked.keys) where !liveIds.contains(nativeId) {
      stopTrackingLan(nativeId: nativeId)
    }
    var awaitingToken = false
    for activity in liveActivities {
      observeLan(activity, invite: invite)
      if activity.pushToken == nil { awaitingToken = true }
    }
    if #available(iOS 17.2, *), let token = Activity<Attributes>.pushToStartToken {
      LanPush.shared.setPushToStart(token)
    }
    return awaitingToken
  }

  private func observeLan(_ activity: Activity<Attributes>, invite: LanInvite) {
    let expectedId = Self.activityId(workspaceId: invite.workspaceId, userId: invite.userId)
    guard activity.attributes.activityId == expectedId,
          Self.isLive(activity.activityState) else { return }
    let nativeId = activity.id
    if var existing = lanTracked[nativeId] {
      // Foreground recovery can see a pushToken before an existing stream wakes up;
      // reconcile the token directly while deduplicating observer tasks.
      if let currentToken = activity.pushToken, currentToken != existing.lastToken {
        existing.lastToken = currentToken
        lanTracked[nativeId] = existing
        LanPush.shared.enter(expectedId, token: currentToken, nativeId: nativeId)
      }
      return
    }
    let generation = LanPush.shared.claimActivity(nativeId: nativeId)
    let initialToken = activity.pushToken
    if let initialToken {
      LanPush.shared.enter(expectedId, token: initialToken, nativeId: nativeId)
    } else if UIApplication.shared.applicationState == .background {
      LanPush.shared.holdBackgroundWake(waitingForActivityToken: true)
      LanPush.shared.markPendingActivity(nativeId: nativeId)
    }
    let tokenTask = Task { [weak self] in
      for await token in activity.pushTokenUpdates {
        guard !Task.isCancelled else { return }
        guard let self, self.lanInvite == invite else { return }
        guard Self.isLive(activity.activityState) else {
          self.stopTrackingLan(nativeId: nativeId)
          return
        }
        self.lanTracked[nativeId]?.lastToken = token
        LanPush.shared.enter(expectedId, token: token, nativeId: nativeId)
      }
      if !Task.isCancelled {
        self?.stopTrackingLan(nativeId: nativeId)
      }
    }
    let stateTask = Task { [weak self] in
      for await state in activity.activityStateUpdates {
        guard !Task.isCancelled else { return }
        guard let self, self.lanInvite == invite else { return }
        if !Self.isLive(state) {
          self.stopTrackingLan(nativeId: nativeId)
          return
        }
      }
    }
    lanTracked[nativeId] = LanTrackedActivity(
      expectedId: expectedId,
      generation: generation,
      lastToken: initialToken,
      tokenTask: tokenTask,
      stateTask: stateTask
    )
  }

  private func stopTrackingLan(nativeId: String) {
    guard let tracked = lanTracked.removeValue(forKey: nativeId) else { return }
    tracked.tokenTask.cancel()
    tracked.stateTask.cancel()
    let replacement = lanTracked
      .filter { $0.value.expectedId == tracked.expectedId && $0.value.lastToken != nil }
      .max { $0.value.generation < $1.value.generation }
    if let replacement, let token = replacement.value.lastToken {
      LanPush.shared.replaceActivity(
        tracked.expectedId,
        departingNativeId: nativeId,
        replacementNativeId: replacement.key,
        replacementToken: token
      )
    } else {
      LanPush.shared.markActivityStopped(nativeId: nativeId)
      LanPush.shared.exit(tracked.expectedId, ifToken: tracked.lastToken, nativeId: nativeId)
    }
  }

  private static func isLive(_ state: ActivityState) -> Bool {
    state == .active || state == .stale
  }

  private func cancelHeartbeat() {
    heartbeatTask?.cancel()
    heartbeatTask = nil
  }

  private func scheduleLanHeartbeat(list: SessionListState, isLAN: Bool, now: Double) {
    cancelHeartbeat()
    guard isLAN, let expiry = Self.nextLanHeartbeatExpiry(list, now: now) else { return }
    let waitMs = min(max(0, expiry - now) + 1000, Self.lanHeartbeatTTL * 2)
    heartbeatTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(Int64(waitMs.rounded(.up))))
      guard !Task.isCancelled else { return }
      self?.refresh()
    }
  }

  private func pinWorkStarts(_ state: inout Attributes.ContentState) {
    var kept: [String: Double] = [:]
    for index in state.items.indices {
      let item = state.items[index]
      guard item.status == .running || item.status == .permission || item.status == .question,
            let started = item.startedAt else { continue }
      let pinned = min(started, workStarts[item.id] ?? started)
      kept[item.id] = pinned
      state.items[index].startedAt = pinned
    }
    workStarts = kept
  }

  private func reconcile() async {
    let list = SessionPublished.state()
    let workspace = list.workspace
    let isLAN = LanInvite.isWorkspace(list.workspaceId)
    let enabled = Self.supported && LodyPreferences.liveActivitiesEnabled
      && workspace?.resolvedMode == .plaintext && !list.userId.isEmpty
      && ActivityAuthorizationInfo().areActivitiesEnabled
    let id = Self.activityId(workspaceId: list.workspaceId, userId: list.userId)
    var existing: Activity<Attributes>?
    var endedMatching: [Activity<Attributes>] = []
    for activity in Activity<Attributes>.activities {
      let live = Self.isLive(activity.activityState)
      if enabled, activity.attributes.activityId == id {
        if live, existing == nil {
          existing = activity
        } else if live {
          if isLAN { stopTrackingLan(nativeId: activity.id) }
          await activity.end(nil, dismissalPolicy: .immediate)
          if pending { return }
        } else if activity.activityState == .ended {
          endedMatching.append(activity)
        }
      } else {
        stopTrackingLan(nativeId: activity.id)
        await activity.end(nil, dismissalPolicy: .immediate)
        if pending { return }
      }
    }
    guard enabled, let workspace, !list.loading else {
      cancelHeartbeat()
      return
    }
    // Wait for a live LAN catalog before updating or ending a Hub-pushed activity;
    // a stale cached disk catalog must not tear down active work on launch.
    if isLAN, !list.connected {
      cancelHeartbeat()
      return
    }

    let nowDate = Date()
    let nowMs = nowDate.timeIntervalSince1970 * 1000
    var state = Self.summary(list, now: nowMs)
    scheduleLanHeartbeat(list: list, isLAN: isLAN, now: nowMs)

    guard !state.items.isEmpty else {
      workStarts.removeAll()
      if let existing {
        if isLAN { stopTrackingLan(nativeId: existing.id) }
        await existing.end(nil, dismissalPolicy: .immediate)
      }
      return
    }
    if isLAN {
      pinWorkStarts(&state)
      if let existing {
        state = Self.carryingRemoteDetail(state, from: existing.content.state)
        pinWorkStarts(&state)
      }
    }
    let staleInterval = isLAN ? Self.lanStaleInterval : Self.cloudStaleInterval
    let content = ActivityContent(state: state, staleDate: nowDate.addingTimeInterval(staleInterval))
    if let existing {
      let isStale = existing.activityState == .stale
      if Self.needsLocalUpdate(existing: existing.content.state, next: state, isStale: isStale, isLAN: isLAN) {
        await existing.update(content)
      }
    } else {
      for ended in endedMatching {
        await ended.end(nil, dismissalPolicy: .immediate)
        if pending { return }
      }
      let slug = isLAN ? LanInvite.workspaceSlug : workspace.slug
      let attributes = Attributes(activityId: id, workspaceId: workspace.id, workspaceSlug: slug,
                                  workspaceName: workspace.name, onesignal: .create(activityId: id))
      do {
        let started = try Activity.request(attributes: attributes, content: content, pushType: .token)
        if let invite = lanInvite { observeLan(started, invite: invite) }
      } catch {
        DiagnosticsStore.shared.record("notification", "activity_start_failed")
      }
    }
  }

  static func isLanHeartbeatFresh(_ lastRunningSeen: Double?, now: Double) -> Bool {
    guard let lastRunningSeen, lastRunningSeen.isFinite else { return false }
    return now - lastRunningSeen < lanHeartbeatTTL
  }

  static func lanActiveStatus(_ session: SessionItem, now: Double) -> LodyConversationActivityStatus? {
    guard !session.archived else { return nil }
    let raw = session.status
    guard lanAttentionStatuses.contains(raw) || lanRunningStatuses.contains(raw) else { return nil }
    guard isLanHeartbeatFresh(session.lastRunningSeen, now: now) else { return nil }
    if raw == "requestPermission" { return .permission }
    if lanAttentionStatuses.contains(raw) || session.awaitingUserSince != nil { return .question }
    return .running
  }

  static func nextLanHeartbeatExpiry(_ list: SessionListState, now: Double) -> Double? {
    list.catalog.sessions.compactMap { session -> Double? in
      guard let seen = session.lastRunningSeen, lanActiveStatus(session, now: now) != nil else { return nil }
      return seen + lanHeartbeatTTL
    }.min()
  }

  /// Preserves Hub-pushed live progress (`activity`, `thought`, `startedAt`,
  /// `machineName`, and interactive permission fields) across local catalog refreshes.
  static func carryingRemoteDetail(
    _ state: Attributes.ContentState,
    from previous: Attributes.ContentState
  ) -> Attributes.ContentState {
    var merged = state
    let earlier = Dictionary(previous.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    for index in merged.items.indices {
      guard let before = earlier[merged.items[index].id],
            before.status == merged.items[index].status else { continue }
      merged.items[index].machineName = merged.items[index].machineName ?? before.machineName
      merged.items[index].activity = merged.items[index].activity ?? before.activity
      merged.items[index].thought = merged.items[index].thought ?? before.thought
      if let localStart = merged.items[index].startedAt, let remoteStart = before.startedAt {
        merged.items[index].startedAt = min(localStart, remoteStart)
      } else {
        merged.items[index].startedAt = merged.items[index].startedAt ?? before.startedAt
      }
      if merged.items[index].permissionOptions == nil {
        merged.items[index].permissionOptions = before.permissionOptions
        merged.items[index].permissionRequestId = merged.items[index].permissionRequestId ?? before.permissionRequestId
        merged.items[index].permissionCommand = merged.items[index].permissionCommand ?? before.permissionCommand
        merged.items[index].permissionResponseState = merged.items[index].permissionResponseState ?? before.permissionResponseState
      }
    }
    return trimToBudget(merged)
  }

  static func needsLocalUpdate(
    existing: Attributes.ContentState,
    next: Attributes.ContentState,
    isStale: Bool,
    isLAN: Bool
  ) -> Bool {
    if isStale { return true }
    if !isLAN {
      return existing.items != next.items || existing.statusCounts != next.statusCounts
    }
    if existing.totalCount != next.totalCount || existing.statusCounts != next.statusCounts {
      return true
    }
    return lanComparisonItems(existing.items) != lanComparisonItems(next.items)
  }

  private struct LanComparableItem: Equatable {
    let id: String
    let status: LodyConversationActivityStatus
    let title: String
    let machineName: String?
    let agentLogoKind: String
    let startedAtSeconds: Int?
    let activity: String?
    let thought: String?
    let permissionRequestId: String?
    let permissionCommand: String?
    let permissionResponseState: LodyPermissionResponseState?
    let permissionOptions: [Attributes.PermissionOption]?
  }

  private static func lanComparisonItems(_ items: [Attributes.ConversationItem]) -> [LanComparableItem] {
    items.map { item in
      LanComparableItem(
        id: item.id,
        status: item.status,
        title: item.title,
        machineName: item.machineName,
        agentLogoKind: item.agentLogoKind,
        startedAtSeconds: item.startedAt.map { Int(($0 / 1000).rounded()) },
        activity: item.activity,
        thought: item.thought,
        permissionRequestId: item.permissionRequestId,
        permissionCommand: item.permissionCommand,
        permissionResponseState: item.permissionResponseState,
        permissionOptions: item.permissionOptions
      )
    }
  }

  static func summary(_ list: SessionListState, now: Double = Date().timeIntervalSince1970 * 1000) -> Attributes.ContentState {
    var counts = Attributes.ContentState.StatusCounts(permission: 0, question: 0, running: 0, unread: 0)
    let isLAN = LanInvite.isWorkspace(list.workspaceId)
    let multiMachine = list.catalog.machineIds.count > 1
    var rows: [(Int, SessionItem, LodyConversationActivityStatus)] = []
    for session in list.catalog.sessions where !session.archived && (isLAN || session.userId == list.userId) {
      if isLAN {
        guard let status = lanActiveStatus(session, now: now) else { continue }
        switch status {
        case .question:
          counts.question += 1
          rows.append((0, session, .question))
        case .permission:
          counts.permission += 1
          rows.append((1, session, .permission))
        case .running:
          counts.running += 1
          rows.append((2, session, .running))
        case .unread, .failed:
          continue
        }
        continue
      }
      switch SessionState(session) {
      case .attention where session.status == "requestPermission":
        counts.permission += 1
        rows.append((1, session, .permission))
      case .attention:
        counts.question += 1
        rows.append((0, session, .question))
      case .live:
        counts.running += 1
        rows.append((2, session, .running))
      default:
        guard SessionRows.isUnread(session) else { continue }
        counts.unread += 1
        rows.append((3, session, .unread))
      }
    }
    func stamp(_ session: SessionItem) -> Double { session.activityAt.isFinite ? session.activityAt : 0 }
    rows.sort {
      if $0.0 != $1.0 { return $0.0 < $1.0 }
      if stamp($0.1) != stamp($1.1) { return stamp($0.1) > stamp($1.1) }
      return $0.1.id < $1.1.id
    }
    let items = rows.prefix(4).map { _, session, status in
      let kind = normalizedAgentKind(session)
      let machine = isLAN && multiMachine ? list.catalog.machineNames[session.machineId] : nil
      let startedAt = isLAN ? lanStartedAt(session: session, status: status) : nil
      let updatedAtLabel = isLAN ? "" : LodyRelativeTime.compact(session.activityAt, now: now)
      return Attributes.ConversationItem(
        id: session.id,
        status: status,
        statusLabel: status.rawValue,
        agentLogoKind: kind,
        agentLogoText: agentGlyphText(kind),
        title: String(session.title.prefix(96)),
        updatedAt: stamp(session),
        updatedAtLabel: updatedAtLabel,
        startedAt: startedAt,
        machineName: machine
      )
    }
    let state = Attributes.ContentState(totalCount: rows.count, statusCounts: counts, items: items, updatedAt: now)
    return trimToBudget(state)
  }

  private static func lanStartedAt(session: SessionItem, status: LodyConversationActivityStatus) -> Double? {
    let lastMessageAt = session.lastMessageAt ?? 0
    let turnStart = session.lastRunningSeen.flatMap { $0.isFinite && $0 >= lastMessageAt ? $0 : nil }
    switch status {
    case .permission, .question:
      return session.awaitingUserSince ?? turnStart
    case .running:
      return turnStart
    case .unread, .failed:
      return nil
    }
  }

  private static func normalizedAgentKind(_ session: SessionItem) -> String {
    let raw = session.agentType.isEmpty ? session.cliType : session.agentType
    if raw == "claude-p" { return "claude" }
    return raw
  }

  private static func agentGlyphText(_ kind: String) -> String {
    switch kind.lowercased() {
    case "codex": return "CX"
    case "claude": return "CC"
    case "antigravity-acp", "antigravity": return "AG"
    default:
      let letters = kind.filter(\.isLetter).prefix(2).uppercased()
      return letters.isEmpty ? "AC" : letters
    }
  }

  private static func trimToBudget(_ input: Attributes.ContentState) -> Attributes.ContentState {
    var state = input
    while !state.items.isEmpty, (try? JSONEncoder().encode(state).count) ?? Int.max > 4000 {
      if let index = state.items.indices.reversed().first(where: { state.items[$0].thought != nil || state.items[$0].activity != nil }) {
        state.items[index].thought = nil
        state.items[index].activity = nil
      } else {
        state.items.removeLast()
      }
    }
    return state
  }
}
