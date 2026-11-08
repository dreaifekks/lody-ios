import XCTest
@testable import LodyData

final class ChatAnswerFoldingTests: XCTestCase {
  private func turn(_ items: [[String: Any]], finished: Bool = true) throws -> ChatTranscript {
    let entry: [String: Any] = ["id": "fold", "role": "assistant", "status": "completed", "finished": finished,
      "startedAt": 1000, "endedAt": 5000, "items": items]
    return ChatTranscript(entries: try JSONDecoder().decode([ChatEntry].self, from: JSONSerialization.data(withJSONObject: [entry])))
  }
  private func text(_ id: String, _ body: String) -> [String: Any] { ["itemId": id, "type": "text", "text": body] }
  private func work(_ id: String) -> [String: Any] { ["itemId": id, "type": "tool_call", "title": "Check", "status": "completed"] }

  func testThinPostscriptKeepsItsPrecedingRunAndEarlierSubstantiveText() throws {
    let items = [text("narration", "Checking"), work("read"), text("report", "# Earlier report"), work("verify"),
      text("bridge", "Checking again"), work("poll"), text("answer1", "Primary answer"), text("answer2", "More detail"),
      work("finish"), text("closing", "Background work finished")]
    let transcript = try turn(items)
    XCTAssertEqual(transcript.rows().filter { $0.kind == "text" }.map(\.itemID), ["report", "answer1", "answer2", "closing"])
    XCTAssertEqual(transcript.rows(processEntryID: "fold").map(\.itemID), ["narration", "read", "verify", "bridge", "poll", "finish"])
    XCTAssertTrue(transcript.rows().first { $0.kind == "duration" }?.actionable == true)
    let live = try turn(items, finished: false).rows()
    let kept = transcript.rows().filter { $0.kind == "text" }
    XCTAssertTrue(kept.allSatisfy { row in live.contains { $0.id == row.id } })
    XCTAssertFalse(kept.contains(where: \.streaming))
    XCTAssertTrue(live.contains { $0.itemID == "closing" && $0.streaming })
  }

  func testUTF16BoundaryAndAdjacentClosingBlocks() throws {
    for (body, expected) in [(String(repeating: "😀", count: 149), ["answer", "closing"]),
                              (String(repeating: "😀", count: 150), ["closing"])] {
      let value = try turn([text("answer", "Short answer"), work("work"), text("closing", body)])
      XCTAssertEqual(value.rows().filter { $0.kind == "text" }.map(\.itemID), expected)
      XCTAssertEqual(value.rows(processEntryID: "fold").filter { $0.kind == "text" }.map(\.itemID), expected.contains("answer") ? [] : ["answer"])
    }
    let value = try turn([text("answer", "Short answer"), work("work"), text("a", String(repeating: "a", count: 149)), text("b", String(repeating: "b", count: 149))])
    XCTAssertEqual(value.rows().filter { $0.kind == "text" }.map(\.itemID), ["a", "b"])
    XCTAssertEqual(value.rows(processEntryID: "fold").map(\.itemID), ["answer", "work"])
  }

  func testOnlyASCIIListsAndExplicitMarkdownStructureAreSubstantive() {
    for body in ["1. List", " 12) List", "- List", "| Table |", "## Heading"] { XCTAssertTrue(ChatAnswerText.isSubstantive(body), body) }
    for body in ["１. Full-width", "١. Arabic-Indic", "#tag", "-1 degree"] { XCTAssertFalse(ChatAnswerText.isSubstantive(body), body) }
    XCTAssertFalse(ChatAnswerText.isSubstantive(String(repeating: "a", count: 299) + "\n "))
  }

  func testWorkTailKeepsOnlyLastTextAndFlatRunDetailStillKeepsEverything() throws {
    let value = try turn([text("report", "# Earlier report"), work("read"), text("last", "Last answer"), work("cleanup")])
    XCTAssertEqual(value.rows().filter { $0.kind == "text" }.map(\.itemID), ["last"])
    XCTAssertEqual(value.rows(processEntryID: "fold").map(\.itemID), ["report", "read", "cleanup"])
    XCTAssertEqual(value.rows(processEntryID: "fold", processStartID: "__subagent__").map(\.itemID), ["report", "read", "last", "cleanup"])
  }

  func testNeverFoldedTailDoesNotDiscardTheAnswerBeforeIt() throws {
    for type in ["image", "image_group", "file", "plan", "goal", "proposed_plan", "system_notice"] {
      let value = try turn([text("answer", "Short answer"), work("poll"), text("closing", "Finished"), ["itemId": "tail", "type": type]])
      XCTAssertEqual(ChatAnswerText.visibleIndices(value.entries[0].items), [0, 2], type)
    }
  }
}
