import Foundation
import Network

/// One bounded TLS-PSK member connection shared by hub discovery and files.
final class LanMemberChannel: @unchecked Sendable {
  struct Failure: Error, LocalizedError, Equatable {
    let code: String
    let message: String
    var errorDescription: String? { message }
  }

  private let endpoint: LanTerminalEndpoint
  private let machineId: String
  private let queue = DispatchQueue(label: "app.lody.lan-member")
  private let connection: NWConnection
  private var buffer = Data()
  private var ended = false
  private var lastActivity = Date()
  private var closed = false

  init(endpoint: LanTerminalEndpoint, lanId: String, key: Data, machineId: String) {
    self.endpoint = endpoint
    self.machineId = machineId
    connection = LanTerminalProtocol.connection(to: endpoint, lanId: lanId, key: key)
  }

  deinit { connection.cancel() }

  func close() {
    queue.async { [self] in
      closed = true
      connection.cancel()
    }
  }

  // MARK: - Session

  /// Connects and exchanges hellos for a member JSON service, such as `hub`.
  func open(service: String = "hub") async throws {
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await connect()
      armIdleTimeout()
      try await writeLine(["type": "hello", "version": LanTerminalProtocol.version,
                           "machineId": machineId, "service": service])
      let line = try await readLine(maxBytes: 4096, deadline: LanTerminalProtocol.handshakeTimeout)
      let answer = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
      if answer?["type"] as? String == "error" {
        throw Failure(code: "remote_unreachable", message: answer?["message"] as? String ?? "the machine refused the connection")
      }
      guard answer?["type"] as? String == "hello", answer?["version"] as? Int == LanTerminalProtocol.version,
        answer?["machineId"] as? String == machineId else {
        throw Failure(code: "remote_unreachable", message: "another machine answered")
      }
      // A build from before services answers every hello as a terminal.
      guard (answer?["service"] as? String ?? "terminal") == service else {
        throw Failure(code: "remote_unreachable", message: "the machine serves no \(service); update it")
      }
    } onCancel: { close() }
  }

  /// Sends one request line and reads its answer line, within `timeout`.
  func request(_ value: [String: Any], timeout: TimeInterval,
               maxBytes: Int = 64 * 1024) async throws -> [String: Any] {
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await writeLine(value)
      let line = try await readLine(maxBytes: maxBytes, deadline: timeout)
      guard let answer = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw Self.unexpected }
      if answer["type"] as? String == "error" {
        throw Failure(code: "remote_unreachable", message: answer["message"] as? String ?? "the machine refused")
      }
      return answer
    } onCancel: { close() }
  }

  // MARK: - Wire

  private static let unexpected = Failure(code: "remote_unreachable", message: "the machine answered with something else")

  private static func unreachable(_ endpoint: LanTerminalEndpoint, _ reason: String) -> Failure {
    Failure(code: "remote_unreachable", message: "\(endpoint.host):\(endpoint.port): \(reason)")
  }

  /// Resumes a continuation once; every caller runs on `queue`.
  private final class Once<Value: Sendable>: @unchecked Sendable {
    private var continuation: CheckedContinuation<Value, Error>?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    var pending: Bool { continuation != nil }
    func resume(_ result: Result<Value, Error>) {
      continuation?.resume(with: result)
      continuation = nil
    }
  }

  private func connect() async throws {
    let endpoint = self.endpoint
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let once = Once(continuation)
      queue.async { [self] in
        guard !closed else { once.resume(.failure(CancellationError())); return }
        connection.stateUpdateHandler = { [weak self] state in
          switch state {
          case .ready:
            once.resume(.success(()))
          case let .waiting(error), let .failed(error):
            // A refused or unrouted address waits forever; the member is unreachable.
            once.resume(.failure(Self.unreachable(endpoint, error.localizedDescription)))
            self?.connection.cancel()
          case .cancelled:
            once.resume(.failure(CancellationError()))
          default:
            break
          }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + LanTerminalProtocol.handshakeTimeout) { [weak self] in
          guard once.pending else { return }
          once.resume(.failure(Self.unreachable(endpoint, "timed out")))
          self?.connection.cancel()
        }
      }
    }
  }

  /// Cancels a connection that neither sent nor received for a minute, which
  /// fails whatever was waiting on it.
  private func armIdleTimeout() {
    queue.asyncAfter(deadline: .now() + 5) { [weak self] in
      guard let self, !self.closed else { return }
      if Date().timeIntervalSince(self.lastActivity) > 60 {
        self.connection.cancel()
      } else {
        self.armIdleTimeout()
      }
    }
  }

  func writeLine(_ value: [String: Any]) async throws {
    var data = try JSONSerialization.data(withJSONObject: value)
    data.append(0x0A)
    try await write(data)
  }

  func write(_ data: Data) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      queue.async { [self] in
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
          self?.lastActivity = Date()
          if let error {
            continuation.resume(throwing: Failure(code: "remote_unreachable", message: error.localizedDescription))
          } else {
            continuation.resume()
          }
        })
      }
    }
  }

  /// Fills `buffer` with whatever arrives next; `false` once the member closed.
  private func receiveMore(deadline: TimeInterval?) async throws -> Bool {
    if ended { return false }
    let received: Data? = try await withCheckedThrowingContinuation { continuation in
      let once = Once(continuation)
      queue.async { [self] in
        if let deadline {
          queue.asyncAfter(deadline: .now() + deadline) { [weak self] in
            guard once.pending else { return }
            once.resume(.failure(Failure(code: "remote_unreachable", message: "the machine did not answer in time")))
            self?.connection.cancel()
          }
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] content, _, complete, error in
          self?.lastActivity = Date()
          guard once.pending else { return }
          if let content, !content.isEmpty {
            if complete { self?.ended = true }
            once.resume(.success(content))
          } else if let error {
            once.resume(.failure(Failure(code: "remote_unreachable", message: error.localizedDescription)))
          } else {
            once.resume(.success(nil))
          }
        }
      }
    }
    guard let received else {
      ended = true
      return false
    }
    buffer.append(received)
    return true
  }

  func readLine(maxBytes: Int, deadline: TimeInterval?) async throws -> Data {
    let end = deadline.map { ProcessInfo.processInfo.systemUptime + $0 }
    while true {
      let remaining = end.map { $0 - ProcessInfo.processInfo.systemUptime }
      if let remaining, remaining <= 0 { throw Self.unexpected }
      if let newline = buffer.firstIndex(of: 0x0A) {
        guard buffer.distance(from: buffer.startIndex, to: newline) <= maxBytes else { throw Self.unexpected }
        let line = Data(buffer[buffer.startIndex..<newline])
        buffer = Data(buffer[buffer.index(after: newline)...])
        if line.allSatisfy({ $0 == 0x20 || $0 == 0x0D }) { continue }
        return line
      }
      if buffer.count > maxBytes { throw Failure(code: "remote_unreachable", message: "the machine sent an oversized line") }
      guard try await receiveMore(deadline: remaining) else {
        throw Failure(code: "remote_unreachable", message: "the machine closed the connection")
      }
    }
  }

  func readChunk(limit: Int) async throws -> Data {
    if buffer.isEmpty, !(try await receiveMore(deadline: nil)) {
      throw Failure(code: "remote_unreachable", message: "connection closed in the middle of a file")
    }
    let count = min(limit, buffer.count)
    let chunk = Data(buffer.prefix(count))
    buffer = Data(buffer.dropFirst(count))
    return chunk
  }
}
