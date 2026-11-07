import Foundation
import UniformTypeIdentifiers

/// Attachments on a LAN, which has no blob store. Like Lody's `LanFileHandoff`,
/// the bytes go to the machine that runs the session over its `files`
/// service and stay there; the message carries the `local` file blocks that
/// machine answers with, images included.
public enum LanSessionFiles {
  public struct Machine: Sendable {
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
      throw SessionAttachments.error(String(localized: "native.attachment.error.lanLimit", bundle: .lodyData))
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
          throw SessionAttachments.error(String(localized: "native.attachment.error.invalid", bundle: .lodyData))
        }
        let attachmentID = attachment["id"] as? String ?? ""
        onProgress(attachmentID, "preparing", nil)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let count = values.fileSize, count > 0, count <= LanFileProtocol.maxSize else {
          throw SessionAttachments.error(String(localized: "native.attachment.error.empty", bundle: .lodyData))
        }
        var source = url, fileName = name
        // The machine takes a file's type from its extension, so an image an
        // agent cannot read is sent as the JPEG the Cloud path would upload.
        if kind == "image", UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) != true,
           !SessionAttachments.sendsImageAsIs(url, size: count) {
          let payload = try SessionAttachments.imagePayload(url, name: name, size: count)
          let directory = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
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
      throw SessionAttachments.error(String.localizedStringWithFormat(String(localized: "native.attachment.error.lanSend", bundle: .lodyData), machine.name, failure.message))
    }
    return blocks
  }

  /// Fetches a file the machine keeps into `directory`.
  public static func download(invite: LanInvite, machine: Machine, session: String, fileId: String, fileName: String,
                       sizeBytes: Int?, sha256: String?, directory: URL) async throws -> URL {
    guard !session.isEmpty, !fileId.isEmpty, let sizeBytes, sizeBytes > 0, let sha256, sha256.count == 64, sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }) else {
      throw SessionAttachments.error(String(localized: "native.attachment.error.invalid", bundle: .lodyData))
    }
    guard sizeBytes <= LanFileProtocol.maxSize else {
      throw SessionAttachments.error(String(localized: "native.attachment.error.tooLarge", bundle: .lodyData))
    }
    let channel = try channel(invite: invite, machine: machine)
    defer { channel.close() }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory.appendingPathComponent(LanFileProtocol.headerFileName(fileName))
    do {
      try await channel.open()
      try await channel.read(sessionId: session, fileId: fileId, sizeBytes: sizeBytes, sha256: sha256, to: destination)
    } catch let failure as LanFileChannel.Failure {
      throw SessionAttachments.error(String.localizedStringWithFormat(String(localized: "native.attachment.error.lanRead", bundle: .lodyData), machine.name, failure.message))
    }
    return destination
  }

  private static func channel(invite: LanInvite, machine: Machine) throws -> LanFileChannel {
    guard let endpoint = machine.endpoint, machine.takesFiles else {
      throw SessionAttachments.error(String.localizedStringWithFormat(String(localized: "native.attachment.error.lanMachine", bundle: .lodyData), machine.name))
    }
    return LanFileChannel(endpoint: endpoint, lanId: invite.id,
                          key: LanTerminalProtocol.key(token: invite.token), machineId: machine.id)
  }
}
