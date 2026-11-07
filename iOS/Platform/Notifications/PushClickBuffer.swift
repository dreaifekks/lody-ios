import Foundation

/// One pending user intent survives bridge recreation, but never account replacement.
struct PushClickBuffer {
  private(set) var pending: [String: String]?

  mutating func receive(id: String, route: String, userId: String) {
    guard !id.isEmpty, !userId.isEmpty, route.hasPrefix("/"), route.utf8.count <= 2048 else { return }
    pending = ["id": id, "route": route, "userId": userId]
  }

  mutating func acknowledge(_ id: String) {
    if pending?["id"] == id { pending = nil }
  }

  mutating func identify(_ userId: String?) {
    if userId == nil || (pending != nil && pending?["userId"] != userId) { pending = nil }
  }

  static func isRegistered(_ id: String?) -> Bool {
    id.map { !$0.isEmpty && !$0.hasPrefix("local-") } ?? false
  }
}

/// Permission notifications a LAN hub sent, and which of them no longer ask
/// anything. The hub's request uses collapse id `permission-<requestId>`, the
/// request identifier on iOS, and once it is answered sends a quiet
/// `permission-resolved` replacement under the same id.
enum PermissionNotices {
  static let requested = "permission-requested"
  static let resolved = "permission-resolved"
  /// A catalog can trail the push announcing a request; one read this soon
  /// after delivery may not show the request yet.
  static let catalogLag: TimeInterval = 15

  struct Delivered: Sendable {
    var identifier: String
    var kind: String?
    var sessionId: String?
    var recipient: String?
    var date: Date

    init(identifier: String, userInfo: [AnyHashable: Any], threadId: String, date: Date) {
      self.identifier = identifier
      kind = userInfo["lodyKind"] as? String
      let session = userInfo["sessionId"] as? String
      sessionId = session.flatMap { $0.isEmpty ? nil : $0 } ?? (threadId.isEmpty ? nil : threadId)
      recipient = userInfo["recipientUserId"] as? String
      self.date = date
    }

    /// Older hubs send no `lodyKind`; their requests carry only the collapse id.
    var isPermission: Bool {
      guard let kind else { return identifier.hasPrefix("permission-") }
      return kind == PermissionNotices.requested || kind == PermissionNotices.resolved
    }
  }

  /// Whether each catalog session still waits on the user, by its durable
  /// state rather than its heartbeat: a request on a machine that went offline
  /// is still unanswered (Lody's `awaitingUserSince` contract).
  static func waitingOnUser(sessions: [[String: Any]]) -> [String: Bool] {
    var waiting: [String: Bool] = [:]
    for session in sessions {
      guard let id = session["id"] as? String else { continue }
      let status = session["status"] as? String ?? ""
      let finished = status == "completed" || status == "error"
      let asking = status == "requestPermission" || status == "waiting" || session["awaitingUserSince"] as? Double != nil
      waiting[id] = !finished && asking
    }
    return waiting
  }

  /// Identifiers to remove from Notification Center: every resolution, and
  /// requests whose session a catalog read well after delivery shows no longer
  /// waiting. A session the catalog does not list yet keeps its request.
  static func withdrawable(_ delivered: [Delivered], userId: String, waiting: [String: Bool]?, catalogAt: Date?) -> [String] {
    guard !userId.isEmpty else { return [] }
    return delivered.compactMap { notice in
      guard notice.isPermission, notice.recipient == nil || notice.recipient == userId else { return nil }
      if notice.kind == resolved { return notice.identifier }
      guard let catalogAt, let sessionId = notice.sessionId, waiting?[sessionId] == false,
            notice.date <= catalogAt.addingTimeInterval(-catalogLag) else { return nil }
      return notice.identifier
    }
  }
}
