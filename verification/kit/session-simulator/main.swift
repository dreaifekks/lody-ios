import Foundation
import LodyCore

enum OutboxError: Error { case scopeExpired }
@MainActor final class DataRuntime {
  static var current: DataRuntime?
  var workspace = ""
  var userId = ""
  func perform(_ call: RuntimeContract.Calls.IosSimulatorControl.Type, _ params: RuntimeContract.IosSimulatorControlParams) async throws -> RuntimeContract.IosSimulatorControlResult { fatalError("fixture must not use cloud") }
}
@MainActor final class Fixture {
  var calls: [String] = []
  var pending: CheckedContinuation<SimulatorService.Reply, Error>?
  var deferResume = false
  var deferList = false
  var invalidate: (() -> Void)?
  var releases = 0
  let device = SessionSimulator.Device(udid: "phone", name: "Phone", runtime: "iOS", deviceType: "iPhone", state: "Booted", available: true, occupancy: .available)
  func ready(_ operation: String) -> SimulatorService.Reply {
    .init(success: true, preview: .init(operationId: operation, udid: "phone", phase: .ready, transport: .remote, viewerUrl: "lody-simulator-fixture://stream"))
  }
  var service: SimulatorService {
    .init(isLAN: true, release: { [self] in releases += 1; invalidate?() }, whenReleased: { [self] in invalidate = $0 }, call: { [self] command in
      switch command {
      case .list:
        calls.append("list")
        if deferList { return try await withCheckedThrowingContinuation { pending = $0 } }
        return .init(success: true, devices: [device])
      case .start: calls.append("start"); return ready("new")
      case .status:
        calls.append("status")
        if deferResume { return try await withCheckedThrowingContinuation { pending = $0 } }
        return ready("resumed")
      case .stop: calls.append("stop"); return .init(success: true)
      case .exterior: preconditionFailure("The viewer owns exterior requests")
      }
    })
  }
}
@main struct SimulatorCheck {
  @MainActor static func main() async throws {
    let fixture = Fixture()
    let store = SessionSimulator(sessionId: "session", service: fixture.service)
    let resumed = try await store.resume()
    precondition(resumed && store.phase == "ready" && store.name == "Phone")
    precondition(fixture.calls == ["status", "list"])
    precondition(!store.previewJSON.isEmpty)
    store.hidePreview(); precondition(store.previewJSON.isEmpty && !store.sourceJSON.isEmpty)
    store.revealPreview(); precondition(!store.previewJSON.isEmpty)
    try await store.stop(); precondition(store.phase == "closed" && fixture.calls.last == "stop")
    fixture.deferResume = true
    let stale = Task { try await store.resume() }
    while fixture.pending == nil { await Task.yield() }
    store.start(fixture.device)
    while store.phase != "ready" { await Task.yield() }
    fixture.pending!.resume(returning: fixture.ready("stale"))
    let accepted = try await stale.value
    precondition(!accepted && store.preview?.operationId == "new")
    precondition(fixture.calls.filter { $0 == "start" }.count == 1)
    fixture.deferResume = false; fixture.deferList = true; fixture.pending = nil
    let duringList = Task { try await store.resume() }
    while fixture.pending == nil { await Task.yield() }
    let ownership = store.ownership
    fixture.invalidate?()
    fixture.pending!.resume(returning: .init(success: true, devices: [fixture.device]))
    let listAccepted = try await duringList.value
    precondition(!listAccepted && store.sourceJSON.isEmpty && store.ownership > ownership)
    fixture.deferList = false
    store.start(fixture.device)
    while store.phase != "ready" { await Task.yield() }
    store.finish()
    precondition(fixture.releases == 2 && store.phase == "closed" && store.sourceJSON.isEmpty)
    print("PASS: resume discovers the device, floating preview hides independently, stale status cannot replace a new start, writes are not replayed; runtime release during list cannot adopt and finish releases/clears LAN preview")
  }
}
