import CryptoKit
import Foundation

/// The `files` service of a LAN member (`lan-files.ts`). After the hello the
/// connection carries files one after another: a JSON header, the member's
/// `ready`, exactly the announced bytes, then the block it stored them as. The
/// same connection gives a kept file back: `read`, then `content` and its bytes.
enum LanFileProtocol {
  /// `SESSION_FILE_MAX_SIZE_BYTES` and `SESSION_FILE_MAX_COUNT`.
  static let maxSize = 100 * 1024 * 1024
  static let maxCount = 8
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

/// File framing on the shared TLS-PSK member transport. One task owns a channel.
final class LanFileChannel: @unchecked Sendable {
  typealias Failure = LanMemberChannel.Failure
  private let machineId: String
  private let member: LanMemberChannel

  init(endpoint: LanTerminalEndpoint, lanId: String, key: Data, machineId: String) {
    self.machineId = machineId
    member = LanMemberChannel(endpoint: endpoint, lanId: lanId, key: key, machineId: machineId)
  }

  func open() async throws { try await member.open(service: "files") }
  func close() { member.close() }

  /// Sends one file and returns the block the member stored it as.
  func send(file url: URL, fileName: String, sessionId: String,
            onProgress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws -> [String: Any] {
    try await withTaskCancellationHandler {
      let (size, sha256) = try Self.describe(url)
      try await member.writeLine(["type": "file", "sessionId": sessionId,
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
        try await member.write(chunk)
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
            let fileId = block["fileId"] as? String, !fileId.isEmpty,
            block["fileName"] is String, block["mimeType"] is String,
            block["textPreview"] is Bool, block["uploadedAt"] is NSNumber else {
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
      try await member.writeLine(["type": "read", "sessionId": sessionId, "fileId": fileId])
      let answer = try await readAnswer()
      guard answer["type"] as? String == "content", let size = answer["sizeBytes"] as? Int else { throw Self.unexpected }
      guard size == sizeBytes, size > 0, size <= LanFileProtocol.maxSize else {
        throw Failure(code: "invalid_file", message: "the machine keeps another file under that name")
      }
      guard !FileManager.default.fileExists(atPath: destination.path),
        FileManager.default.createFile(atPath: destination.path, contents: nil,
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
        let chunk = try await member.readChunk(limit: size - Int(received))
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
    let line = try await member.readLine(maxBytes: LanFileProtocol.answerMaxBytes, deadline: nil)
    guard let answer = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw Self.unexpected }
    if answer["type"] as? String == "error" {
      let code = answer["code"] as? String ?? "file_refused"
      let message = answer["message"] as? String ?? code
      let prefix = "\(code):"
      throw Failure(code: code, message: message.hasPrefix(prefix) ? String(message.dropFirst(prefix.count)) : message)
    }
    return answer
  }

}
