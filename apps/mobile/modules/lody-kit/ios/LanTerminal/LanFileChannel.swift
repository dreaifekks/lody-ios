import CryptoKit
import Foundation
import Network

/// The `files` service of a LAN member (`lan-files.ts`). After the hello the
/// connection carries files one after another: a JSON header, the member's
/// `ready`, exactly the announced bytes, then the block it stored them as. The
/// same connection gives a kept file back: `read`, then `content` and its bytes.
enum LanFileProtocol {
  /// `SESSION_FILE_MAX_SIZE_BYTES` and `SESSION_FILE_MAX_COUNT`.
  static let maxSize = 100 * 1024 * 1024
  static let maxCount = 8
  static let idleTimeout: TimeInterval = 60
  static let helloMaxBytes = 4096
  static let answerMaxBytes = 64 * 1024
  /// `LAN_FILES_PROTOCOL_VERSION`, advertised as `protocolCapabilities.lanFiles`.
  static let version = 1

  /// `toStoredFileName` decides the name the member stores; this only keeps the
  /// header inside its limits and the name free of path separators.
  static func headerFileName(_ name: String) -> String {
    let base = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
    let cleaned = String(base.trimmingCharacters(in: .whitespaces).unicodeScalars.map {
      $0.value < 32 ? "_" : Character($0)
    })
    if cleaned.isEmpty || cleaned == "." || cleaned == ".." { return "file" }
    return String(cleaned.prefix(512))
  }

  /// Whether a machine's metadata says its member takes files (`machineSupportsLanFiles`).
  static func supported(_ capabilities: Any?) -> Bool {
    guard let version = (capabilities as? [String: Any])?["lanFiles"] as? Int else { return false }
    return version >= Self.version
  }
}

/// One TLS-PSK connection to the `files` service of a LAN member, used by one
/// task at a time. Failures carry Lody's `code:message` text.
final class LanFileChannel: @unchecked Sendable {
  struct Failure: Error, LocalizedError, Equatable {
    let code: String
    let message: String
    var errorDescription: String? { message }
  }

  private let endpoint: LanTerminalEndpoint
  private let machineId: String
  private let queue = DispatchQueue(label: "app.lody.lan-files")
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
      connection.stateUpdateHandler = nil
      connection.cancel()
    }
  }

  // MARK: - Session

  /// Connects and exchanges hellos for the `files` service.
  func open() async throws {
    try await withTaskCancellationHandler {
      try await connect()
      armIdleTimeout()
      try await writeLine(["type": "hello", "version": LanTerminalProtocol.version,
                           "machineId": machineId, "service": "files"])
      let line = try await readLine(maxBytes: LanFileProtocol.helloMaxBytes, deadline: LanTerminalProtocol.handshakeTimeout)
      let answer = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
      if answer?["type"] as? String == "error" {
        throw Failure(code: "remote_unreachable", message: answer?["message"] as? String ?? "the machine refused the connection")
      }
      guard answer?["type"] as? String == "hello", answer?["machineId"] as? String == machineId else {
        throw Failure(code: "remote_unreachable", message: "another machine answered")
      }
      // A build from before services answers every hello as a terminal.
      guard (answer?["service"] as? String ?? "terminal") == "files" else {
        throw Failure(code: "remote_unreachable", message: "the machine serves no files; update it")
      }
    } onCancel: { close() }
  }

  /// Sends one file and returns the block the member stored it as.
  func send(file url: URL, fileName: String, sessionId: String,
            onProgress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws -> [String: Any] {
    try await withTaskCancellationHandler {
      let (size, sha256) = try Self.describe(url)
      try await writeLine(["type": "file", "sessionId": sessionId,
                           "fileName": LanFileProtocol.headerFileName(fileName),
                           "sizeBytes": size, "sha256": sha256])
      let ready = try await readAnswer()
      guard ready["type"] as? String == "ready" else { throw Self.unexpected }
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      var sent: Int64 = 0
      onProgress(0, Int64(size))
      while sent < Int64(size), let chunk = try handle.read(upToCount: min(256 * 1024, size - Int(sent))), !chunk.isEmpty {
        try Task.checkCancellation()
        try await write(chunk)
        sent += Int64(chunk.count)
        onProgress(sent, Int64(size))
      }
      guard sent == Int64(size) else {
        throw Failure(code: "invalid_file", message: "\(fileName) changed while it was sent")
      }
      let stored = try await readAnswer()
      guard stored["type"] as? String == "stored", let block = stored["file"] as? [String: Any] else { throw Self.unexpected }
      guard block["type"] as? String == "file", block["transport"] as? String == "local",
            block["machineId"] as? String == machineId,
            (block["sha256"] as? String)?.lowercased() == sha256,
            block["sizeBytes"] as? Int == size,
            let fileId = block["fileId"] as? String, !fileId.isEmpty else {
        throw Failure(code: "remote_unreachable", message: "the machine stored another file than the one sent")
      }
      return block
    } onCancel: { close() }
  }

  /// Writes a file the member keeps to `destination`, which must not exist,
  /// once its size and digest are those of the block. A damaged file is removed.
  func read(sessionId: String, fileId: String, sizeBytes: Int, sha256: String, to destination: URL,
            onProgress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws {
    try await withTaskCancellationHandler {
      try await writeLine(["type": "read", "sessionId": sessionId, "fileId": fileId])
      let answer = try await readAnswer()
      guard answer["type"] as? String == "content", let size = answer["sizeBytes"] as? Int else { throw Self.unexpected }
      guard size == sizeBytes, size > 0, size <= LanFileProtocol.maxSize else {
        throw Failure(code: "invalid_file", message: "the machine keeps another file under that name")
      }
      guard FileManager.default.createFile(atPath: destination.path, contents: nil,
                                           attributes: [.posixPermissions: 0o600]) else {
        throw Failure(code: "file_read_failed", message: "the file cannot be written on this device")
      }
      var complete = false
      defer { if !complete { try? FileManager.default.removeItem(at: destination) } }
      let handle = try FileHandle(forWritingTo: destination)
      defer { try? handle.close() }
      var hash = SHA256()
      var received: Int64 = 0
      onProgress(0, Int64(size))
      while received < Int64(size) {
        try Task.checkCancellation()
        let chunk = try await readChunk(limit: size - Int(received))
        hash.update(data: chunk)
        try handle.write(contentsOf: chunk)
        received += Int64(chunk.count)
        onProgress(received, Int64(size))
      }
      guard Self.hex(hash.finalize()) == sha256.lowercased() else {
        throw Failure(code: "invalid_file", message: "the file arrived damaged")
      }
      complete = true
    } onCancel: { close() }
  }

  // MARK: - Wire

  private static let unexpected = Failure(code: "remote_unreachable", message: "the machine answered with something else")

  private static func unreachable(_ endpoint: LanTerminalEndpoint, _ reason: String) -> Failure {
    Failure(code: "remote_unreachable", message: "\(endpoint.host):\(endpoint.port): \(reason)")
  }

  private static func hex(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
  }

  private static func describe(_ url: URL) throws -> (Int, String) {
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
      throw Failure(code: "invalid_file", message: "\(url.lastPathComponent) is empty")
    }
    guard size <= LanFileProtocol.maxSize else {
      throw Failure(code: "invalid_file", message: "\(url.lastPathComponent) is larger than 100 MB")
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
      try Task.checkCancellation()
      hash.update(data: data)
    }
    return (size, hex(hash.finalize()))
  }

  /// One answer line; a refusal becomes its `code:message` failure.
  private func readAnswer() async throws -> [String: Any] {
    let line = try await readLine(maxBytes: LanFileProtocol.answerMaxBytes, deadline: nil)
    guard let answer = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw Self.unexpected }
    if answer["type"] as? String == "error" {
      let code = answer["code"] as? String ?? "file_refused"
      let message = answer["message"] as? String ?? code
      let prefix = "\(code):"
      throw Failure(code: code, message: message.hasPrefix(prefix) ? String(message.dropFirst(prefix.count)) : message)
    }
    return answer
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
      if Date().timeIntervalSince(self.lastActivity) > LanFileProtocol.idleTimeout {
        self.connection.cancel()
      } else {
        self.armIdleTimeout()
      }
    }
  }

  private func writeLine(_ value: [String: Any]) async throws {
    var data = try JSONSerialization.data(withJSONObject: value)
    data.append(0x0A)
    try await write(data)
  }

  private func write(_ data: Data) async throws {
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

  private func readLine(maxBytes: Int, deadline: TimeInterval?) async throws -> Data {
    while true {
      if let newline = buffer.firstIndex(of: 0x0A) {
        let line = Data(buffer[buffer.startIndex..<newline])
        buffer = Data(buffer[buffer.index(after: newline)...])
        if line.allSatisfy({ $0 == 0x20 || $0 == 0x0D }) { continue }
        return line
      }
      if buffer.count > maxBytes { throw Failure(code: "remote_unreachable", message: "the machine sent an oversized line") }
      guard try await receiveMore(deadline: deadline) else {
        throw Failure(code: "remote_unreachable", message: "the machine closed the connection")
      }
    }
  }

  private func readChunk(limit: Int) async throws -> Data {
    if buffer.isEmpty, !(try await receiveMore(deadline: nil)) {
      throw Failure(code: "remote_unreachable", message: "connection closed in the middle of a file")
    }
    let count = min(limit, buffer.count)
    let chunk = Data(buffer.prefix(count))
    buffer = Data(buffer.dropFirst(count))
    return chunk
  }
}
