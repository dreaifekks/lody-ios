import LodyData
import Foundation

/// Page ownership survives loss of a subscription and late transport callbacks.
@MainActor
final class TerminalShellOwnership {
  private(set) var terminalId: String?
  private(set) var machineId: String?
  var openUncertain = false
  private var ended = false
  private var cleanupAttempted = false
  private var cleanup: (@MainActor (String, @escaping @MainActor (Bool) -> Void) -> Void)?

  func configure(machineId: String, cleanup: @escaping @MainActor (String, @escaping @MainActor (Bool) -> Void) -> Void) -> Bool {
    if let previous = self.machineId, previous != machineId, terminalId != nil || openUncertain { return false }
    self.machineId = machineId
    self.cleanup = cleanup
    return true
  }
  func record(_ id: String) {
    if terminalId != id { cleanupAttempted = false }
    terminalId = id; openUncertain = false
    if ended { cleanupKnown() }
  }
  func confirmExit(_ id: String) {
    guard terminalId == id else { return }
    terminalId = nil
    openUncertain = false
  }
  func end(using channel: (any TerminalChannel)?) {
    guard !ended else { return }
    ended = true
    if let channel { channel.stop() } else { cleanupKnown() }
    // Unknown opens get only a bounded late-answer cleanup window. Release
    // the old native key even if this ended page stays on screen after logout.
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(24))
      self?.cleanup = nil
    }
  }
  func cleanupKnown() {
    guard ended, !cleanupAttempted, let id = terminalId, let cleanup else { return }
    cleanupAttempted = true
    self.cleanup = nil
    cleanup(id) { [self] confirmed in
      if confirmed { confirmExit(id) }
      // Do not automatically retry failed cleanup, even on another callback.
    }
  }
}

@MainActor
protocol TerminalChannel: AnyObject {
  func start(_ completion: @escaping @MainActor (Result<Void, LanTerminalLink.Failure>) -> Void)
  func request(_ command: LanTerminalCommand, _ completion: @escaping @MainActor (Result<LanTerminalEvent, LanTerminalLink.Failure>) -> Void)
  func adopt(terminalId: String)
  func send(_ command: LanTerminalCommand)
  func disconnect()
  func stop()
}

@MainActor
final class NativeTerminalChannel: TerminalChannel {
  private let link: LanTerminalLink
  private let ownership: TerminalShellOwnership
  private var stopped = false
  init(endpoint: LanTerminalEndpoint, invite: LanInvite, machineId: String, ownership: TerminalShellOwnership,
       event: @escaping @MainActor (LanTerminalEvent) -> Void,
       closed: @escaping @MainActor (LanTerminalLink.Failure) -> Void) {
    self.ownership = ownership
    link = LanTerminalLink(endpoint: endpoint, lanId: invite.id,
      key: LanTerminalProtocol.key(token: invite.token), machineId: machineId)
    link.onOwnedTerminal = { id in MainActor.assumeIsolated { ownership.record(id) } }
    link.onEvent = { value in MainActor.assumeIsolated {
      if case let .exit(_, id, _, _) = value { ownership.confirmExit(id) }
      event(value)
    } }
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
  func adopt(terminalId: String) { link.adopt(terminalId: terminalId) }
  func send(_ command: LanTerminalCommand) { link.send(command) }
  func disconnect() { link.disconnect() }
  func stop() {
    guard !stopped else { return }
    stopped = true
    let ownership = self.ownership
    link.cancel { confirmed in MainActor.assumeIsolated {
      if confirmed, let id = ownership.terminalId { ownership.confirmExit(id) }
      else { ownership.cleanupKnown() }
    } }
  }
  isolated deinit { if !stopped { link.disconnect() } }
}

@MainActor
private final class TerminalCallback<Value> {
  let body: @MainActor (Value) -> Void
  init(_ body: @escaping @MainActor (Value) -> Void) { self.body = body }
}
