import CryptoKit
import Foundation
import Network

/// Where a LAN member accepts terminal connections, as published in its
/// machine metadata. The address is not a secret; the LAN credential opens it.
struct LanTerminalEndpoint: Sendable, Equatable {
  let host: String
  let port: UInt16
}

/// Lody's LAN member protocol (`lan-terminal.ts`): TLS 1.2 with a pre-shared
/// key derived from the LAN credential, one JSON line of hello each way, then
/// newline-delimited terminal messages.
enum LanTerminalProtocol {
  static let version = 1
  static let requestTimeout: TimeInterval = 9
  static let handshakeTimeout: TimeInterval = 10
  /// `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256`, the one suite Node and Electron share.
  static let cipherSuite: UInt16 = 0xCCAC

  /// Mirrors `deriveLanTerminalKey`: the raw SHA-256 of the scoped credential.
  static func key(token: String) -> Data {
    Data(SHA256.hash(data: Data("lody-lan-hub:terminal:\(token)".utf8)))
  }
}

struct LanTerminalSnapshot: Sendable, Equatable, Decodable {
  let terminalId: String
  let title: String
  let cwd: String?
}

/// A server event of the terminal protocol (`TerminalServerEventSchema`).
enum LanTerminalEvent: Sendable, Equatable {
  case terminals(requestId: String?, sessionId: String, terminals: [LanTerminalSnapshot])
  case opened(requestId: String?, terminalId: String, cwd: String?)
  case data(requestId: String?, terminalId: String, data: String, replay: Bool)
  case title(requestId: String?, terminalId: String, title: String)
  case exit(requestId: String?, terminalId: String, exitCode: Int, signal: String?)
  case error(requestId: String?, terminalId: String?, code: String, message: String)

  var requestId: String? {
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
  static func decode(_ line: Data) -> LanTerminalEvent? {
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
struct LanTerminalCommand: Sendable, Encodable, Equatable {
  let type: String
  var requestId: String?
  var sessionId: String?
  var terminalId: String?
  var cols: Int?
  var rows: Int?
  var data: String?

  static func list(sessionId: String) -> Self { .init(type: "list", sessionId: sessionId) }
  static func open(sessionId: String, cols: Int, rows: Int) -> Self {
    .init(type: "open", sessionId: sessionId, cols: cols, rows: rows)
  }
  static func attach(terminalId: String, cols: Int, rows: Int) -> Self {
    .init(type: "attach", terminalId: terminalId, cols: cols, rows: rows)
  }
  static func input(terminalId: String, data: String) -> Self {
    .init(type: "input", terminalId: terminalId, data: data)
  }
  static func resize(terminalId: String, cols: Int, rows: Int) -> Self {
    .init(type: "resize", terminalId: terminalId, cols: cols, rows: rows)
  }
  static func close(terminalId: String) -> Self { .init(type: "close", terminalId: terminalId) }
}

/// Splits a byte stream into lines. Lines are split on the byte, so a
/// multi-byte character never straddles two lines.
struct LanTerminalLineBuffer: Sendable {
  static let maxLine = 1024 * 1024
  private var pending = Data()

  enum Failure: Error, Equatable { case lineTooLong }

  mutating func append(_ chunk: Data) throws -> [Data] {
    pending.append(chunk)
    var lines: [Data] = []
    while let newline = pending.firstIndex(of: 0x0A) {
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
final class LanTerminalLink: @unchecked Sendable {
  enum Failure: Error, Equatable, LocalizedError {
    case unreachable(String)
    case refused(code: String, message: String)
    case anotherMachine
    case timedOut
    case closed(String)

    var errorDescription: String? {
      switch self {
      case let .unreachable(reason): reason
      case let .refused(_, message): message
      case .anotherMachine: "another machine answered"
      case .timedOut: "the machine did not answer in time"
      case let .closed(reason): reason
      }
    }
  }

  private let endpoint: LanTerminalEndpoint
  private let machineId: String
  private let queue = DispatchQueue(label: "app.lody.lan-terminal")
  private let callbackQueue: DispatchQueue
  private let connection: NWConnection
  private var lines = LanTerminalLineBuffer()
  private var greeted = false
  private var finished = false
  private var sequence = 0
  private var pending: [String: @Sendable (Result<LanTerminalEvent, Failure>) -> Void] = [:]
  private var onReady: (@Sendable (Result<Void, Failure>) -> Void)?

  /// Events that answer no pending request: live output, titles and exits.
  var onEvent: (@Sendable (LanTerminalEvent) -> Void)?
  var onClose: (@Sendable (Failure) -> Void)?

  init(endpoint: LanTerminalEndpoint, lanId: String, key: Data, machineId: String, callbackQueue: DispatchQueue = .main) {
    self.endpoint = endpoint
    self.machineId = machineId
    self.callbackQueue = callbackQueue
    let tls = NWProtocolTLS.Options()
    let security = tls.securityProtocolOptions
    let psk = key.withUnsafeBytes { DispatchData(bytes: $0) }
    let identity = Data(lanId.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
    sec_protocol_options_add_pre_shared_key(security, psk as __DispatchData, identity as __DispatchData)
    if let suite = tls_ciphersuite_t(rawValue: LanTerminalProtocol.cipherSuite) {
      sec_protocol_options_append_tls_ciphersuite(security, suite)
    }
    sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
    sec_protocol_options_set_max_tls_protocol_version(security, .TLSv12)
    // Every connection proves the current credential; a cached session would skip the key.
    sec_protocol_options_set_tls_resumption_enabled(security, false)
    let tcp = NWProtocolTCP.Options()
    tcp.enableKeepalive = true
    tcp.keepaliveIdle = 30
    tcp.connectionTimeout = Int(LanTerminalProtocol.handshakeTimeout)
    let parameters = NWParameters(tls: tls, tcp: tcp)
    connection = NWConnection(
      host: NWEndpoint.Host(endpoint.host),
      port: NWEndpoint.Port(rawValue: endpoint.port) ?? 8789,
      using: parameters
    )
  }

  /// Connects and exchanges hellos; `completion` runs once.
  func start(completion: @escaping @Sendable (Result<Void, Failure>) -> Void) {
    queue.async { [self] in
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
  func request(_ command: LanTerminalCommand, completion: @escaping @Sendable (Result<LanTerminalEvent, Failure>) -> Void) {
    queue.async { [self] in
      guard !finished else {
        callbackQueue.async { completion(.failure(.closed("connection closed"))) }
        return
      }
      sequence += 1
      let id = String(sequence)
      var message = command
      message.requestId = id
      pending[id] = { [callbackQueue] result in callbackQueue.async { completion(result) } }
      write(message)
      queue.asyncAfter(deadline: .now() + LanTerminalProtocol.requestTimeout) { [weak self] in
        self?.pending.removeValue(forKey: id)?(.failure(.timedOut))
      }
    }
  }

  /// Sends a command that is not answered, such as input or resize.
  func send(_ command: LanTerminalCommand) {
    queue.async { [self] in
      guard !finished else { return }
      write(command)
    }
  }

  func cancel() {
    queue.async { [self] in finish(.closed("closed by this device")) }
  }

  /// Ends the remote shell, then the connection once the close has been sent.
  func close(terminal terminalId: String) {
    queue.async { [self] in
      guard !finished else { return }
      guard var data = try? JSONEncoder().encode(LanTerminalCommand.close(terminalId: terminalId)) else {
        return finish(.closed("closed by this device"))
      }
      data.append(0x0A)
      connection.send(content: data, completion: .contentProcessed { [weak self] _ in
        self?.finish(.closed("closed by this device"))
      })
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
            hello.machineId == machineId else {
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
    connection.stateUpdateHandler = nil
    connection.cancel()
    let ready = onReady
    onReady = nil
    let waiting = pending.values
    pending.removeAll()
    for callback in waiting { callback(.failure(failure)) }
    let close = onClose
    callbackQueue.async {
      ready?(.failure(failure))
      if ready == nil { close?(failure) }
    }
  }
}
