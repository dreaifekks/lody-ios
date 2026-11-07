import Foundation
import Network

public struct LanTerminalSnapshot: Sendable, Equatable, Decodable {
  public let terminalId: String
  public let title: String
  public let cwd: String?
}

/// A server event of the terminal protocol (`TerminalServerEventSchema`).
public enum LanTerminalEvent: Sendable, Equatable {
  case terminals(requestId: String?, sessionId: String, terminals: [LanTerminalSnapshot])
  case opened(requestId: String?, terminalId: String, cwd: String?)
  case data(requestId: String?, terminalId: String, data: String, replay: Bool)
  case title(requestId: String?, terminalId: String, title: String)
  case exit(requestId: String?, terminalId: String, exitCode: Int, signal: String?)
  case error(requestId: String?, terminalId: String?, code: String, message: String)

  public var requestId: String? {
    switch self {
    case let .terminals(id, _, _), let .opened(id, _, _), let .data(id, _, _, _),
         let .title(id, _, _), let .exit(id, _, _, _), let .error(id, _, _, _):
      id
    }
  }

  private struct Wire: Decodable {
    let type: String
    let requestId: String?
    let sessionId: String?
    let terminalId: String?
    let terminals: [LanTerminalSnapshot]?
    let cwd: String?
    let data: String?
    let replay: Bool?
    let title: String?
    let exitCode: Int?
    let signal: String?
    let code: String?
    let message: String?
  }

  /// `nil` for a line that is not a valid event; the desktop closes the link then.
  public static func decode(_ line: Data) -> LanTerminalEvent? {
    guard let wire = try? JSONDecoder().decode(Wire.self, from: line) else { return nil }
    let id = wire.requestId
    switch wire.type {
    case "terminals":
      guard let sessionId = wire.sessionId, let terminals = wire.terminals else { return nil }
      return .terminals(requestId: id, sessionId: sessionId, terminals: terminals)
    case "opened":
      guard let terminalId = wire.terminalId, !terminalId.isEmpty else { return nil }
      return .opened(requestId: id, terminalId: terminalId, cwd: wire.cwd)
    case "data":
      guard let terminalId = wire.terminalId, let data = wire.data else { return nil }
      return .data(requestId: id, terminalId: terminalId, data: data, replay: wire.replay ?? false)
    case "title":
      guard let terminalId = wire.terminalId, let title = wire.title else { return nil }
      return .title(requestId: id, terminalId: terminalId, title: title)
    case "exit":
      guard let terminalId = wire.terminalId, let exitCode = wire.exitCode else { return nil }
      return .exit(requestId: id, terminalId: terminalId, exitCode: exitCode, signal: wire.signal)
    case "error":
      guard let code = wire.code, !code.isEmpty, let message = wire.message else { return nil }
      return .error(requestId: id, terminalId: wire.terminalId, code: code, message: message)
    default:
      return nil
    }
  }
}

/// A client message of the terminal protocol (`TerminalClientMessageSchema`).
public struct LanTerminalCommand: Sendable, Encodable, Equatable {
  public let type: String
  public var requestId: String?
  public var sessionId: String?
  public var terminalId: String?
  public var cols: Int?
  public var rows: Int?
  public var data: String?

  public static func list(sessionId: String) -> Self { .init(type: "list", sessionId: sessionId) }
  public static func open(sessionId: String, cols: Int, rows: Int) -> Self {
    .init(type: "open", sessionId: sessionId, cols: cols, rows: rows)
  }
  public static func attach(terminalId: String, cols: Int, rows: Int) -> Self {
    .init(type: "attach", terminalId: terminalId, cols: cols, rows: rows)
  }
  public static func input(terminalId: String, data: String) -> Self {
    .init(type: "input", terminalId: terminalId, data: data)
  }
  public static func resize(terminalId: String, cols: Int, rows: Int) -> Self {
    .init(type: "resize", terminalId: terminalId, cols: cols, rows: rows)
  }
  public static func close(terminalId: String) -> Self { .init(type: "close", terminalId: terminalId) }
}

/// Splits a byte stream into lines. Lines are split on the byte, so a
/// multi-byte character never straddles two lines.
public struct LanTerminalLineBuffer: Sendable {
  public static let maxLine = 1024 * 1024
  private var pending = Data()

  public enum Failure: Error, Equatable { case lineTooLong }

  public mutating func append(_ chunk: Data) throws -> [Data] {
    pending.append(chunk)
    var lines: [Data] = []
    while let newline = pending.firstIndex(of: 0x0A) {
      guard pending.distance(from: pending.startIndex, to: newline) <= Self.maxLine else { throw Failure.lineTooLong }
      let line = pending[pending.startIndex..<newline]
      pending = Data(pending[pending.index(after: newline)...])
      let trimmed = line.drop { $0 == 0x20 || $0 == 0x0D }
      if !trimmed.isEmpty { lines.append(Data(trimmed)) }
    }
    if pending.count > Self.maxLine { throw Failure.lineTooLong }
    return lines
  }
}

/// One TLS-PSK connection to the terminal service of a LAN member. Every
/// callback runs on `callbackQueue`; the link itself is confined to `queue`.
public final class LanTerminalLink: @unchecked Sendable {
  public enum Failure: Error, Equatable, LocalizedError {
    case unreachable(String)
    case refused(code: String, message: String)
    case anotherMachine
    case timedOut
    case closed(String)

    public var errorDescription: String? {
      switch self {
      case let .unreachable(reason): reason
      case let .refused(_, message): message
      case .anotherMachine: "another machine answered"
      case .timedOut: "the machine did not answer in time"
      case let .closed(reason): reason
      }
    }
  }

  private static let requestTimeout: TimeInterval = 9
  private var stopping = false
  private var closing = false
  private var ownedTerminal: String?
  private var opening = Set<String>()
  // Retain only while an open answer is outstanding, so departure can close it.
  private var draining: LanTerminalLink?

  private let endpoint: LanTerminalEndpoint
  private let machineId: String
  private let queue = DispatchQueue(label: "app.lody.lan-terminal")
  private let callbackQueue: DispatchQueue
  private let connection: NWConnection
  private var lines = LanTerminalLineBuffer()
  private var started = false
  private var greeted = false
  private var finished = false
  private var sequence = 0
  private var pending: [String: @Sendable (Result<LanTerminalEvent, Failure>) -> Void] = [:]
  private var onReady: (@Sendable (Result<Void, Failure>) -> Void)?

  /// Events that answer no pending request: live output, titles and exits.
  public var onEvent: (@Sendable (LanTerminalEvent) -> Void)?
  public var onClose: (@Sendable (Failure) -> Void)?

  public init(endpoint: LanTerminalEndpoint, lanId: String, key: Data, machineId: String, callbackQueue: DispatchQueue = .main) {
    self.endpoint = endpoint
    self.machineId = machineId
    self.callbackQueue = callbackQueue
    connection = LanTerminalProtocol.connection(to: endpoint, lanId: lanId, key: key)
  }

  deinit { connection.cancel() }

  /// Connects and exchanges hellos; `completion` runs once.
  public func start(completion: @escaping @Sendable (Result<Void, Failure>) -> Void) {
    queue.async { [self] in
      guard !finished, !stopping, !started else {
        callbackQueue.async { completion(.failure(.closed("connection closed"))) }
        return
      }
      started = true
      onReady = completion
      connection.stateUpdateHandler = { [weak self] state in self?.stateChanged(state) }
      connection.start(queue: queue)
      queue.asyncAfter(deadline: .now() + LanTerminalProtocol.handshakeTimeout) { [weak self] in
        guard let self, !self.greeted else { return }
        self.finish(.timedOut)
      }
    }
  }

  /// Sends a command that expects an answer; `completion` gets the event that
  /// carries its request id, or the failure.
  public func request(_ command: LanTerminalCommand, completion: @escaping @Sendable (Result<LanTerminalEvent, Failure>) -> Void) {
    queue.async { [self] in
      guard !finished, !stopping, greeted else {
        callbackQueue.async { completion(.failure(.closed("connection closed"))) }
        return
      }
      if command.type == "open", ownedTerminal != nil || !opening.isEmpty {
        callbackQueue.async { completion(.failure(.closed("this link already owns a shell"))) }
        return
      }
      sequence += 1
      let id = String(sequence)
      var message = command
      message.requestId = id
      if command.type == "open" { opening.insert(id) }
      pending[id] = { [callbackQueue] result in callbackQueue.async { completion(result) } }
      write(message)
      queue.asyncAfter(deadline: .now() + Self.requestTimeout) { [weak self] in
        guard let self else { return }
        self.pending.removeValue(forKey: id)?(.failure(.timedOut))
        if self.opening.contains(id) { self.stopOwnedShell() }
      }
    }
  }

  /// Sends a command that is not answered, such as input or resize.
  public func send(_ command: LanTerminalCommand) {
    queue.async { [self] in
      guard !finished, !stopping, greeted else { return }
      write(command)
    }
  }

  public func cancel() {
    queue.async { [self] in stopOwnedShell() }
  }

  private func stopOwnedShell() {
    guard !finished else { return }
    stopping = true
    if let ownedTerminal { close(terminal: ownedTerminal); return }
    if !opening.isEmpty {
      draining = self
      return // A late open must be closed, never adopted by the UI.
    }
    finish(.closed("closed by this device"))
  }

  /// Ends the remote shell, then the connection once the close has been sent.
  public func close(terminal terminalId: String) {
    queue.async { [self] in
      guard !finished, !closing else { return }
      stopping = true
      closing = true
      draining = self
      guard var data = try? JSONEncoder().encode(LanTerminalCommand.close(terminalId: terminalId)) else {
        return finish(.closed("closed by this device"))
      }
      data.append(0x0A)
      connection.send(content: data, completion: .contentProcessed { [weak self] error in
        if let error { self?.finish(.closed(error.localizedDescription)) }
      })
      // Prefer the server's exit/EOF after close. Older members do not answer
      // close, so bound the drain once the command has been submitted.
      queue.asyncAfter(deadline: .now() + 2) { [weak self] in
        self?.finish(.closed("closed by this device"))
      }
    }
  }

  private func stateChanged(_ state: NWConnection.State) {
    switch state {
    case .ready:
      write(Hello(type: "hello", version: LanTerminalProtocol.version, machineId: machineId, service: "terminal"))
      receive()
    case let .waiting(error):
      // A refused or unrouted address waits forever; the member is unreachable.
      finish(.unreachable("\(endpoint.host):\(endpoint.port): \(error.localizedDescription)"))
    case let .failed(error):
      finish(.unreachable("\(endpoint.host):\(endpoint.port): \(error.localizedDescription)"))
    case .cancelled:
      finish(.closed("connection closed"))
    default:
      break
    }
  }

  private struct Hello: Codable {
    let type: String
    let version: Int
    let machineId: String
    let service: String?
  }

  private struct Refusal: Decodable {
    let type: String
    let code: String
    let message: String
  }

  private func write(_ value: some Encodable) {
    guard var data = try? JSONEncoder().encode(value) else { return }
    data.append(0x0A)
    connection.send(content: data, completion: .contentProcessed { [weak self] error in
      guard let error else { return }
      self?.finish(.closed(error.localizedDescription))
    })
  }

  private func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] content, _, complete, error in
      guard let self, !self.finished else { return }
      if let content, !content.isEmpty {
        do {
          for line in try self.lines.append(content) {
            self.handle(line)
            if self.finished { return }
          }
        } catch {
          self.finish(.closed("the machine sent an oversized line"))
          return
        }
      }
      if let error {
        self.finish(.closed(error.localizedDescription))
      } else if complete {
        self.finish(.closed("connection closed"))
      } else {
        self.receive()
      }
    }
  }

  private func handle(_ line: Data) {
    guard greeted else {
      if let refusal = try? JSONDecoder().decode(Refusal.self, from: line), refusal.type == "error" {
        finish(.refused(code: refusal.code, message: refusal.message))
        return
      }
      guard let hello = try? JSONDecoder().decode(Hello.self, from: line), hello.type == "hello",
            hello.version == LanTerminalProtocol.version, hello.machineId == machineId else {
        finish(.anotherMachine)
        return
      }
      // A build from before services answers every hello as a terminal.
      guard (hello.service ?? "terminal") == "terminal" else {
        finish(.refused(code: "unsupported_service", message: "the machine serves no terminals; update it"))
        return
      }
      greeted = true
      let ready = onReady
      onReady = nil
      callbackQueue.async { ready?(.success(())) }
      return
    }
    guard let event = LanTerminalEvent.decode(line) else {
      finish(.closed("the machine sent an invalid terminal event"))
      return
    }
    if case let .exit(_, terminalId, _, _) = event, closing, terminalId == ownedTerminal {
      finish(.closed("closed by this device")); return
    }
    if case let .opened(id, terminalId, _) = event, let id, opening.remove(id) != nil {
      ownedTerminal = terminalId
      if stopping { close(terminal: terminalId); return }
    } else if let id = event.requestId, opening.remove(id) != nil, stopping {
      finish(.closed("closed by this device")); return
    }
    if let id = event.requestId, let waiting = pending[id] {
      // An attach answers with its replay first; the title closes it.
      if case .data = event {
        forward(event)
        return
      }
      pending.removeValue(forKey: id)
      if case let .error(_, _, code, message) = event {
        waiting(.failure(.refused(code: code, message: message)))
      } else {
        waiting(.success(event))
      }
      return
    }
    forward(event)
  }

  private func forward(_ event: LanTerminalEvent) {
    let handler = onEvent
    callbackQueue.async { handler?(event) }
  }

  private func finish(_ failure: Failure) {
    guard !finished else { return }
    finished = true
    draining = nil
    opening.removeAll()
    connection.stateUpdateHandler = nil
    connection.cancel()
    let ready = onReady
    onReady = nil
    let waiting = Array(pending.values)
    pending.removeAll()
    for callback in waiting { callback(.failure(failure)) }
    let close = onClose
    callbackQueue.async {
      ready?(.failure(failure))
      if ready == nil { close?(failure) }
    }
  }
}
