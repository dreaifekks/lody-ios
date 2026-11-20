@preconcurrency import ActivityKit
import Foundation
@preconcurrency import OneSignalLiveActivities

/// Serialize ActivityKit writes while coalescing catalog changes during an in-flight update.
@MainActor
final class ConversationActivities {
  typealias Attributes = LodyConversationLiveActivityAttributes
  /// Live Activities and their Dynamic Island/lock-screen UI require iOS 17;
  /// earlier systems disable the feature entirely so settings can hide it.
  static var supported: Bool {
    if #available(iOS 17.0, *) { return true }
    return false
  }

  private var pending = false
  private var worker: Task<Void, Never>?

  func refresh() {
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

  private func reconcile() async {
    let list = SessionPublished.state()
    let workspace = list.workspace
    let enabled = Self.supported && LodyPreferences.liveActivitiesEnabled
      && workspace?.resolvedMode == .plaintext && !list.userId.isEmpty
      && ActivityAuthorizationInfo().areActivitiesEnabled
    let id = "lody-conversations:v5:\(list.workspaceId):\(list.userId)"
    var existing: Activity<Attributes>?
    for activity in Activity<Attributes>.activities {
      if enabled, activity.attributes.activityId == id, existing == nil {
        existing = activity
      } else {
        await activity.end(nil, dismissalPolicy: .immediate)
        if pending { return }
      }
    }
    guard enabled, let workspace, !list.loading else { return }
    let state = Self.summary(list)
    guard !state.items.isEmpty else {
      await existing?.end(nil, dismissalPolicy: .immediate)
      return
    }
    let content = ActivityContent(state: state, staleDate: Date(timeIntervalSinceNow: 300))
    if let existing {
      let old = existing.content.state
      if old.items != state.items || old.statusCounts != state.statusCounts || existing.activityState == .stale {
        await existing.update(content)
      }
    } else {
      let attributes = Attributes(activityId: id, workspaceId: workspace.id, workspaceName: workspace.name,
                                  onesignal: .create(activityId: id))
      do {
        _ = try Activity.request(attributes: attributes, content: content, pushType: .token)
      } catch {
        DiagnosticsStore.shared.record("notification", "activity_start_failed")
      }
    }
  }

  static func summary(_ list: SessionListState) -> Attributes.ContentState {
    var counts = Attributes.ContentState.StatusCounts(permission: 0, question: 0, running: 0, unread: 0)
    let now = Date().timeIntervalSince1970 * 1000
    var rows: [(Int, SessionItem, LodyConversationActivityStatus)] = []
    for session in list.catalog.sessions where !session.archived && session.userId == list.userId {
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
      let kind = session.agentType == "claude-p" ? "claude" : session.agentType
      return Attributes.ConversationItem(id: session.id, status: status, statusLabel: status.rawValue,
        agentLogoKind: kind, agentLogoText: String(kind.prefix(2)).uppercased(),
        title: String(session.title.prefix(96)), updatedAt: stamp(session),
        updatedAtLabel: LodyRelativeTime.compact(session.activityAt, now: now))
    }
    var state = Attributes.ContentState(totalCount: rows.count, statusCounts: counts, items: items, updatedAt: now)
    while !state.items.isEmpty, (try? JSONEncoder().encode(state).count) ?? Int.max > 4000 {
      state.items.removeLast()
    }
    return state
  }
}
