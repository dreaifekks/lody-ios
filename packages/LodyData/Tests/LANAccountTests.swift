import XCTest
@testable import LodyData

final class LANAccountTests: XCTestCase {
  func testLANProjectionRestoresWithoutPersistingBearer() throws {
    let invite = try LanInvite.parse("lody-lan://private-test-token@hub:8788/Home")
    let account = AuthAccount.lanAccount(invite)
    XCTAssertTrue(account.isLAN)
    XCTAssertEqual(account.lan?.workspaceId, invite.workspaceId)
    XCTAssertEqual(account.user.id, invite.userId)
    XCTAssertEqual(account.workspaces.first?.slug, "lan")
    XCTAssertFalse(account.json.contains(invite.token))
    XCTAssertEqual(AuthAccount.decode(account.json), account)
  }

  func testCloudAccountFromBeforeLANStillDecodes() {
    let account = AuthAccount.decode(#"{"user":{"id":"u","name":"User","email":"u@example.com"},"workspaces":[]}"#)
    XCTAssertNotNil(account)
    XCTAssertNil(account?.lan)
    XCTAssertEqual(account?.isLAN, false)
  }

  func testOldAttemptCannotReleaseItsReplacementLease() {
    let inflight = OutboxInflight()
    let old = inflight.begin("s")!
    XCTAssertNil(inflight.begin("s"))
    inflight.end("s", token: old)
    let replacement = inflight.begin("s")!
    inflight.end("s", token: old)
    XCTAssertTrue(inflight.contains("s"))
    inflight.end("s", token: replacement)
    XCTAssertFalse(inflight.contains("s"))
  }
}
