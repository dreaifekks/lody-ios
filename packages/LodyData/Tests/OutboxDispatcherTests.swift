import XCTest
@testable import LodyData

@MainActor
final class OutboxDispatcherTests: XCTestCase {
  private func record(_ phase: String) -> OutboxRecord {
    .init(session: ["id": .string("s")], send: ["id": .string("turn"), "phase": .string(phase),
      "text": .string("hello"), "attachments": .array([]), "choice": .object([:])])
  }

  private func store(_ record: OutboxRecord) async -> OutboxStore {
    let raw = OutboxRecord.encode([record])
    let store = OutboxStore(key: "outbox:u:w", generation: 0,
      persistence: .init(generation: { 0 }, read: { _ in raw }, write: { _, _, _ in }), awaitingConfirmation: "unknown")
    for _ in 0..<100 where !store.snapshot.ready { await Task.yield() }
    XCTAssertTrue(store.snapshot.ready)
    return store
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<200 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Outbox did not settle")
  }

  func testRetryableSendReleasesInflightAndWakesWaiting() async throws {
    let store = await store(record("waiting")), inflight = OutboxInflight()
    var done = false
    var calls = 0
    let services = OutboxServices(createSession: { _ in "" }, ensureSession: { _ in }, sendSessionTurn: { _ in
      calls += 1
      if calls == 1 { return #"{"state":"not_sent","reason":"metadata_not_ready","retryable":true}"# }
      return #"{"state":"accepted"}"#
    }, releaseReserve: { _ in done = true }, alert: { _, _ in XCTFail("retryable send must wait") })
    let dispatcher = OutboxDispatcher(services: services, inflight: inflight, text: { $0 })
    dispatcher.retryPause = .milliseconds(5)
    store.onChange = { dispatcher.schedule() }
    dispatcher.update(store: store, inputs: .init(userId: "u", connected: true))
    try await waitUntil { done }
    XCTAssertEqual(calls, 2)
    XCTAssertEqual(store.snapshot.records.first?.phase, "accepted")
    XCTAssertFalse(inflight.contains("s"))
    dispatcher.update(store: nil, inputs: .init())
    store.onChange = nil
  }

  func testUnknownAbsentIsFailedWithNewTurnIDWithoutSendReplay() async throws {
    let store = await store(record("unknown"))
    var done = false
    let services = OutboxServices(createSession: { _ in XCTFail("must not create"); return "" },
      ensureSession: { _ in }, sendSessionTurn: { _ in XCTFail("must not replay"); return "" },
      releaseReserve: { _ in }, alert: { _, _ in done = true },
      confirmSessionCreation: { _ in "" }, confirmSessionTurn: { _ in #"{"state":"absent","retryId":"retry-turn"}"# })
    let dispatcher = OutboxDispatcher(services: services, inflight: OutboxInflight(), text: { $0 })
    dispatcher.update(store: store, inputs: .init(userId: "u", connected: true))
    try await waitUntil { done }
    XCTAssertEqual(store.snapshot.records.first?.phase, "failed")
    XCTAssertEqual(store.snapshot.records.first?.sendId, "retry-turn")
    dispatcher.update(store: nil, inputs: .init())
  }
}
