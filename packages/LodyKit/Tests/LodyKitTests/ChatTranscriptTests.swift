import XCTest
@testable import LodyKit

final class ChatTranscriptTests: XCTestCase {
  private let reply = """
  [{"id":"reply","role":"assistant","status":"running","finished":true,"items":[
  {"itemId":"intro","type":"thought","text":"check"},
  {"itemId":"tool","type":"tool_call","title":"Read file","status":"completed"},
  {"itemId":"answer","type":"text","text":"done"}]}]
  """

  private func transcript(_ json: String) throws -> ChatTranscript {
    ChatTranscript(entries: try JSONDecoder().decode([ChatEntry].self, from: Data(json.utf8)))
  }

  func testDelegatedAuthorsUseOnlyProjectedIdentity() throws {
    let json = """
    [{"id":"delegated","role":"user","status":"done","finished":true,
      "author":{"kind":"agent","name":"Planner","role":{"name":"iosDev","instanceLabel":"Mini"},"model":"GPT"},
      "items":[{"itemId":"text","type":"text","text":"Check the layout."}]},
     {"id":"human","role":"user","status":"done","finished":true,
      "author":{"kind":"human","name":"Human"},"items":[{"itemId":"text","type":"text","text":"Human message"}]}]
    """
    let rows = try transcript(json).rows()
    XCTAssertEqual(rows.first?.delegatedAuthor, "iosDev · Mini · Planner · GPT")
    XCTAssertNil(rows.last?.delegatedAuthor)
    let noAuthor = json.replacingOccurrences(of: "\"kind\":\"agent\"", with: "\"kind\":\"unknown\"")
    XCTAssertNil(try transcript(noAuthor).rows().first?.delegatedAuthor)
  }

  func testBoardRowsRetainDetailsAndHideOnlyIdleInterruptedMaintenance() throws {
    let json = """
    [{"id":"b","role":"system","status":"done","finished":true,"items":[
      {"itemId":"batch","type":"operation_completion_batch","memberCount":2,"members":[{"title":"A","status":"succeeded"},{"title":"B","status":"failed"}]},
      {"itemId":"proposal","type":"system_notice","name":"agent_role_proposal","meta":{"command":{"action":"update","patch":{"description":"Native chat"}},"before":{"name":"iosDev"},"outcome":"saved"}},
      {"itemId":"manual","type":"system_notice","name":"board_context_maintenance","meta":{"kind":"compact","status":"interrupted","trigger":"manual"}}]},
    {"id":"idle","role":"system","status":"done","finished":true,"items":[
      {"itemId":"hidden","type":"system_notice","name":"board_context_maintenance","meta":{"kind":"compact","status":"interrupted","trigger":"idle"}}]}]
    """
    let rows = try transcript(json).rows()
    XCTAssertEqual(rows.map(\.kind), ["orchestration", "orchestration", "noticeDivider"])
    XCTAssertTrue(rows[0].text.contains("A · "))
    XCTAssertTrue(rows[0].text.contains("B · "))
    XCTAssertTrue(rows[1].text.contains("iosDev"))
    XCTAssertTrue(rows[1].text.contains("Native chat"))
    XCTAssertFalse(rows.contains { $0.actionable || $0.entryID == "idle" })
    XCTAssertFalse(try transcript(json).entries[0].items[0].isProcess)
  }

  func testBoardMaintenanceReplyUsesItsSystemTurnClock() throws {
    let json = """
    [{"id":"maintenance","role":"system","status":"done","finished":true,"startedAt":1000,"items":[
      {"itemId":"compact","type":"system_notice","name":"board_context_maintenance","meta":{"kind":"compact","status":"done"}}]},
    {"id":"reply","role":"assistant","status":"done","finished":true,"endedAt":6000,"userTurnId":"maintenance",
      "items":[{"itemId":"text","type":"text","text":"Maintenance complete"}]}]
    """
    XCTAssertEqual(try transcript(json).rows().first { $0.kind == "duration" }?.workDurationMs, 5000)
  }

  func testSubagentCardsUseRunStateAndKeepLatestStep() throws {
    let json = """
    [{"id":"a","role":"assistant","status":"running","finished":false,"items":[
      {"itemId":"task1","type":"subagent_task","status":"completed","actor":"Explore","run":{"state":"running","items":[{"itemId":"step","type":"text","text":"first line\\nLatest step"}]}},
      {"itemId":"task2","type":"subagent_task","status":"in_progress","actor":"Review","summary":"Finished review","run":{"state":"completed","items":[]}}]}]
    """
    let value = try transcript(json)
    let inline = value.rows()
    let header = try XCTUnwrap(inline.first { $0.kind == "tasksHeader" })
    XCTAssertTrue(header.running)
    XCTAssertEqual(header.detail, "Latest step")
    let rows = value.rows(processEntryID: "a", processStartID: "__subagent__")
    XCTAssertEqual(value.liveSubagentItems().map(\.itemId), ["task1"])
    XCTAssertEqual(rows.map { $0.subagent?.status }, ["in_progress", "completed"])
    XCTAssertEqual(rows[0].subagent?.detail, "Latest step")
    XCTAssertFalse(rows[0].subagent!.groupTitle.isEmpty)
    XCTAssertEqual(rows[1].subagent?.groupTitle, "")
  }

  func testUnknownSubagentRemainsUnsettledInTheCard() throws {
    let json = """
    [{"id":"a","role":"assistant","status":"done","finished":true,"items":[
      {"itemId":"task","type":"subagent_task","status":"completed","run":{"state":"unknown","items":[]}}]}]
    """
    let row = try XCTUnwrap(try transcript(json).rows(processEntryID: "a", processStartID: "__subagent__").first { $0.kind == "subagent_task" })
    XCTAssertEqual(row.subagent?.status, "unknown")
    XCTAssertFalse(row.subagent!.detail.isEmpty)
    XCTAssertFalse(row.running)
  }

  func testToolCallsFoldIntoAProcessSummary() throws {
    let rows = try transcript(reply).rows()
    XCTAssertTrue(rows.contains { $0.kind == "summary" && $0.actionable })
    XCTAssertFalse(rows.contains { $0.itemID == "tool" })
    XCTAssertTrue(rows.contains { $0.itemID == "answer" })
    XCTAssertEqual(try transcript(reply).rows(processEntryID: "reply").map(\.itemID), ["intro", "tool"])
  }

  func testPendingPermissionMakesTheToolActionable() throws {
    let json = reply.replacingOccurrences(of: "\"status\":\"completed\"", with: "\"permission\":{\"requestId\":\"p\",\"pending\":true}")
    let process = try transcript(json).rows(processEntryID: "reply")
    XCTAssertTrue(process.contains { $0.itemID == "tool" && $0.actionable && $0.attention })
  }

  private let twoTurns = """
  [{"id":"u1","role":"user","status":"done","finished":true,"timestamp":"2026-10-30T02:40:00Z","items":[{"itemId":"q1","type":"text","text":"first"}]},
  {"id":"a1","role":"assistant","status":"done","finished":true,"items":[{"itemId":"r1","type":"text","text":"one"}]},
  {"id":"u2","role":"user","status":"done","finished":true,"timestamp":"2026-10-30T02:46:00Z","items":[{"itemId":"q2","type":"text","text":"second"}]},
  {"id":"a2","role":"assistant","status":"done","finished":true,"items":[{"itemId":"r2","type":"text","text":"two"}]}]
  """

  func testTurnsAreSeparatedWithoutDividerRows() throws {
    let rows = try transcript(twoTurns).rows()
    XCTAssertTrue(rows.allSatisfy { $0.kind != "turn" })
    XCTAssertTrue(rows.contains { $0.id == "u2:user" })
  }

  func testAPendingSendOpensWithoutADivider() throws {
    let entries = try JSONDecoder().decode([ChatEntry].self, from: Data(twoTurns.utf8))
    let pending = ChatPendingSend(id: "u3", text: "third", attachments: [], status: "")
    XCTAssertTrue(pending.rows(entries: entries).allSatisfy { $0.kind != "turn" })
  }

  func testDurationRowDoesNotShineWhileRunningRowsDo() {
    XCTAssertFalse(ChatRow(id: "d", entryID: "a", kind: "duration", text: "", running: true).shines)
    XCTAssertTrue(ChatRow(id: "t", entryID: "a", kind: "thought", text: "thinking", running: true).shines)
    XCTAssertTrue(ChatRow(id: "s", entryID: "a", kind: "summary", text: "Working", running: true).shines)
  }

  private func changed(_ files: [String]) -> String {
    let diffs = files.map { #"{"path":"\#($0)","add":3,"del":1}"# }.joined(separator: ",")
    return """
    [{"id":"a","role":"assistant","status":"done","finished":true,"modelInfo":{"title":"Codex"},"fileDiffs":[\(diffs)],
    "items":[{"itemId":"r","type":"text","text":"done"}]}]
    """
  }

  func testTheFileBlockComesBeforeTheMetaRow() throws {
    let kinds = try transcript(changed(["a.swift", "b.swift"])).rows().map(\.kind)
    let header = try XCTUnwrap(kinds.firstIndex(of: "changesHeader"))
    let meta = try XCTUnwrap(kinds.firstIndex(of: "meta"))
    XCTAssertLessThan(header, meta)
  }

  func testBoardFoldRolloverDividerIncludesNodeAndFoldMergeDetails() throws {
    let json = """
    [{"id":"m","role":"system","status":"done","finished":true,"items":[
      {"itemId":"fold","type":"system_notice","name":"board_context_maintenance",
       "meta":{"kind":"fold_rollover","status":"done","trigger":"manual","usedBefore":150000,"usedAfter":18000,"nodeId":"seg-3","foldedCount":3,"foldId":"fold-1"}}]}]
    """
    let row = try XCTUnwrap(try transcript(json).rows().first { $0.kind == "noticeDivider" })
    XCTAssertTrue(row.text.contains("seg-3"), "Expected nodeId in divider: \(row.text)")
    XCTAssertTrue(row.text.contains("3"), "Expected foldedCount in divider: \(row.text)")
    XCTAssertTrue(row.text.contains("fold-1"), "Expected foldId in divider: \(row.text)")
  }
}
