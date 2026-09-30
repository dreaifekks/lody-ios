import Foundation

// swiftc ../../ios/Auth/LanInvite.swift main.swift -o /tmp/lan-invite && /tmp/lan-invite
// Expected ids come from Lody's `deriveLanHubId` / `deriveLanHubUserId` (Node sha256).

let token = "test-Token_0.~+/="
let invite = try LanInvite.parse("  lody-lan://test-Token_0.~%2B%2F%3D@100.64.0.1:8788/Home%20%20LAN \n")
assert(invite.url == "http://100.64.0.1:8788", invite.url)
assert(invite.token == token, invite.token)
assert(invite.name == "Home LAN", String(describing: invite.name))
assert(invite.id == "13be09de9d11c08582ccb5d76d588f0b", invite.id)
assert(invite.workspaceId == "lw_13be09de9d11c08582ccb5d76d588f0b", invite.workspaceId)
assert(invite.userId == "local:81fc5d2883ce584af028cac5bb25fa2a", invite.userId)

let unnamed = try LanInvite.parse("LODY-LANS://abc@Hub.Example.ts.net")
assert(unnamed.url == "https://hub.example.ts.net", unnamed.url)
assert(unnamed.name == nil && unnamed.displayName == LanInvite.defaultName)

let defaultPort = try LanInvite.parse("lody-lans://abc@hub.example:443/")
assert(defaultPort.url == "https://hub.example", defaultPort.url)
let ipv6 = try LanInvite.parse("lody-lan://abc@[fd7a:115c::1]:8788")
assert(ipv6.url == "http://[fd7a:115c::1]:8788", ipv6.url)

func rejects(_ input: String, _ failure: LanInvite.Failure) {
  do { _ = try LanInvite.parse(input); assertionFailure("accepted \(input)") }
  catch { assert(error as? LanInvite.Failure == failure, "\(input): \(error)") }
}
rejects("http://abc@hub:8788", .invalidInvite)
rejects("lody-lan://hub:8788", .invalidInvite)
rejects("lody-lan://abc:secret@hub:8788", .invalidInvite)
rejects("lody-lan://abc@hub:8788?x=1", .invalidInvite)
rejects("lody-lan://a%20b@hub:8788", .invalidToken)
rejects("lody-lan://abc@hub:8788/\(String(repeating: "x", count: 41))", .invalidName)

assert(LanInvite.isWorkspace(invite.workspaceId) && !LanInvite.isWorkspace("org_123"))
let encoded = try JSONEncoder().encode(invite)
assert(try JSONDecoder().decode(LanInvite.self, from: encoded) == invite)

print("PASS: invite parsing, Lody-compatible LAN ids, rejection of malformed invites")
