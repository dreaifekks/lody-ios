import Foundation
import Network

/// Simulators of another member of a LAN, as Lody's `forwardIosSimulatorControl`
/// (`lan-ios-simulator.ts`) previews them. A command goes to the member that
/// runs the session over its `control` service, and the member carries it out
/// as one from its own desktop, so its viewer listens on the member's
/// loopback. A loopback port of this device with the same number carries the
/// viewer here over the member's `tunnel` service: the viewer checks that its
/// page comes from the address it serves, so the number cannot change.
enum LanSimulator {
  /// `LAN_IOS_SIMULATOR_PROTOCOL_VERSION`, advertised as `protocolCapabilities.lanIosSimulator`.
  static let version = 1
  /// What `lan-fleet-control.ts` gives a member for a simulator command.
  static let timeout: TimeInterval = 50
  /// `ANSWER_MAX_BYTES` of `lan-control-channel.ts`; a device's exterior art rides in the answer.
  static let answerMaxBytes = 8 * 1024 * 1024

  struct Target: Sendable {
    let endpoint: LanTerminalEndpoint
    let machineId: String
  }

  /// Puts one `lan/ios-simulator` request to the member over a `control`
  /// connection, which carries one request and its answer.
  static func ask(invite: LanInvite, target: Target, sessionId: String, command: [String: Any]) async throws -> [String: Any] {
    let channel = LanFileChannel(endpoint: target.endpoint, lanId: invite.id,
                                 key: LanTerminalProtocol.key(token: invite.token), machineId: target.machineId)
    defer { channel.close() }
    try await channel.open(service: "control")
    return try await channel.request([
      "type": "lan/ios-simulator", "machineId": target.machineId, "workspaceId": invite.workspaceId,
      "sessionId": sessionId, "requestedByUserId": invite.userId, "command": command,
    ], timeout: timeout, maxBytes: answerMaxBytes)
  }

  /// Carries out one `IosSimulatorCommand` and returns the member's
  /// `IosSimulatorResponse`. A viewer in the answer is carried to the same
  /// port of this device; an operation that ended releases its port.
  static func control(invite: LanInvite, target: Target, sessionId: String, command: [String: Any],
                      ports: LanSimulatorPorts = .shared) async -> [String: Any] {
    func failure(_ message: String) -> [String: Any] {
      ["type": "ios-simulator/control_response", "sessionId": sessionId, "success": false,
       "error": "failed", "message": message]
    }
    func ask(_ command: [String: Any]) async throws -> [String: Any] {
      try await Self.ask(invite: invite, target: target, sessionId: sessionId, command: command)
    }
    let key = LanTerminalProtocol.key(token: invite.token)
    // A release while the member answers (page left, stop, logout) wins over the answer.
    let ticket = await ports.ticket(sessionId)
    let answer: [String: Any]
    do { answer = try await ask(command) } catch { return failure(error.localizedDescription) }
    guard answer["ok"] as? Bool == true else {
      return failure(answer["message"] as? String ?? "the machine refused")
    }
    guard answer["type"] as? String == "lan/ios-simulator", let response = answer["result"] as? [String: Any] else {
      return failure("the machine answered with something else")
    }
    let preview = response["preview"] as? [String: Any]
    guard let viewer = (preview?["viewerUrl"] as? String).flatMap(URL.init(string:)),
          let port = viewer.port.flatMap(UInt16.init(exactly:)) else {
      let stopped = command["action"] as? String == "stop" && response["success"] as? Bool == true
      if stopped || ["closed", "failed"].contains(preview?["phase"] as? String) {
        await ports.release(sessionId)
      }
      return response
    }
    let connect: @Sendable () -> NWConnection = {
      LanTerminalProtocol.connection(to: target.endpoint, lanId: invite.id, key: key)
    }
    do {
      try await ports.open(sessionId: sessionId, ticket: ticket, machineId: target.machineId, port: port, connect: connect)
    } catch {
      // The operation keeps its viewer port; only a new one gets another.
      if let operationId = preview?["operationId"] as? String {
        _ = try? await ask(["action": "stop", "operationId": operationId])
      }
      return failure(LodyStrings.text("native.simulator.lan.portBusy", ["port": port]))
    }
    return response
  }
}

/// The loopback ports of this device that carry a member's simulator viewer,
/// one per session that previews one.
actor LanSimulatorPorts {
  static let shared = LanSimulatorPorts()
  private var forwards: [String: LanPortForward] = [:]
  private var releases: [String: Int] = [:]
  private var logouts = 0

  /// What a release of the session has been up to now; a later release outdates it.
  struct Ticket: Equatable, Sendable {
    let releases: Int
    let logouts: Int
  }

  func ticket(_ sessionId: String) -> Ticket {
    Ticket(releases: releases[sessionId, default: 0], logouts: logouts)
  }

  /// Listens on `127.0.0.1:port` unless the session already does, while
  /// `ticket` is current; a release during the wait closes it again. Throws
  /// when the port is taken.
  func open(sessionId: String, ticket: Ticket, machineId: String, port: UInt16,
            connect: @escaping @Sendable () -> NWConnection) async throws {
    guard ticket == self.ticket(sessionId) else { return }
    if let current = forwards[sessionId], current.machineId == machineId, current.port == port, current.alive { return }
    forwards.removeValue(forKey: sessionId)?.close()
    let forward = LanPortForward(machineId: machineId, port: port, connect: connect)
    // Registered while it binds, so a release meanwhile finds and closes it.
    forwards[sessionId] = forward
    do {
      try await forward.start()
    } catch {
      if forwards[sessionId] === forward { forwards[sessionId] = nil }
      if ticket == self.ticket(sessionId) { throw error }
    }
  }

  /// Stops listening and ends the connections the session's port carries.
  func release(_ sessionId: String) {
    releases[sessionId, default: 0] += 1
    forwards.removeValue(forKey: sessionId)?.close()
  }

  func closeAll() {
    logouts += 1
    forwards.values.forEach { $0.close() }
    forwards.removeAll()
  }

  func port(of sessionId: String) -> UInt16? { forwards[sessionId]?.port }
}

/// One loopback listener. Each connection it accepts opens a tunnel to the
/// same port of the member's loopback. Suspension in the background breaks a
/// listening socket, so one that failed after it listened listens again.
final class LanPortForward: @unchecked Sendable {
  let machineId: String
  let port: UInt16
  private let connect: @Sendable () -> NWConnection
  private let queue = DispatchQueue(label: "app.lody.lan-simulator-port")
  private var listener: NWListener?
  private var listening = false
  private var onReady: ((Result<Void, Error>) -> Void)?
  private var tunnels: [ObjectIdentifier: LanTunnel] = [:]
  private var closed = false

  init(machineId: String, port: UInt16, connect: @escaping @Sendable () -> NWConnection) {
    self.machineId = machineId
    self.port = port
    self.connect = connect
  }

  func start() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      queue.async { [self] in
        onReady = { continuation.resume(with: $0) }
        listen()
      }
    }
  }

  /// Whether it listens or is about to; one whose listening again failed is not.
  var alive: Bool { queue.sync { listener != nil } }

  func close() {
    queue.async { [self] in
      closed = true
      listener?.cancel()
      listener = nil
      tunnels.values.forEach { $0.close() }
      tunnels.removeAll()
      settle(.failure(CancellationError()))
    }
  }

  private func listen() {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
    let listener: NWListener
    do { listener = try NWListener(using: parameters) } catch { return settle(.failure(error)) }
    self.listener = listener
    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    listener.stateUpdateHandler = { [weak self, weak listener] state in
      guard let self, let listener, self.listener === listener else { return }
      switch state {
      case .ready:
        self.listening = true
        self.settle(.success(()))
      case let .failed(error), let .waiting(error):
        listener.cancel()
        self.listener = nil
        let relisten = self.listening && !self.closed
        self.listening = false
        if relisten { self.listen() } else { self.settle(.failure(error)) }
      default:
        break
      }
    }
    listener.start(queue: queue)
  }

  private func settle(_ result: Result<Void, Error>) {
    let ready = onReady
    onReady = nil
    ready?(result)
  }

  private func accept(_ local: NWConnection) {
    guard !closed else { return local.cancel() }
    let tunnel = LanTunnel(local: local, remote: connect(), machineId: machineId, port: port, queue: queue)
    let id = ObjectIdentifier(tunnel)
    tunnels[id] = tunnel
    tunnel.onClose = { [weak self] in self?.tunnels.removeValue(forKey: id) }
    tunnel.start()
  }
}

/// One connection carried to a port of a member's loopback (`lan-tunnel.ts`):
/// after the hello the member is asked for the port with one JSON line and
/// answers `connected`; then the bytes go both ways. A side that finishes
/// sending passes its end on; one that fails takes the other down with it.
final class LanTunnel: @unchecked Sendable {
  private let local: NWConnection
  private let remote: NWConnection
  private let machineId: String
  private let port: UInt16
  private let queue: DispatchQueue
  private var buffer = Data()
  private var greeted = false
  private var joined = false
  private var ended: Set<ObjectIdentifier> = []
  private var finished = false
  /// Runs on the queue once both connections are gone.
  var onClose: (() -> Void)?

  init(local: NWConnection, remote: NWConnection, machineId: String, port: UInt16, queue: DispatchQueue) {
    self.local = local
    self.remote = remote
    self.machineId = machineId
    self.port = port
    self.queue = queue
  }

  func start() {
    local.stateUpdateHandler = { [weak self] state in
      if case .failed = state { self?.close() }
    }
    remote.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        self.writeLine(["type": "hello", "version": LanTerminalProtocol.version,
                        "machineId": self.machineId, "service": "tunnel"])
        self.readAnswers()
      case .waiting, .failed:
        self.close()
      default:
        break
      }
    }
    local.start(queue: queue)
    remote.start(queue: queue)
    queue.asyncAfter(deadline: .now() + LanTerminalProtocol.handshakeTimeout) { [weak self] in
      guard let self, !self.joined else { return }
      self.close()
    }
  }

  func close() {
    guard !finished else { return }
    finished = true
    local.cancel()
    remote.cancel()
    onClose?()
    onClose = nil
  }

  private func writeLine(_ value: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: value) else { return close() }
    data.append(0x0A)
    remote.send(content: data, completion: .contentProcessed { [weak self] error in
      if error != nil { self?.close() }
    })
  }

  /// The hello and the `connected` answer, each one line; whatever follows belongs to the port.
  private func readAnswers() {
    remote.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] content, _, complete, error in
      guard let self, !self.finished else { return }
      self.buffer.append(content ?? Data())
      while !self.joined, let newline = self.buffer.firstIndex(of: 0x0A) {
        let line = Data(self.buffer[self.buffer.startIndex..<newline])
        self.buffer = Data(self.buffer[self.buffer.index(after: newline)...])
        guard self.answer(line) else { return self.close() }
      }
      if self.joined { return self.join() }
      if error != nil || complete || self.buffer.count > 4096 { return self.close() }
      self.readAnswers()
    }
  }

  private func answer(_ line: Data) -> Bool {
    guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return false }
    if !greeted {
      guard value["type"] as? String == "hello", value["machineId"] as? String == machineId,
            value["service"] as? String == "tunnel" else { return false }
      greeted = true
      writeLine(["type": "connect", "port": Int(port), "host": "127.0.0.1"])
      return true
    }
    guard value["type"] as? String == "connected" else { return false }
    joined = true
    return true
  }

  private func join() {
    let rest = buffer
    buffer = Data()
    if rest.isEmpty {
      pump(from: remote, to: local)
    } else {
      local.send(content: rest, completion: .contentProcessed { [weak self] error in
        guard let self else { return }
        if error != nil { return self.close() }
        self.pump(from: self.remote, to: self.local)
      })
    }
    pump(from: local, to: remote)
  }

  private func pump(from source: NWConnection, to sink: NWConnection) {
    source.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] content, _, complete, error in
      guard let self, !self.finished else { return }
      if error != nil { return self.close() }
      if let content, !content.isEmpty {
        sink.send(content: content, isComplete: false, completion: .contentProcessed { [weak self] error in
          guard let self, !self.finished else { return }
          if error != nil { return self.close() }
          if complete { self.end(source, sink) } else { self.pump(from: source, to: sink) }
        })
      } else if complete {
        self.end(source, sink)
      } else {
        self.pump(from: source, to: sink)
      }
    }
  }

  private func end(_ source: NWConnection, _ sink: NWConnection) {
    sink.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
    ended.insert(ObjectIdentifier(source))
    if ended.count == 2 { close() }
  }
}
