import Foundation
import LodyCore

@MainActor
struct ConnectionService {
  typealias Machine = RuntimeContract.MachineStatusResultMachinesItem
  var machines: @MainActor (String) async throws -> [Machine]
  var ping: @MainActor (String, String) async throws -> Double
  var latency: @MainActor (LanHubSummary) async -> Int?
  var presence: @MainActor () -> String

  static let live = ConnectionService(
    machines: { workspace in
      guard let runtime = DataRuntime.current, runtime.workspace == workspace else {
        throw DataRuntime.failure("not_ready", "metadata_not_ready")
      }
      return try await runtime.workspaceCall(RuntimeContract.Calls.MachineStatus.self) { workspace, _ in
        .init(workspaceId: workspace, action: .list)
      }.machines ?? []
    },
    ping: { workspace, machine in
      guard let runtime = DataRuntime.current, runtime.workspace == workspace else {
        throw DataRuntime.failure("not_ready", "metadata_not_ready")
      }
      return try await runtime.workspaceCall(RuntimeContract.Calls.MachineStatus.self) { workspace, _ in
        .init(workspaceId: workspace, action: .ping, machineId: machine)
      }.ms!
    },
    latency: { hub in
      guard !LodyUIVerify.enabled, !LodyUIVerify.offline,
            let invite = LanHub.credential(for: hub.workspaceId) else { return nil }
      return await LanHub.latency(invite)
    },
    presence: {
      struct Payload: Decodable {
        struct Presence: Decodable { var presence: RuntimeContract.MachinePresence }
        var presence: Presence
      }
      return (try? JSONDecoder().decode(Payload.self, from: Data(CatalogSession.published.json.utf8)))?.presence.presence.state.rawValue ?? "unknown"
    }
  )
}

/// Visible-page ownership matches the old ten-second hub probe hook.
@MainActor
final class HubLatencyObserver {
  enum Value: Equatable {
    case measuring, noAnswer, measured(Int)
    var text: String {
      switch self {
      case .measuring: return SettingsSections.text("connection.measuring")
      case .noAnswer: return SettingsSections.text("connection.noAnswer")
      case .measured(let ms): return String.localizedStringWithFormat(String(localized: "settings.connection.latency", bundle: .lody), ms)
      }
    }
  }
  private(set) var value = Value.measuring
  private var hub: LanHubSummary?
  private var task: Task<Void, Never>?
  private var active = false
  private let service: ConnectionService
  var changed: (() -> Void)?

  init(service: ConnectionService) { self.service = service }
  isolated deinit { task?.cancel() }

  func start(_ hub: LanHubSummary?) {
    if active, self.hub == hub { return }
    stop()
    active = true
    self.hub = hub
    value = .measuring
    guard let hub else { return }
    task = Task { [weak self, service] in
      while !Task.isCancelled {
        let ms = await service.latency(hub)
        guard let self, !Task.isCancelled, self.hub == hub else { return }
        self.value = ms.map(Value.measured) ?? .noAnswer
        self.changed?()
        try? await Task.sleep(for: .seconds(10))
      }
    }
  }

  func stop() {
    active = false
    task?.cancel()
    task = nil
    hub = nil
  }
}
