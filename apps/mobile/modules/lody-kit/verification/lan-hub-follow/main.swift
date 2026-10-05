import Foundation

// swiftc -swift-version 6 ../../ios/Auth/LanInvite.swift ../../ios/Auth/AuthKeychain.swift ../../ios/Auth/LanHub.swift \
//   ../../ios/Auth/LanHubFollower.swift ../../ios/LanTerminal/LanTerminalLink.swift ../../ios/LanTerminal/LanFileChannel.swift \
//   main.swift -o /tmp/lan-hub-follow && /tmp/lan-hub-follow
// Signatures come from Lody's `signLanHubMove` / `signLanHubLocation` (Node
// crypto) for the token below; the rules mirror `LanMembership.adopt`.

func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "", line: Int = #line) {
  if !condition() {
    FileHandle.standardError.write(Data("FAIL line \(line): \(message())\n".utf8))
    exit(1)
  }
}

let token = "test-Token_0.~+/="
let invite = LanInvite(url: "http://100.64.0.1:8788", token: token, name: "Home")
let moved = "5f58a5b180259d4b5a96c148c7ae3e794fe6432ec544e137a6dac1d89685ba7e"
let located = "6cd9c4218b03fba0a8a61393e931eba1d3233a0d589f59b682fc1f563c5a9935"

// `normalizeLanHubUrl` is `new URL(…).origin`.
check(LanHubFollower.normalize("HTTP://Hub.Example:80/") == "http://hub.example")
check(LanHubFollower.normalize("https://hub.example:443") == "https://hub.example")
check(LanHubFollower.normalize("http://[fd7a:115c::1]:8788/") == "http://[fd7a:115c::1]:8788")
check(LanHubFollower.normalize("http://hub.example/ds") == nil)
check(LanHubFollower.normalize("ftp://hub.example") == nil)
check(LanHubFollower.normalize("http://user:pw@hub.example") == nil)

// A pointer from a build with terms signs the term with the address.
let termed: [String: Any] = ["error": "moved", "movedTo": "http://100.64.0.9:8788", "signature": moved,
                             "term": 3, "termSignature": located]
typealias Location = LanHubFollower.Location
check(LanHubFollower.verify(termed, token: token) == Location(url: "http://100.64.0.9:8788", term: 3))
// A build without terms signs the address alone.
check(LanHubFollower.verify(["movedTo": "http://100.64.0.9:8788/", "signature": moved], token: token)
  == Location(url: "http://100.64.0.9:8788", term: nil))
// Another token, another address, another term, or a term without its signature is refused.
check(LanHubFollower.verify(termed, token: "other") == nil)
check(LanHubFollower.verify(termed.merging(["movedTo": "http://100.64.0.10:8788"]) { $1 }, token: token) == nil)
check(LanHubFollower.verify(termed.merging(["term": 4]) { $1 }, token: token) == nil)
check(LanHubFollower.verify(["movedTo": "http://100.64.0.9:8788", "signature": moved, "term": 3], token: token) == nil)
check(LanHubFollower.verify(["movedTo": "http://100.64.0.9:8788", "signature": "zz"], token: token) == nil)

// A later term wins; within a term, the address that sorts first.
let followed = LanHubFollower.adopt(invite, .init(url: "http://100.64.0.9:8788", term: 3))
check(followed?.url == "http://100.64.0.9:8788" && followed?.term == 3 && followed?.token == token)
check(followed?.workspaceId == invite.workspaceId && followed?.userId == invite.userId)
check(followed?.name == "Home")
let atThree = followed!
check(LanHubFollower.adopt(atThree, .init(url: "http://100.64.0.1:8788", term: 2)) == nil)
check(LanHubFollower.adopt(atThree, .init(url: "http://100.64.0.9:9999", term: 3)) == nil)
// Strings compare as Lody's do: ".10" sorts before ".9".
check(LanHubFollower.adopt(atThree, .init(url: "http://100.64.0.10:8788", term: 3))?.url == "http://100.64.0.10:8788")
check(LanHubFollower.adopt(atThree, .init(url: "http://100.64.0.1:8788", term: 3))?.url == "http://100.64.0.1:8788")
// A hub without terms points somewhere later than anything known.
check(LanHubFollower.adopt(atThree, .init(url: "http://100.64.0.2:8788", term: nil))?.term == 4)
check(LanHubFollower.adopt(atThree, .init(url: atThree.url, term: 5))?.url == atThree.url)

// An invite saved before terms decodes; one with a term keeps it.
let legacy = try JSONDecoder().decode(LanInvite.self, from: Data(#"{"url":"http://h:1","token":"t","name":null}"#.utf8))
check(legacy.term == nil)
let roundTrip = try JSONDecoder().decode(LanInvite.self, from: try JSONEncoder().encode(atThree))
check(roundTrip == atThree)

// Members come from the projected catalog's `machineTerminals`.
let members = LanHubFollower.members(catalog: #"{"machineTerminals":{"m1":{"host":"100.64.0.5","port":8789},"bad":{"host":" ","port":1}}}"#)
check(members.count == 1 && members[0].machineId == "m1" && members[0].endpoint == LanTerminalEndpoint(host: "100.64.0.5", port: 8789))
check(LanHubFollower.members(catalog: nil).isEmpty)

print("PASS: hub moves are followed only with the credential's signature, by Lody's term rules")
