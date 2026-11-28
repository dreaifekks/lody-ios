import LodyCore
import UIKit
import XCTest
@testable import LodyKit

@MainActor
final class ScheduleRunPrecheckTests: XCTestCase {
  private func makeItem(
    destination: RuntimeContract.ScheduleItemDestination,
    destinationSessionId: String? = nil,
    lastSessionId: String? = nil
  ) -> ScheduleItem {
    ScheduleItem(
      scheduleId: "sched-1",
      title: "Nightly check",
      ownerId: "user-1",
      isOwner: true,
      machineId: "machine-1",
      machineName: "Studio",
      machineSupported: true,
      agentConfigId: "codex",
      agentName: "Codex",
      agentType: "codex",
      enabled: true,
      scheduledMessage: false,
      rule: .init(kind: .manual),
      destination: destination,
      destinationSessionId: destinationSessionId,
      state: .init(group: .running, kind: .manual),
      lastRunAt: nil,
      lastSessionId: lastSessionId,
      createdAt: 1,
      updatedAt: 2
    )
  }

  private func makeCatalog(sessionId: String, title: String) throws -> SessionCatalog {
    let payload = try JSONSerialization.data(withJSONObject: [
      "id": sessionId,
      "machineId": "machine-1",
      "title": title,
      "status": "idle",
      "projectId": "p1",
      "createdAt": "2026-11-28T00:00:00.000Z",
    ])
    let session = try JSONDecoder().decode(SessionItem.self, from: payload)
    return SessionCatalog(projects: [], sessions: [session], machineIds: ["machine-1"])
  }

  private func makeService(
    onLiveStatus: @escaping (_ workspaceId: String, _ sessionId: String, _ machineId: String) async throws -> RuntimeContract.SessionLiveStatusResult
  ) -> ScheduleService {
    ScheduleService(
      list: { _ in .init(items: [], deviceTimeZone: "UTC", machineTimeZones: [:], ownedMachineIds: []) },
      detail: { _, _ in throw NSError(domain: "test", code: 1) },
      command: { params in .init(scheduleId: params.scheduleId) },
      sessionLiveStatus: onLiveStatus,
      options: { _ in CreationOptions(availability: "live", sessionId: "test", agents: [], capabilities: []) }
    )
  }

  func testBoundSessionResolutionCoversExistingOwnAndNewDestinations() {
    XCTAssertEqual(
      ScheduleRunPrecheck.boundSessionId(for: makeItem(destination: .existingSession, destinationSessionId: "sess-1")),
      "sess-1"
    )
    XCTAssertEqual(
      ScheduleRunPrecheck.boundSessionId(for: makeItem(destination: .ownSession, destinationSessionId: "own-1", lastSessionId: "old-1")),
      "own-1"
    )
    XCTAssertEqual(
      ScheduleRunPrecheck.boundSessionId(for: makeItem(destination: .ownSession, destinationSessionId: nil, lastSessionId: "own-fallback")),
      "own-fallback"
    )
    XCTAssertNil(ScheduleRunPrecheck.boundSessionId(for: makeItem(destination: .ownSession)))
    XCTAssertNil(ScheduleRunPrecheck.boundSessionId(for: makeItem(destination: .newSession, destinationSessionId: "ignored", lastSessionId: "ignored")))
  }

  func testEvaluateRunsImmediatelyWhenUnboundOrIdleAndConfirmsWhenBusyOrUnknown() async throws {
    var queried: [(String, String, String)] = []
    let catalog = try makeCatalog(sessionId: "sess-1", title: "Release thread")

    // Unbound schedule never queries live status.
    let unboundService = makeService { workspaceId, sessionId, machineId in
      queried.append((workspaceId, sessionId, machineId))
      return .init(sessionId: sessionId, state: .busy)
    }
    let unboundDecision = await ScheduleRunPrecheck.evaluate(
      item: makeItem(destination: .newSession),
      workspaceId: "ws-1",
      catalog: catalog,
      service: unboundService
    )
    XCTAssertEqual(unboundDecision, .runImmediately)
    XCTAssertTrue(queried.isEmpty)

    // Idle bound chat runs immediately.
    let idleService = makeService { workspaceId, sessionId, machineId in
      queried.append((workspaceId, sessionId, machineId))
      return .init(sessionId: sessionId, state: .idle, source: .rpc)
    }
    let idleDecision = await ScheduleRunPrecheck.evaluate(
      item: makeItem(destination: .existingSession, destinationSessionId: "sess-1"),
      workspaceId: "ws-1",
      catalog: catalog,
      service: idleService
    )
    XCTAssertEqual(idleDecision, .runImmediately)
    XCTAssertEqual(queried.count, 1)
    XCTAssertEqual(queried[0].0, "ws-1")
    XCTAssertEqual(queried[0].1, "sess-1")
    XCTAssertEqual(queried[0].2, "machine-1")

    // Busy bound chat asks for busy confirmation with chat title.
    let busyService = makeService { _, sessionId, _ in
      .init(sessionId: sessionId, state: .busy, detail: .running, source: .presence)
    }
    let busyDecision = await ScheduleRunPrecheck.evaluate(
      item: makeItem(destination: .existingSession, destinationSessionId: "sess-1"),
      workspaceId: "ws-1",
      catalog: catalog,
      service: busyService
    )
    XCTAssertEqual(busyDecision, .confirmBusy(chatTitle: "Release thread"))

    // Unknown state and thrown errors both ask for unknown-status confirmation.
    let unknownService = makeService { _, sessionId, _ in
      .init(sessionId: sessionId, state: .unknown, source: .none, reason: .machineOffline)
    }
    let unknownDecision = await ScheduleRunPrecheck.evaluate(
      item: makeItem(destination: .existingSession, destinationSessionId: "sess-1"),
      workspaceId: "ws-1",
      catalog: catalog,
      service: unknownService
    )
    XCTAssertEqual(unknownDecision, .confirmUnknown(chatTitle: "Release thread"))

    let failingService = makeService { _, _, _ in
      throw NSError(domain: "test", code: 2)
    }
    let errorDecision = await ScheduleRunPrecheck.evaluate(
      item: makeItem(destination: .existingSession, destinationSessionId: "sess-1"),
      workspaceId: "ws-1",
      catalog: try makeCatalog(sessionId: "other", title: ""),
      service: failingService
    )
    XCTAssertEqual(errorDecision, .confirmUnknown(chatTitle: ScheduleFormat.text("destination.untitledChat")))
  }

  func testConfirmationAlertBuildsCancelAndConfirmActions() {
    let item = makeItem(destination: .existingSession, destinationSessionId: "sess-1")
    XCTAssertNil(ScheduleRunPrecheck.confirmationAlert(item: item, decision: .runImmediately, detail: false, onConfirm: {}))

    let busyAlert = ScheduleRunPrecheck.confirmationAlert(
      item: item,
      decision: .confirmBusy(chatTitle: "Release thread"),
      detail: true,
      onConfirm: {}
    )
    XCTAssertNotNil(busyAlert)
    XCTAssertEqual(busyAlert?.actions.count, 2)
    XCTAssertEqual(busyAlert?.actions[0].style, .cancel)
    XCTAssertEqual(busyAlert?.actions[1].style, .default)
    XCTAssertTrue(busyAlert?.title?.contains("Release thread") == true)
    XCTAssertTrue(busyAlert?.message?.contains("Nightly check") == true)
  }
}
