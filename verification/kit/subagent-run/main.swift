import Foundation
import LodyCore

@MainActor
final class Harness {
  var pending: [(RuntimeContract.ItemDetailParams, CheckedContinuation<RuntimeContract.ItemDetail, Error>)] = []
  var receive: (@MainActor (Int, String?) -> Void)?
  var removals = 0
  var service: ItemDetailService {
    .init(load: { [self] params in
      try await withCheckedThrowingContinuation { pending.append((params, $0)) }
    }, observe: { [self] callback in receive = callback; return { [self] in removals += 1; receive = nil } })
  }
  static let first = #"["task","first"]"#
  static let last = #"["task","last"]"#
  func item(_ rev: Int, count: Int = 3, text: String = "tail") -> [String: Any] {
    ["itemId": "task", "rev": rev, "type": "subagent_task", "run": ["state": "running", "itemCount": count,
      "items": [["itemId": Self.last, "type": "text", "text": text]]]]
  }
  func response(_ index: Int, rev: Int, text: String) {
    let run: RuntimeContract.JSONValue = .object(["state": .string("running"), "items": .array([
      .object(["itemId": .string(Self.first), "type": .string("text"), "text": .string(text)]),
      .object(["itemId": .string(Self.last), "type": .string("text"), "text": .string("read tail")]),
    ])])
    pending[index].1.resume(returning: .init(itemId: "task", rev: rev, blocks: [], run: .init(value: run), truncated: false))
  }
  func event(_ generation: Int, rev: Int) {
    let value: [String: Any] = ["status": "live", "entries": [["id": "entry", "items": [item(rev)]]]]
    receive?(generation, String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self))
  }
}

@main
struct Check {
  @MainActor static func settle() async { for _ in 0..<30 { await Task.yield() } }
  @MainActor static func steps(_ store: SubagentRunStore) -> [[String: Any]] {
    (store.displayedItem["run"] as! [String: Any])["items"] as! [[String: Any]]
  }
  @MainActor static func main() async {
    let io = Harness()
    let store = SubagentRunStore(sessionId: "session", entryId: "entry", item: io.item(1), generation: 0, service: io.service)
    var changes = 0; store.changed = { changes += 1 }
    store.start(); await settle()
    precondition(io.pending.count == 1 && io.pending[0].0.run == true)
    precondition(io.pending[0].0.sessionId == "session" && io.pending[0].0.entryId == "entry" && io.pending[0].0.itemId == "task")
    store.update(io.item(2), generation: 0); store.update(io.item(3, text: "live tail"), generation: 0); await settle()
    precondition(io.pending.count == 1, "Revisions coalesce behind one read")
    io.response(0, rev: 1, text: "early report"); await settle()
    precondition(io.pending.count == 2)
    precondition(steps(store).last?["text"] as? String == "live tail")
    io.response(1, rev: 3, text: "updated report at the same item count"); await settle()
    precondition(steps(store).first?["text"] as? String == "updated report at the same item count")
    precondition(steps(store).first?["itemId"] as? String == Harness.first, "Composite item IDs survive unchanged")
    store.update(io.item(3), generation: 0); await settle(); precondition(io.pending.count == 2)
    store.update(io.item(4), generation: 0); await settle()
    io.pending[2].1.resume(throwing: CocoaError(.fileReadUnknown)); await settle()
    precondition(steps(store).first?["text"] as? String == "updated report at the same item count", "Failed refresh retains full history")
    store.update(io.item(5), generation: 0); await settle()
    io.receive?(1, nil)
    store.update(io.item(99), generation: 0) // A pre-recovery owner update must not fence out the new generation.
    io.event(1, rev: 1); await settle()
    precondition(io.pending.count == 5 && steps(store).count == 1)
    let before = changes
    store.update(io.item(99), generation: 0) // The old owner can also arrive after the new live.
    precondition(changes == before && steps(store).count == 1)
    io.event(1, rev: 2); await settle()
    precondition(io.pending.count == 5, "New revisions still coalesce behind the generation's read")
    io.response(3, rev: 5, text: "stale generation"); await settle()
    precondition(changes == before && steps(store).count == 1)
    io.response(4, rev: 1, text: "new generation"); await settle()
    precondition(steps(store).first?["text"] as? String == "new generation")
    store.update(io.item(3), generation: 1); await settle()
    let oldObserver = io.receive
    store.finish()
    let ended = changes
    io.response(5, rev: 2, text: "late after close"); oldObserver?(2, nil); await settle()
    precondition(changes == ended && io.removals == 1, "A closed page has no late state or subscriptions")

    let completeIO = Harness()
    let complete = SubagentRunStore(sessionId: "session", entryId: "entry", item: completeIO.item(1, count: 1), generation: 0, service: completeIO.service)
    complete.start(); await settle(); precondition(completeIO.pending.isEmpty); complete.finish()
    let nullIO = Harness()
    let null = SubagentRunStore(sessionId: "session", entryId: "entry", item: nullIO.item(1), generation: 0, service: nullIO.service)
    null.start(); await settle()
    nullIO.pending[0].1.resume(returning: .init(itemId: "task", rev: 1, blocks: [], run: .init(value: .null), truncated: false))
    await settle(); precondition(steps(null).count == 1); null.finish()
    print("PASS: full run reads, one-at-a-time rev coalescing, latest-step merge, same-count edits, generation/close fences, null and complete runs")
  }
}
