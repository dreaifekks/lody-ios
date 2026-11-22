import Foundation
import Network

/// One loopback listener. Each connection it accepts opens a tunnel to the
/// same port of the member's loopback. Suspension in the background breaks a
/// listening socket, so one that failed after it listened listens again.
final class LanPortForward: @unchecked Sendable {
  let machineId: String
  let port: UInt16
  private var connect: @Sendable () -> NWConnection
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

  /// New viewer connections follow the member's latest address without rebinding.
  func updateConnection(_ connect: @escaping @Sendable () -> NWConnection) {
    queue.async { [self] in self.connect = connect }
  }

  func start() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      queue.async { [self] in
        guard !closed else { continuation.resume(throwing: CancellationError()); return }
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
        sink.send(content: content, isComplete: true, completion: .contentProcessed { [weak self] error in
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
    sink.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] error in
      guard let self, !self.finished else { return }
      if error != nil { return self.close() }
      self.ended.insert(ObjectIdentifier(source))
      if self.ended.count == 2 { self.close() }
    })
  }
}
