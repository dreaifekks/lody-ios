import Foundation
import XCTest
@testable import LodyKit

@MainActor
final class SessionPreviewCacheTests: XCTestCase {
  func testDevicePreviewPersistsAcrossSwitchesAndClearsOnStop() async throws {
    let cache = SessionPreviewCache(observeMemoryWarning: false)
    let key = SessionPreviewCache.DeviceKey(
      session: .init(workspaceId: "ws-1", userId: "user-1", sessionId: "session-a"),
      platform: .ios
    )
    var stopCount = 0
    let makeService: () -> SimulatorService = {
      SimulatorService(platform: .ios) { command in
        switch command {
        case .list:
          return .init(success: true, devices: [
            .init(id: "udid-1", name: "iPhone 16", runtime: "iOS 18", deviceType: "iPhone", state: "Booted", available: true, unavailableReason: nil, occupied: false),
          ], preview: nil, error: nil, message: nil)
        case .start, .status:
          return .init(success: true, devices: nil, preview: .init(operationId: "op-1", deviceId: "udid-1", phase: "ready", viewerUrl: "https://sim-demo.trycloudflare.com/?token=1", message: nil), error: nil, message: nil)
        case .stop:
          stopCount += 1
          return .init(success: true, devices: nil, preview: nil, error: nil, message: nil)
        }
      }
    }

    let first = cache.device(for: key) { SessionSimulator(sessionId: "session-a", service: makeService()) }
    let resumed = try await first.resume()
    XCTAssertTrue(resumed)
    XCTAssertTrue(first.running)
    XCTAssertTrue(cache.isDeviceCached(first))

    // Returning to the same conversation reuses the exact same SessionSimulator without reconnecting.
    let second = cache.device(for: key) { SessionSimulator(sessionId: "session-a", service: makeService()) }
    XCTAssertTrue(first === second)
    XCTAssertTrue(second.running)

    // Explicit stop tears down and evicts from cache.
    try await second.stop()
    XCTAssertEqual(stopCount, 1)
    XCTAssertFalse(second.running)
    XCTAssertFalse(cache.isDeviceCached(second))
    XCTAssertNil(cache.cachedDevice(for: key))
  }

  func testBrowserCacheEvictsOldestAndClearsOutsideScope() {
    let cache = SessionPreviewCache(observeMemoryWarning: false)
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    for idx in 1...5 {
      let key = SessionPreviewCache.SessionKey(workspaceId: "ws-1", userId: "user-1", sessionId: "s-\(idx)")
      let url = URL(string: "https://demo-\(idx).trycloudflare.com/?__lody_preview_token=t\(idx)")!
      cache.storeBrowser(url: url, expiresAt: now.addingTimeInterval(3600), controller: BrowserPreviewController(url: url), for: key)
    }

    // Bounded at maxBrowsers (4): s-1 was evicted, s-2..s-5 remain.
    XCTAssertNil(cache.browser(for: .init(workspaceId: "ws-1", userId: "user-1", sessionId: "s-1")))
    let entry2 = cache.browser(for: .init(workspaceId: "ws-1", userId: "user-1", sessionId: "s-2"))
    XCTAssertNotNil(entry2)
    XCTAssertTrue(entry2?.isValid(at: now.addingTimeInterval(100)) == true)
    XCTAssertTrue(entry2?.isValid(at: now.addingTimeInterval(4000)) == false)

    // Switching workspace clears entries from the previous workspace.
    cache.clearOutside(workspaceId: "ws-2", userId: "user-1")
    XCTAssertNil(cache.browser(for: .init(workspaceId: "ws-1", userId: "user-1", sessionId: "s-2")))
    XCTAssertNil(cache.browser(for: .init(workspaceId: "ws-1", userId: "user-1", sessionId: "s-5")))
  }

  func testValidatedAndMergedPreviewURL() {
    XCTAssertNotNil(SessionPreviewCache.validatedPreviewURL("https://calm-river.trycloudflare.com/app?__lody_preview_token=abc"))
    XCTAssertNil(SessionPreviewCache.validatedPreviewURL("http://calm-river.trycloudflare.com/?__lody_preview_token=abc"))
    XCTAssertNil(SessionPreviewCache.validatedPreviewURL("https://user@calm-river.trycloudflare.com/?__lody_preview_token=abc"))
    XCTAssertNil(SessionPreviewCache.validatedPreviewURL("https://calm-river.trycloudflare.com:8443/?__lody_preview_token=abc"))
    XCTAssertNil(SessionPreviewCache.validatedPreviewURL("https://evil.example/?__lody_preview_token=abc"))

    let fresh = URL(string: "https://new-tunnel.trycloudflare.com/?__lody_preview_token=fresh-tok")!
    let previous = URL(string: "https://old-tunnel.trycloudflare.com/settings/profile?tab=security&__lody_preview_token=old-tok#keys")!
    let merged = SessionPreviewCache.mergedPreviewURL(newBase: fresh, previousPage: previous)
    XCTAssertEqual(merged.host, "new-tunnel.trycloudflare.com")
    XCTAssertEqual(merged.path, "/settings/profile")
    XCTAssertEqual(merged.fragment, "keys")
    let items = URLComponents(url: merged, resolvingAgainstBaseURL: false)?.queryItems ?? []
    XCTAssertEqual(items.first(where: { $0.name == "tab" })?.value, "security")
    XCTAssertEqual(items.filter { $0.name == "__lody_preview_token" }.map(\.value), ["fresh-tok"])
  }
}
