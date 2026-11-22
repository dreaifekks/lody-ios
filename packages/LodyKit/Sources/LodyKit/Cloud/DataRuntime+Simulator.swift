import Foundation
import LodyCore

extension SimulatorService {
  static func live(_ platform: DevicePlatform = .ios, workspaceId: String, userId: String, sessionId: String,
                   target: @escaping @MainActor () -> (LanTerminalEndpoint, String)? = { nil }) -> Self {
    func runtime() throws -> DataRuntime {
      guard let runtime = DataRuntime.current, runtime.workspace == workspaceId, runtime.userId == userId else {
        throw OutboxError.scopeExpired
      }
      return runtime
    }
    if !LanInvite.isWorkspace(workspaceId) || platform == .android {
      switch platform {
      case .ios:
        return .ios { command in
          try await runtime().perform(RuntimeContract.Calls.IosSimulatorControl.self,
            .init(workspaceId: workspaceId, sessionId: sessionId, userId: userId, command: command))
        }
      case .android:
        return .android { command in
          try await runtime().perform(RuntimeContract.Calls.AndroidEmulatorControl.self,
            .init(workspaceId: workspaceId, sessionId: sessionId, userId: userId, command: command))
        }
      }
    }
    let client = LanSimulator()
    @MainActor func context() -> (DataRuntime, LanInvite, LanSimulator.Target)? {
      guard let runtime = DataRuntime.current, runtime.workspace == workspaceId, runtime.userId == userId,
            let invite = runtime.lan,
            AuthSession.shared.snapshot.account?.user.id == userId,
            AuthSession.shared.snapshot.account?.lan?.id == invite.id,
            let (endpoint, machineId) = target() else { return nil }
      return (runtime, invite, .init(endpoint: endpoint, machineId: machineId))
    }
    return .ios(isLAN: true, release: { client.release() }, whenReleased: { client.onRelease = $0 }, canReuse: {
      guard let (_, invite, target) = context() else { client.release(); return false }
      return client.reuse(invite: invite, target: target)
    }) { command in
      guard let (runtime, invite, target) = context() else { throw OutboxError.scopeExpired }
      runtime.simulatorClients.removeAll { $0.value == nil }
      if !runtime.simulatorClients.contains(where: { $0.value === client }) {
        runtime.simulatorClients.append(.init(client))
      }
      let generation = runtime.generation
      return try await client.control(invite: invite, target: target,
        sessionId: sessionId, command: command, current: {
          DataRuntime.current === runtime && runtime.generation == generation &&
            runtime.workspace == workspaceId && runtime.userId == userId &&
            AuthSession.shared.snapshot.account?.lan?.id == invite.id
        })
    }
  }
}

@MainActor
final class WeakLanSimulator {
  weak var value: LanSimulator?
  init(_ value: LanSimulator) { self.value = value }
}
