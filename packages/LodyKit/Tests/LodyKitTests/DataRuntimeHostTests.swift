import XCTest
@testable import LodyKit

@MainActor
final class DataRuntimeHostTests: XCTestCase {
  private func store() -> LocalStore {
    LocalStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("lody-\(UUID().uuidString).sqlite"))
  }

  func testMissingLanCredentialFailsWithoutAWebView() {
    let runtime = DataRuntime(localStore: store())
    var states: [String] = []
    runtime.onCatalogUpdate = { _, state, _ in states.append(state) }
    runtime.start(workspace: "lw_deadbeef", slug: "lan", name: "LAN", owner: "owner", userId: "local:deadbeef")
    XCTAssertEqual(states, ["failed"])
    XCTAssertNil(runtime.webView)
  }

  func testReplacedFeedOfTheSameSessionKeepsTheNewWatcherOpen() {
    let runtime = DataRuntime(localStore: store())
    DataRuntime.current = runtime
    defer { DataRuntime.current = nil }
    let old = SessionFeedService.live.watch("s") { _ in }
    let replacement = SessionFeedService.live.watch("s") { _ in }
    old()
    XCTAssertEqual(runtime.sessionId, "s")
    replacement()
    XCTAssertNil(runtime.sessionId)
  }

  func testStaleUnsubscribeCannotStopTheCurrentOwner() throws {
    let workspace = "w-\(UUID().uuidString)"
    try WorkspaceModePins.shared.observe(workspace, mode: .plaintext)
    let runtime = DataRuntime(localStore: store())
    runtime.start(workspace: workspace, slug: "team", name: "Team", owner: "new-owner", userId: "user")
    runtime.stop(owner: "old-owner")
    XCTAssertEqual(runtime.workspace, workspace)
    runtime.stop(owner: "new-owner")
    XCTAssertNil(runtime.workspace)
    XCTAssertNil(runtime.webView)
  }

  func testLocalStoreRoundTrips() throws {
    let local = store()
    try local.write("account", #"{"user":"u"}"#)
    XCTAssertEqual(try local.read("account"), #"{"user":"u"}"#)
  }
}
