import LodyData
import Foundation

/// A native-only service seam. Offline fixtures never construct a network link.
@MainActor
protocol TerminalChannel: AnyObject {
  func start(_ completion: @escaping @MainActor (Result<Void, LanTerminalLink.Failure>) -> Void)
  func request(_ command: LanTerminalCommand, _ completion: @escaping @MainActor (Result<LanTerminalEvent, LanTerminalLink.Failure>) -> Void)
  func send(_ command: LanTerminalCommand)
  func stop()
}

@MainActor
final class NativeTerminalChannel: TerminalChannel {
  private let link: LanTerminalLink
  init(endpoint: LanTerminalEndpoint, invite: LanInvite, machineId: String,
       event: @escaping @MainActor (LanTerminalEvent) -> Void,
       closed: @escaping @MainActor (LanTerminalLink.Failure) -> Void) {
    link = LanTerminalLink(endpoint: endpoint, lanId: invite.id,
      key: LanTerminalProtocol.key(token: invite.token), machineId: machineId)
    link.onEvent = { value in MainActor.assumeIsolated { event(value) } }
    link.onClose = { value in MainActor.assumeIsolated { closed(value) } }
  }
  func start(_ completion: @escaping @MainActor (Result<Void, LanTerminalLink.Failure>) -> Void) {
    let callback = TerminalCallback(completion)
    link.start { value in MainActor.assumeIsolated { callback.body(value) } }
  }
  func request(_ command: LanTerminalCommand, _ completion: @escaping @MainActor (Result<LanTerminalEvent, LanTerminalLink.Failure>) -> Void) {
    let callback = TerminalCallback(completion)
    link.request(command) { value in MainActor.assumeIsolated { callback.body(value) } }
  }
  func send(_ command: LanTerminalCommand) { link.send(command) }
  func stop() { link.cancel() }
  isolated deinit { link.cancel() }
}

/// The body is accessed only on the main actor, including transport callbacks.
@MainActor
private final class TerminalCallback<Value> {
  let body: @MainActor (Value) -> Void
  init(_ body: @escaping @MainActor (Value) -> Void) { self.body = body }
}
