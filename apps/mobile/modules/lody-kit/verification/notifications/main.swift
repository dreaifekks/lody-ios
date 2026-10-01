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

print("PASS: launch permission request, cold click retention, latest-intent acknowledgement, account/logout isolation, subscription placeholders")
