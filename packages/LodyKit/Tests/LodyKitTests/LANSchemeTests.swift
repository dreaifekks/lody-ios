import XCTest
@testable import LodyKit

@MainActor
final class LANSchemeTests: XCTestCase {
  func testOnlyTheOwnedStreamsOriginAndClockEndpointAreForwarded() throws {
    let invite = try LanInvite.parse("lody-lan://token@hub:8788")
    let origin = LanHubSchemeHandler.origin(invite)
    let streams = LanHubSchemeHandler.route(URL(string: origin + "/ds/lody/stream?live=sse")!, method: "GET", invite: invite)
    XCTAssertEqual(streams?.url.absoluteString, "http://hub:8788/ds/lody/stream?live=sse")
    XCTAssertEqual(streams?.authorized, true)

    let time = LanHubSchemeHandler.route(URL(string: origin + "/api/time")!, method: "GET", invite: invite)
    XCTAssertEqual(time?.url.absoluteString, "http://hub:8788/api/time")
    XCTAssertEqual(time?.authorized, true)
    let timeHead = LanHubSchemeHandler.route(URL(string: origin + "/api/time")!, method: "HEAD", invite: invite)
    XCTAssertEqual(timeHead?.url.absoluteString, "http://hub:8788/api/time")
    XCTAssertEqual(timeHead?.authorized, true)
    let timeOptions = LanHubSchemeHandler.route(URL(string: origin + "/api/time")!, method: "OPTIONS", invite: invite)
    XCTAssertEqual(timeOptions?.url.absoluteString, "http://hub:8788/api/time")
    XCTAssertEqual(timeOptions?.authorized, false)
    XCTAssertNil(LanHubSchemeHandler.route(URL(string: origin + "/api/time")!, method: "POST", invite: invite))
    XCTAssertNil(LanHubSchemeHandler.route(URL(string: origin + "/api/time/extra")!, method: "GET", invite: invite))

    for address in [origin + "/github/token", origin + "/ds/../github/token", origin + "/ds/%2e%2e/github/token",
                    origin + "/ds/%2f../github/token", origin + "/api/%2e%2e/api/time", origin + ":80/ds/lody/x",
                    "lody-hub://other/ds/lody/x", "lody-hub://other/api/time",
                    "lody-hub://user@\(invite.id)/ds/lody/x", origin + "/ds/lody/x#fragment"] {
      XCTAssertNil(LanHubSchemeHandler.forward(URL(string: address)!, invite: invite), address)
    }
  }
}
