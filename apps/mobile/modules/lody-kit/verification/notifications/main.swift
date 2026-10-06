import Foundation

var launchPermissionRequests = 0
PushPermissionLaunchRequest.perform {
  launchPermissionRequests += 1
}
precondition(launchPermissionRequests == 1, "app launch requests notification permission")

var clicks = PushClickBuffer()
clicks.receive(id: "first", route: "/work/sessions/one", userId: "alice")
precondition(clicks.pending?["id"] == "first")
clicks.identify("alice")
precondition(clicks.pending?["id"] == "first", "same-account cold restoration preserves intent")
clicks.receive(id: "second", route: "/work/sessions/two", userId: "alice")
clicks.acknowledge("first")
precondition(clicks.pending?["id"] == "second", "stale JS ack must not erase a newer click")
clicks.identify("bob")
precondition(clicks.pending == nil)
clicks.receive(id: "third", route: "/work/sessions/two", userId: "bob")
clicks.identify(nil)
precondition(clicks.pending == nil)
clicks.receive(id: "bad", route: String(repeating: "/", count: 2049), userId: "bob")
precondition(clicks.pending == nil)
for id: String? in [nil, "", "local-placeholder"] { precondition(!PushClickBuffer.isRegistered(id)) }
precondition(PushClickBuffer.isRegistered("server-assigned-subscription"))
func profile(_ environment: String) -> Data {
  Data("junk<plist><dict><key>Entitlements</key><dict><key>aps-environment</key>\n\t<string>\(environment)</string></dict></dict></plist>junk".utf8)
}
precondition(ApsEnvironment.of(profile: profile("development")) == "development", "a development-signed build registers sandbox tokens")
precondition(ApsEnvironment.of(profile: profile("production")) == "production")
precondition(ApsEnvironment.of(profile: nil) == "production", "an App Store build has no profile")
precondition(ApsEnvironment.of(profile: Data("<key>get-task-allow</key><true/>".utf8)) == "production")
print("PASS: APNs environment follows the signing profile")

// A LAN hub's permission request uses collapse id `permission-<requestId>`; an
// answer elsewhere replaces it with a quiet `permission-resolved`.
let catalogAt = Date(timeIntervalSince1970: 1_800_000_000)
func notice(_ id: String, _ info: [AnyHashable: Any], thread: String = "", at: Date = catalogAt.addingTimeInterval(-60)) -> PermissionNotices.Delivered {
  PermissionNotices.Delivered(identifier: id, userInfo: info, threadId: thread, date: at)
}
let waiting = PermissionNotices.waitingOnUser(sessions: [
  ["id": "asking", "status": "requestPermission"],
  ["id": "answered", "status": "running"],
  ["id": "offline", "status": "running", "awaitingUserSince": 1.0],
  ["id": "done", "status": "completed", "awaitingUserSince": 1.0],
])
precondition(waiting == ["asking": true, "answered": false, "offline": true, "done": false], "\(waiting)")
let delivered = [
  notice("permission-r1", ["lodyKind": "permission-resolved", "sessionId": "asking", "requestId": "r1"]),
  notice("permission-r2", ["lodyKind": "permission-requested", "sessionId": "answered", "recipientUserId": "local:me"]),
  notice("permission-r3", ["lodyKind": "permission-requested", "sessionId": "asking", "recipientUserId": "local:me"]),
  notice("permission-r4", [:], thread: "answered"),
  notice("permission-r5", ["sessionId": "unknown"]),
  notice("permission-r6", ["lodyKind": "permission-requested", "sessionId": "answered", "recipientUserId": "local:other"]),
  notice("permission-r7", ["lodyKind": "permission-requested", "sessionId": "answered"], at: catalogAt.addingTimeInterval(-5)),
  notice("permission-r8", ["lodyKind": "permission-requested", "sessionId": "offline"]),
  notice("turn-1", ["lodyKind": "turn-completed", "sessionId": "answered"]),
  notice("other", ["sessionId": "answered"]),
]
let withdrawn = PermissionNotices.withdrawable(delivered, userId: "local:me", waiting: waiting, catalogAt: catalogAt)
precondition(withdrawn == ["permission-r1", "permission-r2", "permission-r4"], "\(withdrawn)")
precondition(
  PermissionNotices.withdrawable(delivered, userId: "local:me", waiting: nil, catalogAt: nil) == ["permission-r1"],
  "without a catalog only resolutions go"
)
precondition(PermissionNotices.withdrawable(delivered, userId: "", waiting: waiting, catalogAt: catalogAt).isEmpty, "signed out settles nothing")
print("PASS: resolved permission notices and requests no longer waiting are withdrawn; unknown, recent, foreign and still-waiting ones stay")

print("PASS: launch permission request, cold click retention, latest-intent acknowledgement, account/logout isolation, subscription placeholders")
