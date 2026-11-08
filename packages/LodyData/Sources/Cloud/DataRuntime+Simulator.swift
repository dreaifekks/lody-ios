import Foundation
import LodyCore

extension SimulatorService {
  public static func live(workspaceId: String, userId: String, sessionId: String,
                          target: @escaping @MainActor () -> (LanTerminalEndpoint, String)? = { nil }) -> Self {
    if !LanInvite.isWorkspace(workspaceId) {
      return Self(call: { command in
        guard let runtime = DataRuntime.current, runtime.workspace == workspaceId, runtime.userId == userId else {
          throw OutboxError.scopeExpired
        }
        return try await runtime.perform(RuntimeContract.Calls.IosSimulatorControl.self,
          .init(workspaceId: workspaceId, sessionId: sessionId, userId: userId, command: command))
      })
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
    return Self(isLAN: true, release: { client.release() }, whenReleased: { client.onRelease = $0 }, canReuse: {
      guard let (_, invite, target) = context() else { client.release(); return false }
      return client.reuse(invite: invite, target: target)
    }, call: { command in
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
    })
  }
}

@MainActor
final class WeakLanSimulator {
  weak var value: LanSimulator?
  init(_ value: LanSimulator) { self.value = value }
}
