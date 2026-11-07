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
print("PASS: launch permission request, cold click retention, latest-intent acknowledgement, account/logout isolation, subscription placeholders")

// Hub permission resolution never withdraws another account's request, and a
// catalog arriving immediately after APNs cannot erase a not-yet-synced request.
let deliveredAt = Date(timeIntervalSince1970: 100)
let requested = PermissionNotices.Delivered(identifier: "permission-request", userInfo: ["lodyKind": PermissionNotices.requested,
  "sessionId": "session", "recipientUserId": "local:alice"], threadId: "", date: deliveredAt)
let resolved = PermissionNotices.Delivered(identifier: "permission-resolved", userInfo: ["lodyKind": PermissionNotices.resolved,
  "recipientUserId": "local:alice"], threadId: "", date: deliveredAt)
precondition(PermissionNotices.withdrawable([requested, resolved], userId: "local:bob", waiting: ["session": false], catalogAt: deliveredAt.addingTimeInterval(30)).isEmpty)
precondition(PermissionNotices.withdrawable([requested], userId: "local:alice", waiting: ["session": false], catalogAt: deliveredAt.addingTimeInterval(1)).isEmpty)
precondition(PermissionNotices.withdrawable([requested, resolved], userId: "local:alice", waiting: ["session": false], catalogAt: deliveredAt.addingTimeInterval(30)) == ["permission-request", "permission-resolved"])
precondition(PermissionNotices.waitingOnUser(sessions: [["id": "session", "status": "running", "awaitingUserSince": 10.0]])["session"] == true)
print("PASS: permission catalog lag and recipient fencing")

precondition(ApsEnvironment.of(profile: nil) == "production")
precondition(ApsEnvironment.of(profile: Data("<key>aps-environment</key><string>development</string>".utf8)) == "development")
precondition(ApsEnvironment.of(profile: Data("<key>aps-environment</key><string>production</string>".utf8)) == "production")
print("PASS: APNs environment follows the signed profile")
