import Foundation

@main struct Check {
  @MainActor static func store(_ phase: String) async -> OutboxStore {
    let record = OutboxRecord(session: ["id": .string("s")], send: ["id": .string("turn"), "phase": .string(phase),
      "text": .string("hello"), "attachments": .array([]), "choice": .object([:])])
    let raw = OutboxRecord.encode([record])
    let store = OutboxStore(key: "outbox:u:w", generation: 0,
      persistence: .init(generation: { 0 }, read: { _ in raw }, write: { _, _, _ in }), awaitingConfirmation: "unknown")
    for _ in 0..<100 where !store.snapshot.ready { await Task.yield() }
    assert(store.snapshot.ready)
    return store
  }
  @MainActor static func wait(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<200 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    fatalError("outbox did not settle")
  }
  @MainActor static func main() async throws {
    let inflight = OutboxInflight()
    let old = inflight.begin("lease")!
    inflight.end("lease", token: old)
    let next = inflight.begin("lease")!
    inflight.end("lease", token: old)
    assert(inflight.contains("lease"))
    inflight.end("lease", token: next)

    let first = await store("waiting")
    var calls = 0
    var observedWaiting = false
    let services = OutboxServices(createSession: { _ in "" }, ensureSession: { _ in }, sendSessionTurn: { _ in
      calls += 1
      return calls == 1 ? #"{"state":"not_sent","reason":"metadata_not_ready","retryable":true}"# : #"{"state":"accepted"}"#
    }, releaseReserve: { _ in }, alert: { _, _ in fatalError("retryable send alerted") })
    let dispatcher = OutboxDispatcher(services: services, inflight: inflight, text: { $0 })
    dispatcher.retryPause = .milliseconds(5)
    first.onChange = {
      if calls == 1, first.snapshot.records.first?.phase == "waiting" {
        observedWaiting = true; assert(!inflight.contains("s"))
      }
      dispatcher.schedule()
    }
    dispatcher.update(store: first, inputs: .init(userId: "u", connected: true))
    try await wait { first.snapshot.records.first?.phase == "accepted" && !inflight.contains("s") }
    assert(calls == 2 && observedWaiting)
    dispatcher.update(store: nil, inputs: .init()); first.onChange = nil

    let second = await store("unknown")
    var confirmations = 0
    let confirming = OutboxServices(createSession: { _ in fatalError("unknown creation replayed") }, ensureSession: { _ in },
      sendSessionTurn: { _ in fatalError("unknown turn replayed") }, releaseReserve: { _ in }, alert: { _, _ in },
      confirmSessionCreation: { _ in "" }, confirmSessionTurn: { _ in
        confirmations += 1
        if confirmations == 1 { return #"{"state":"pending"}"# }
        return #"{"state":"absent","retryId":"retry-turn"}"#
      })
    let unknown = OutboxDispatcher(services: confirming, inflight: inflight, text: { $0 })
    unknown.confirmationPause = .milliseconds(5)
    second.onChange = { unknown.schedule() }
    unknown.update(store: second, inputs: .init(userId: "u", connected: true))
    try await wait { second.snapshot.records.first?.phase == "failed" && !inflight.contains("s") }
    assert(confirmations == 2 && second.snapshot.records.first?.sendId == "retry-turn")
    unknown.update(store: nil, inputs: .init()); second.onChange = nil
    let third = await store("unknown")
    var ensure: CheckedContinuation<Void, Never>?
    var turnConfirmations = 0
    let lateServices = OutboxServices(createSession: { _ in "" },
      ensureSession: { _ in await withCheckedContinuation { ensure = $0 } }, sendSessionTurn: { _ in "" },
      releaseReserve: { _ in }, alert: { _, _ in fatalError("late confirmation alerted") },
      confirmSessionCreation: { _ in "" }, confirmSessionTurn: { _ in turnConfirmations += 1; return #"{"state":"seen"}"# })
    let late = OutboxDispatcher(services: lateServices, inflight: inflight, text: { $0 })
    late.update(store: third, inputs: .init(userId: "u", connected: true))
    try await wait { ensure != nil }
    late.update(store: nil, inputs: .init())
    ensure?.resume()
    try await wait { !inflight.contains("s") }
    assert(turnConfirmations == 0 && third.snapshot.records.first?.phase == "unknown")
    print("PASS: owned inflight release, retryable waiting wake, fresh confirmation pending/absent, no unknown replay, stale owner fencing")
  }
}
