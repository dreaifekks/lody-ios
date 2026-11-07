import XCTest
@testable import LodyData

@MainActor
final class LANSchemeTests: XCTestCase {
  func testOnlyTheOwnedStreamsOriginIsForwarded() throws {
    let invite = try LanInvite.parse("lody-lan://token@hub:8788")
    let origin = LanHubSchemeHandler.origin(invite)
    let target = LanHubSchemeHandler.forward(URL(string: origin + "/ds/lody/stream?live=sse")!, invite: invite)
    XCTAssertEqual(target?.absoluteString, "http://hub:8788/ds/lody/stream?live=sse")
    for address in [origin + "/github/token", origin + "/ds/../github/token", origin + "/ds/%2e%2e/github/token",
                    origin + "/ds/%2f../github/token", origin + ":80/ds/lody/x", "lody-hub://other/ds/lody/x",
                    "lody-hub://user@\(invite.id)/ds/lody/x", origin + "/ds/lody/x#fragment"] {
      XCTAssertNil(LanHubSchemeHandler.forward(URL(string: address)!, invite: invite), address)
    }
  }
}
