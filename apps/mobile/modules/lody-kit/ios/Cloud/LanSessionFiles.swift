import Foundation
import UniformTypeIdentifiers

/// Attachments on a LAN, which has no blob store. Like Lody's `LanFileHandoff`,
/// the bytes go to the machine that runs the session over its `files`
/// service and stay there; the message carries the `local` file blocks that
/// machine answers with, images included.
enum LanSessionFiles {
  struct Machine: Sendable {
    let id: String
    let name: String
    let endpoint: LanTerminalEndpoint?
    let takesFiles: Bool
  }

  /// The runtime's `lanFileTarget` answer; `nil` without a machine id.
  static func machine(_ value: [String: Any]) -> Machine? {
    guard let id = value["machineId"] as? String, !id.isEmpty else { return nil }
    let name = (value["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
    return Machine(id: id, name: name, endpoint: endpoint(value["lanTerminal"]),
                   takesFiles: LanFileProtocol.supported(value["protocolCapabilities"]))
  }

  /// Mirrors Lody's `parseLanTerminalEndpoint`.
  static func endpoint(_ value: Any?) -> LanTerminalEndpoint? {
    guard let value = value as? [String: Any], value["version"] as? Int == 1,
          let host = value["host"] as? String, !host.trimmingCharacters(in: .whitespaces).isEmpty,
          host.count <= 255, let port = (value["port"] as? Int).flatMap({ UInt16(exactly: $0) }), port > 0 else {
      return nil
    }
    return LanTerminalEndpoint(host: host, port: port)
  }

  static func upload(_ attachments: [[String: Any]], invite: LanInvite, machine: Machine, session: String,
    onProgress: @escaping SessionAttachments.ProgressHandler = { _, _, _ in }) async throws -> [[String: Any]] {
    guard attachments.count <= LanFileProtocol.maxCount else {
      throw SessionAttachments.error(LodyStrings.text("native.attachment.error.lanLimit"))
    }
    let channel = try channel(invite: invite, machine: machine)
    defer { channel.close() }
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("lan-send-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    var blocks: [[String: Any]] = []
    do {
      try await channel.open()
      for attachment in attachments {
        try Task.checkCancellation()
        guard let uri = attachment["uri"] as? String, let url = URL(string: uri), url.isFileURL,
              url.resolvingSymlinksInPath().path.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"),
              let name = attachment["name"] as? String, !name.isEmpty,
              let kind = attachment["kind"] as? String, ["image", "file"].contains(kind) else {
          throw SessionAttachments.error(LodyStrings.text("native.attachment.error.invalid"))
        }
        let attachmentID = attachment["id"] as? String ?? ""
        onProgress(attachmentID, "preparing", nil)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let count = values.fileSize, count > 0, count <= LanFileProtocol.maxSize else {
          throw SessionAttachments.error(LodyStrings.text("native.attachment.error.empty"))
        }
        var source = url, fileName = name
        // The machine takes a file's type from its extension, so an image an
        // agent cannot read is sent as the JPEG the Cloud path would upload.
        if kind == "image", UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) != true,
           !SessionAttachments.sendsImageAsIs(url, size: count) {
          let payload = try SessionAttachments.imagePayload(url, name: name, size: count)
          let directory = scratch.appendingPathComponent(attachmentID.isEmpty ? UUID().uuidString : attachmentID, isDirectory: true)
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
          source = directory.appendingPathComponent(LanFileProtocol.headerFileName(payload.fileName))
          try payload.bytes.write(to: source)
          fileName = payload.fileName
        }
        let block = try await channel.send(file: source, fileName: fileName, sessionId: session) { sent, total in
          guard total > 0 else { return }
          let percent = min(100, max(0, Int(Double(sent) / Double(total) * 100)))
          onProgress(attachmentID, sent >= total ? "verifying" : "uploading", percent)
        }
        blocks.append(block)
        onProgress(attachmentID, "complete", 100)
      }
    } catch let failure as LanFileChannel.Failure {
      throw SessionAttachments.error(LodyStrings.text("native.attachment.error.lanSend",
        ["machine": machine.name, "reason": failure.message]))
    }
    return blocks
  }

  /// Fetches a file the machine keeps into `directory`.
  static func download(invite: LanInvite, machine: Machine, session: String, fileId: String, fileName: String,
                       sizeBytes: Int?, sha256: String?, directory: URL) async throws -> URL {
    guard !session.isEmpty, !fileId.isEmpty, let sizeBytes, sizeBytes > 0, let sha256, sha256.count == 64 else {
      throw SessionAttachments.error(LodyStrings.text("native.attachment.error.invalid"))
    }
    guard sizeBytes <= LanFileProtocol.maxSize else {
      throw SessionAttachments.error(LodyStrings.text("native.attachment.error.tooLarge"))
    }
    let channel = try channel(invite: invite, machine: machine)
    defer { channel.close() }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory.appendingPathComponent(LanFileProtocol.headerFileName(fileName))
    do {
      try await channel.open()
      try await channel.read(sessionId: session, fileId: fileId, sizeBytes: sizeBytes, sha256: sha256, to: destination)
    } catch let failure as LanFileChannel.Failure {
      throw SessionAttachments.error(LodyStrings.text("native.attachment.error.lanRead",
        ["machine": machine.name, "reason": failure.message]))
    }
    return destination
  }

  private static func channel(invite: LanInvite, machine: Machine) throws -> LanFileChannel {
    guard let endpoint = machine.endpoint, machine.takesFiles else {
      throw SessionAttachments.error(LodyStrings.text("native.attachment.error.lanMachine", ["machine": machine.name]))
    }
    return LanFileChannel(endpoint: endpoint, lanId: invite.id,
                          key: LanTerminalProtocol.key(token: invite.token), machineId: machine.id)
  }
}

/// Pictures LAN machines keep, fetched once per digest into Caches. A
/// thumbnail and its full-screen preview share one fetch.
@MainActor
enum LanKeptImages {
  private static var loads: [String: Task<URL, Error>] = [:]
  private static let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("lan-images", isDirectory: true)

  static func file(_ image: ChatImage, session: String) async throws -> URL {
    guard let sha256 = image.sha256?.lowercased(), sha256.count == 64, sha256.allSatisfy(\.isHexDigit) else {
      throw SessionAttachments.error(LodyStrings.text("native.attachment.error.invalid"))
    }
    let suffix = (image.fileName as NSString).pathExtension.filter { $0.isLetter || $0.isNumber }
    let cached = directory.appendingPathComponent(suffix.isEmpty ? sha256 : "\(sha256).\(suffix)")
    if FileManager.default.fileExists(atPath: cached.path) { return cached }
    if let load = loads[sha256] { return try await load.value }
    let load = Task { @MainActor in
      defer { loads[sha256] = nil }
      guard let runtime = DataRuntime.active else {
        throw SessionAttachments.error(LodyStrings.text("native.runtime.notConnected"))
      }
      let lan = try await runtime.lanFileMachine(machineId: image.machineId)
      let scratch = directory.appendingPathComponent("fetch-\(UUID().uuidString)", isDirectory: true)
      defer { try? FileManager.default.removeItem(at: scratch) }
      let fetched = try await LanSessionFiles.download(invite: lan.0, machine: lan.1, session: image.storageSessionId ?? session,
        fileId: image.id, fileName: image.fileName, sizeBytes: image.sizeBytes, sha256: sha256, directory: scratch)
      try? FileManager.default.removeItem(at: cached)
      try FileManager.default.moveItem(at: fetched, to: cached)
      return cached
    }
    loads[sha256] = load
    return try await load.value
  }
}
