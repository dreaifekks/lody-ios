import UIKit
import XCTest
@testable import LodyKit

@MainActor
final class ChatTurnScrollTests: XCTestCase {
  func testTargetTurnWaitsForLiveSnapshotAndFindsItAfterCachedSnapshot() async throws {
    let (window, view) = makeAttachedChatView()
    defer { window.isHidden = true }

    view.targetTurnID = "t-live"
    view.transcriptLive = false
    view.setEntries(try encodeEntries(["t-cached"]), animate: false)
    view.scheduleUpdate()

    try await waitUntil { view.appliedSnapshotEpoch >= 1 }
    XCTAssertEqual(view.targetTurnID, "t-live", "Cached snapshot must not clear an unseen target turn")
    XCTAssertNil(view.lastScrolledTurnID)

    view.transcriptLive = true
    view.setEntries(try encodeEntries(["t-cached", "t-live"]), animate: false)
    view.scheduleUpdate()

    try await waitUntil { view.lastScrolledTurnID == "t-live" }
    XCTAssertEqual(view.targetTurnID, "")
    XCTAssertFalse(view.followsBottom)
  }

  func testTargetTurnSurvivesStaleSnapshotCommitWhileLiveSnapshotIsQueued() async throws {
    let (window, view) = makeAttachedChatView()
    defer { window.isHidden = true }

    view.targetTurnID = "t-live"
    view.transcriptLive = false
    // Start decoding a cached snapshot without the target turn, then immediately
    // transition to live with a newer snapshot containing the target turn.
    view.setEntries(try encodeEntries(["t-cached"]), animate: false)
    view.scheduleUpdate()
    view.transcriptLive = true
    view.setEntries(try encodeEntries(["t-cached", "t-live"]), animate: false)
    view.scheduleUpdate()

    try await waitUntil { view.lastScrolledTurnID == "t-live" }
    XCTAssertEqual(view.targetTurnID, "")
    XCTAssertEqual(view.appliedSnapshotEpoch, view.pendingSnapshotEpoch)
  }

  func testCachedHitKeepsTargetUntilLiveWindowConfirmsAndLoadsEarlierHistoryIfEvicted() async throws {
    let (window, view) = makeAttachedChatView()
    defer { window.isHidden = true }

    var pagesLoaded = 0
    view.onLoadEarlierHistory = { [weak view] in
      guard let view else { return }
      pagesLoaded += 1
      view.remoteHasEarlierHistory = false
      let ids = (1...12).map { "t\($0)" }
      if let json = try? self.encodeEntries(ids) {
        view.setEntries(json, animate: false)
        view.scheduleUpdate()
      }
    }

    // Cached snapshot initially contains the linked turn `t2`: scroll immediately,
    // but keep `targetTurnID` alive until a live snapshot confirms it.
    view.targetTurnID = "t2"
    view.transcriptLive = false
    view.setEntries(try encodeEntries(["t1", "t2", "t3"]), animate: false)
    view.scheduleUpdate()

    try await waitUntil { view.appliedSnapshotEpoch >= 1 && view.lastScrolledTurnID == "t2" }
    XCTAssertEqual(view.targetTurnID, "t2", "Provisional cached hit must retain targetTurnID until live confirms")
    XCTAssertEqual(pagesLoaded, 0)

    // First live snapshot arrives with only the newest 6 turns (evicting `t2`).
    view.lastScrolledTurnID = nil
    view.remoteHasEarlierHistory = true
    view.transcriptLive = true
    view.setEntries(try encodeEntries((7...12).map { "t\($0)" }), animate: false)
    view.scheduleUpdate()

    try await waitUntil { view.targetTurnID.isEmpty }
    XCTAssertEqual(pagesLoaded, 1, "Live handoff evicting the cached target must page earlier history")
    XCTAssertEqual(view.lastScrolledTurnID, "t2")
    XCTAssertFalse(view.followsBottom)
  }

  func testTargetTurnExpandsEarlierRemoteHistoryAndLocalWindowUntilFound() async throws {
    let (window, view) = makeAttachedChatView()
    defer { window.isHidden = true }

    var pagesLoaded = 0
    view.onLoadEarlierHistory = { [weak view] in
      guard let view else { return }
      pagesLoaded += 1
      let ids: [String]
      if pagesLoaded == 1 {
        ids = (30...60).map { "t\($0)" }
        view.remoteHasEarlierHistory = true
      } else {
        ids = (1...60).map { "t\($0)" }
        view.remoteHasEarlierHistory = false
      }
      if let json = try? self.encodeEntries(ids) {
        view.setEntries(json, animate: false)
        view.scheduleUpdate()
      }
    }

    view.targetTurnID = "t5"
    view.remoteHasEarlierHistory = true
    view.transcriptLive = true
    view.setEntries(try encodeEntries((55...60).map { "t\($0)" }), animate: false)
    view.scheduleUpdate()

    try await waitUntil { view.lastScrolledTurnID == "t5" }
    XCTAssertEqual(pagesLoaded, 2)
    XCTAssertEqual(view.targetTurnID, "")
    XCTAssertFalse(view.followsBottom)
    XCTAssertTrue(
      view.dataSource.snapshot().itemIdentifiers.contains { view.rows[$0]?.entryID == "t5" },
      "Local 50-entry boundary must expand to include the linked turn"
    )
  }

  func testTargetTurnClearsQuietlyWhenHistoryExhaustsOrRemoteLoadFails() async throws {
    let (window, view) = makeAttachedChatView()
    defer { window.isHidden = true }

    // Subcase A: history exhausts without finding the turn.
    var exhaustLoads = 0
    view.onLoadEarlierHistory = { [weak view] in
      guard let view else { return }
      exhaustLoads += 1
      view.remoteHasEarlierHistory = false
      if let json = try? self.encodeEntries(["t1", "t2", "t3", "t4"]) {
        view.setEntries(json, animate: false)
        view.scheduleUpdate()
      }
    }
    view.targetTurnID = "missing-turn"
    view.remoteHasEarlierHistory = true
    view.transcriptLive = true
    view.setEntries(try encodeEntries(["t3", "t4"]), animate: false)
    view.scheduleUpdate()

    try await waitUntil { view.targetTurnID.isEmpty }
    XCTAssertEqual(exhaustLoads, 1)
    XCTAssertNil(view.lastScrolledTurnID)

    // Subcase B: Roost remote load starts and fails without expanding the edge.
    var failedLoads = 0
    view.onLoadEarlierHistory = { [weak view] in
      guard let view else { return }
      failedLoads += 1
      view.remoteHistoryLoading = true
      view.scrollToTargetTurn()
      DispatchQueue.main.async {
        view.remoteHistoryLoading = false
        view.scrollToTargetTurn()
      }
    }
    view.remoteHasEarlierHistory = true
    view.targetTurnID = "unreachable-turn"

    try await waitUntil { view.targetTurnID.isEmpty }
    XCTAssertEqual(failedLoads, 1)
    XCTAssertNil(view.lastScrolledTurnID)
  }

  func testTargetTurnStopsAtSafetyCapWithoutLoopingForever() async throws {
    let (window, view) = makeAttachedChatView()
    defer { window.isHidden = true }

    var loads = 0
    var oldest = 100
    view.onLoadEarlierHistory = { [weak view] in
      guard let view else { return }
      loads += 1
      oldest -= 1
      let ids = (oldest...100).map { "t\($0)" }
      view.remoteHasEarlierHistory = true
      if let json = try? self.encodeEntries(ids) {
        view.setEntries(json, animate: false)
        view.scheduleUpdate()
      }
    }

    view.targetTurnID = "never-found"
    view.remoteHasEarlierHistory = true
    view.transcriptLive = true
    view.setEntries(try encodeEntries(["t100"]), animate: false)
    view.scheduleUpdate()

    try await waitUntil(timeout: 10) { view.targetTurnID.isEmpty }
    XCTAssertEqual(loads, LodyChatView.maxTargetTurnHistoryLoads)
    XCTAssertNil(view.lastScrolledTurnID)
  }

  private func makeAttachedChatView() -> (UIWindow, LodyChatView) {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    let controller = UIViewController()
    let view = LodyChatView(frame: window.bounds)
    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    controller.view.addSubview(view)
    window.rootViewController = controller
    window.makeKeyAndVisible()
    view.layoutIfNeeded()
    return (window, view)
  }

  private func encodeEntries(_ ids: [String]) throws -> String {
    let payload: [[String: Any]] = ids.map { id in
      [
        "id": id,
        "role": "user",
        "status": "completed",
        "finished": true,
        "items": [["itemId": "text-\(id)", "type": "text", "text": "Message \(id)"]],
      ]
    }
    let data = try JSONSerialization.data(withJSONObject: payload)
    return String(decoding: data, as: UTF8.self)
  }

  private func waitUntil(timeout: TimeInterval = 5, condition: @escaping @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      if Date() >= deadline {
        XCTFail("Timed out waiting for chat turn scroll condition")
        return
      }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
  }
}
