import Foundation

// The production feed owns its subscription; these stubs only remove app I/O.
final class LocalStore: @unchecked Sendable {
  static let shared = LocalStore()
  static let queue = DispatchQueue(label: "fixture-cache")
  func read(_ key: String) throws -> String? { nil }
}
@MainActor final class DataRuntime {
  static var current: DataRuntime?
  func reconnectSession(_ id: String) { preconditionFailure("Unexpected live runtime") }
  func watchSession(_ id: String) { preconditionFailure("Unexpected live runtime") }
  func unwatchSession(_ id: String) { preconditionFailure("Unexpected live runtime") }
}
@MainActor final class DiagnosticsStore {
  static let shared = DiagnosticsStore()
  static func correlation(_ value: String) -> String { value }
  func record(_ category: String, _ event: String, fields: [String: String]) {}
}
@MainActor final class Fixture {
  var receive: ((SessionRuntimeEvent) -> Void)?
  var watched = 0
  var unwatched = 0
  var reconnects = 0
  nonisolated static func envelope(_ revision: Int, _ text: String, syncing: Bool = false) -> String {
    let state = syncing ? #""status":"syncing","controlReady":true,"sendReady":false"# : #""status":"live""#
    return #"{"v":1,\#(state),"revision":\#(revision),"usage":{"context":{"used":84000,"size":200000},"isContextCompacting":false},"preview":{"label":"localhost:5173","active":true},"entries":[{"id":"reply","role":"assistant","finished":true,"items":[{"type":"text","text":"\#(text)"}]}]}"#
  }
  var service: SessionFeedService {
    .init(watch: { _, receive in self.watched += 1; self.receive = receive; return { self.unwatched += 1 } },
      reconnect: { _ in self.reconnects += 1 }, cached: { _, _, _ in Self.envelope(0, "cached") })
  }
  func send(_ generation: Int, _ revision: Int, _ text: String, syncing: Bool = false) {
    receive?(.init(generation: generation, state: "live", sessionId: "session", session: Self.envelope(revision, text, syncing: syncing)))
  }
}
@main struct FeedCheck {
  @MainActor static func wait(_ test: () -> Bool) async throws {
    for _ in 0..<1000 {
      if test() { return }
      try await Task.sleep(for: .milliseconds(2))
    }
    preconditionFailure("Feed did not reach its expected state")
  }
  @MainActor static func main() async throws {
    let fixture = Fixture()
    let feed = SessionFeed(sessionId: "session", userId: "user", workspaceId: "workspace", service: fixture.service)
    feed.start(); feed.start()
    try await wait { feed.state.entriesJSON.contains("cached") }
    precondition(fixture.watched == 1 && feed.state.status == "syncing")
    precondition(!feed.state.sendReady && !feed.state.controlReady)
    precondition(!feed.state.isLiveUpdate, "Cached content must establish a static baseline")
    fixture.send(1, 3, "live")
    try await wait { feed.state.status == "live" }
    precondition(feed.state.preview?.label == "localhost:5173")
    let usage = try JSONSerialization.jsonObject(with: Data(feed.state.usageJSON!.utf8)) as! [String: Any]
    precondition((usage["context"] as? [String: Int]) == ["used": 84000, "size": 200000])
    precondition(!feed.state.isLiveUpdate, "The first live snapshot must replace the cache without replay")
    fixture.send(0, 100, "stale-generation")
    fixture.send(1, 2, "stale-revision")
    fixture.send(1, 4, "accepted")
    try await wait { feed.state.revision == 4 }
    precondition(feed.state.entriesJSON.contains("accepted"))
    precondition(feed.state.isLiveUpdate, "Subsequent live revisions may animate their appended text")
    fixture.send(2, 0, "new-runtime")
    try await wait { feed.generation == 2 }
    precondition(feed.state.entriesJSON.contains("new-runtime"))
    precondition(!feed.state.isLiveUpdate, "A replaced runtime restores a fresh baseline")
    feed.reconnect(); precondition(fixture.reconnects == 1)
    fixture.send(2, 1, "caught-up")
    try await wait { feed.state.revision == 1 }
    precondition(!feed.state.isLiveUpdate, "Reconnect catch-up must not replay missed text")
    fixture.send(2, 2, "resumed")
    try await wait { feed.state.revision == 2 }
    precondition(feed.state.isLiveUpdate, "Live animation resumes after catch-up")
    fixture.receive?(.init(generation: 2, state: "background"))
    try await wait { feed.state.status == "background" }
    fixture.send(2, 3, "foreground")
    try await wait { feed.state.revision == 3 }
    precondition(!feed.state.isLiveUpdate, "Foreground restoration must not replay suspended content")
    fixture.send(2, 4, "readable-history", syncing: true)
    try await wait { feed.state.revision == 4 }
    precondition(feed.state.status == "syncing" && feed.state.controlReady && !feed.state.sendReady)
    precondition(feed.state.entriesJSON.contains("readable-history") && !feed.state.isLiveUpdate)
    fixture.receive?(.init(generation: 2, state: "background"))
    try await wait { feed.state.status == "background" }
    precondition(!feed.state.controlReady && !feed.state.sendReady)
    fixture.send(2, 5, "after-close")
    feed.finish(); feed.finish(); feed.reconnect()
    try await Task.sleep(for: .milliseconds(50))
    precondition(fixture.unwatched == 1 && fixture.reconnects == 1 && !feed.watching)
    precondition(!feed.state.entriesJSON.contains("after-close"))
    let maintenance = SessionEnvelope.prepare(#"""
    {"v":1,"revision":9,"status":"live","activeTurnId":"a-fold","usage":{"context":null,"isContextCompacting":true,"quotaEligible":false,"quota":null},"entries":[
      {"id":"u1","role":"user","status":"handled","finished":true,"items":[]},
      {"id":"a1","role":"assistant","finished":true,"items":[]}
    ]}
    """#)
    precondition(maintenance?.transcript.unfinishedTurnId == "a-fold",
                 "activeTurnId preserves unfinishedTurnId while a hidden maintenance reply runs")
    print("PASS: cache before live, one subscription, generation/revision ordering, reconnect and cancellation")
  }
}
