import XCTest
@testable import LodyData

@MainActor
final class ChatContinueMarkerTests: XCTestCase {
  private func entry(status: String = "handled", delivery: String? = nil, kind: String? = "continue") throws -> ChatEntry {
    var raw: [String: Any] = ["id": "continue", "role": "user", "status": status, "finished": true,
      "items": [["itemId": "prompt", "type": "text", "text": SessionDecision.interruptedContinuation]]]
    raw["delivery"] = delivery; raw["deliveryKind"] = kind
    return try JSONDecoder().decode(ChatEntry.self, from: JSONSerialization.data(withJSONObject: raw))
  }

  func testOnlySettledContinueReplacesThePrompt() throws {
    let value = try entry()
    XCTAssertEqual(value.deliveryKind, "continue")
    XCTAssertEqual(value.items[0].text, SessionDecision.interruptedContinuation)
    let row = try XCTUnwrap(ChatTranscript(entries: [value]).rows().first)
    XCTAssertEqual(row.kind, "continued")
    XCTAssertEqual(row.id, "continue:user")
    XCTAssertEqual(row.symbol, "play.circle")
    XCTAssertFalse(row.actionable)
    XCTAssertFalse(row.text.contains(SessionDecision.interruptedContinuation))
    XCTAssertEqual(row.text, String(localized: "native.chat.message.continued", bundle: .lodyData))
  }

  func testUnknownAndEveryNonNilDeliveryKeepTheRecoveryPrompt() throws {
    var values = [try entry(status: "delivery_unknown"), try entry(kind: nil)]
    values += try ["unknown", "rejected", "confirming", "waiting", "accepted"].map { try entry(delivery: $0) }
    for value in values {
      let rows = ChatTranscript(entries: [value]).rows()
      XCTAssertFalse(rows.contains { $0.kind == "continued" })
      XCTAssertEqual(rows.first { $0.kind == "user" }?.text, SessionDecision.interruptedContinuation)
      if let delivery = value.delivery, delivery != "accepted" { XCTAssertTrue(rows.contains { $0.kind == "delivery" }) }
    }
    XCTAssertTrue(try ChatTranscript(entries: [entry(status: "queued")]).rows().isEmpty)
  }

  func testSettlingChangesTheSameRowIdentityWithoutWritingATurn() throws {
    let uncertain = try ChatTranscript(entries: [entry(status: "delivery_unknown")]).rows()
    let settled = try ChatTranscript(entries: [entry()]).rows()
    XCTAssertEqual(uncertain.first?.id, settled.first?.id)
    XCTAssertEqual(uncertain.first?.kind, "user")
    XCTAssertEqual(settled.first?.kind, "continued")
  }

  @MainActor
  func testRestartAlreadyUsesTheExistingContinuationAndHasItsOwnTitle() throws {
    let meta = try JSONDecoder().decode(ChatItem.NoticeMeta.self, from: Data(#"{"reason":"daemon_restart"}"#.utf8))
    XCTAssertEqual(ChatFailure.title(meta), String(localized: "native.chat.error.daemon_restart", bundle: .lodyData))
    XCTAssertNotEqual(ChatFailure.title(meta), ChatFailure.title(nil))
    XCTAssertEqual(SessionDecision.retryTurn(reason: "daemon_restart").deliveryKind, "continue")
    XCTAssertEqual(SessionDecision.retryTurn(reason: "daemon_restart").text, SessionDecision.interruptedContinuation)
  }
}
