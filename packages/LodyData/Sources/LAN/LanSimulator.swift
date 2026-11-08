import Foundation
import LodyCore
import Network

/// Direct member control and the session-owned same-number loopback viewer port.
@MainActor
final class LanSimulator {
  struct Target: Sendable, Equatable {
    let endpoint: LanTerminalEndpoint
    let machineId: String
  }
  var onRelease: (() -> Void)?
  private var version = 0
  private var forward: LanPortForward?
  private var channels: [UUID: LanMemberChannel] = [:]

  func release() {
    version += 1
    onRelease?()
    forward?.close(); forward = nil
    channels.values.forEach { $0.close() }; channels.removeAll()
  }

  isolated deinit {
    forward?.close()
    channels.values.forEach { $0.close() }
  }

  /// Reuses a live local listener, refreshing where its next tunnel connects.
  func reuse(invite: LanInvite, target: Target) -> Bool {
    guard let forward, forward.machineId == target.machineId, forward.alive else { return false }
    let key = LanTerminalProtocol.key(token: invite.token)
    forward.updateConnection {
      LanTerminalProtocol.connection(to: target.endpoint, lanId: invite.id, key: key)
    }
    return true
  }

  func control(invite: LanInvite, target: Target, sessionId: String,
               command: SimulatorService.Command,
               current: @MainActor () -> Bool = { true }) async throws -> SimulatorService.Reply {
    // Stop also invalidates a start/status that is still answering.
    if case .stop = command { release() }
    let token = version
    let reply = try await ask(invite: invite, target: target, sessionId: sessionId, command: command)
    guard token == version, !Task.isCancelled else { throw CancellationError() }
    guard current() else { release(); throw CancellationError() }
    if case .stop = command { return reply }
    if let preview = reply.preview, [.closed, .failed].contains(preview.phase) {
      version += 1
      forward?.close(); forward = nil
      return reply
    }
    guard let address = reply.preview?.viewerUrl, let url = URL(string: address),
          let port = url.port.flatMap(UInt16.init(exactly:)) else { return reply }
    if forward?.port == port, reuse(invite: invite, target: target) { return reply }
    forward?.close()
    let key = LanTerminalProtocol.key(token: invite.token)
    let next = LanPortForward(machineId: target.machineId, port: port) {
      LanTerminalProtocol.connection(to: target.endpoint, lanId: invite.id, key: key)
    }
    // Register before binding, so release during start closes the pending listener.
    forward = next
    do {
      try await withTaskCancellationHandler { try await next.start() } onCancel: { next.close() }
    } catch {
      let owned = token == version && forward === next
      if forward === next { forward = nil; next.close() }
      guard owned, !Task.isCancelled else { throw CancellationError() }
      guard current() else { release(); throw CancellationError() }
      if let operationId = reply.preview?.operationId {
        _ = try? await ask(invite: invite, target: target, sessionId: sessionId,
                          command: .stop(.init(operationId: operationId)))
      }
      throw Self.failure(String.localizedStringWithFormat(
        String(localized: "native.simulator.lan.portBusy", bundle: .lodyData), String(port)))
    }
    guard token == version, forward === next, !Task.isCancelled else {
      if forward === next { forward = nil; next.close() }
      throw CancellationError()
    }
    guard current() else { release(); throw CancellationError() }
    return reply
  }

  private nonisolated static func failure(_ message: String) -> NSError {
    NSError(domain: "LodyKit.Simulator", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }

  private func ask(invite: LanInvite, target: Target, sessionId: String,
                   command: SimulatorService.Command) async throws -> SimulatorService.Reply {
    let id = UUID()
    let channel = LanMemberChannel(endpoint: target.endpoint, lanId: invite.id,
      key: LanTerminalProtocol.key(token: invite.token), machineId: target.machineId)
    channels[id] = channel
    defer { channels[id] = nil; channel.close() }
    return try await Self.ask(channel: channel, invite: invite, target: target, sessionId: sessionId, command: command)
  }

  private nonisolated static func ask(channel: LanMemberChannel, invite: LanInvite, target: Target,
                                      sessionId: String, command: SimulatorService.Command) async throws -> SimulatorService.Reply {
    try await channel.open(service: "control")
    let encoded = try JSONEncoder().encode(command)
    let body = try JSONSerialization.jsonObject(with: encoded)
    let answer = try await channel.request([
      "type": "lan/ios-simulator", "machineId": target.machineId,
      "workspaceId": invite.workspaceId, "sessionId": sessionId,
      "requestedByUserId": invite.userId, "command": body,
    ], timeout: 50, maxBytes: 8 * 1024 * 1024)
    guard answer["ok"] as? Bool == true else {
      throw Self.failure(answer["message"] as? String ?? "the machine refused")
    }
    guard answer["type"] as? String == "lan/ios-simulator", let result = answer["result"] as? [String: Any] else {
      throw Self.failure("the machine answered with something else")
    }
    return try JSONDecoder().decode(SimulatorService.Reply.self,
      from: JSONSerialization.data(withJSONObject: result))
  }
}
