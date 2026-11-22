import Foundation
import LodyCore

/// Downloads a `local_attachment` through Machine RPC `file/download-chunk`,
/// assembling chunks directly onto disk while enforcing `revision` continuity
/// and a total byte ceiling.
enum LocalAttachmentDownloader {
  static let defaultMaxBytes = 100 * 1024 * 1024

  typealias FetchChunk = @MainActor (RuntimeContract.DownloadFileChunkParams) async throws -> RuntimeContract.DownloadFileChunkResult

  @MainActor
  static func download(
    sessionId: String,
    attachment: ChatMessageAttachment,
    directory: URL,
    maxBytes: Int = defaultMaxBytes,
    isCurrent: @escaping @MainActor () -> Bool = { true },
    fetchChunk: FetchChunk
  ) async throws -> URL {
    guard attachment.isLocalAttachment,
      let machineId = attachment.machineId, !machineId.isEmpty,
      let path = attachment.path, !path.isEmpty else {
      throw SessionAttachments.error(String(localized: "native.attachment.error.invalid", bundle: .lody))
    }
    if let declared = attachment.sizeBytes, declared > maxBytes {
      throw SessionAttachments.error(String(localized: "native.file.error.tooLarge", bundle: .lody))
    }
    let kind: RuntimeContract.LocalAttachmentRefKind = attachment.kind == "image" ? .image : .file
    let mimeType = attachment.mimeType.flatMap { $0.isEmpty ? nil : $0 } ?? "application/octet-stream"
    let declaredSize = max(0, attachment.sizeBytes ?? 0)
    let ref = RuntimeContract.LocalAttachmentRef(
      type: "local_attachment",
      machineId: machineId,
      path: path,
      kind: kind,
      fileName: attachment.fileName,
      mimeType: mimeType,
      sizeBytes: declaredSize
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory.appendingPathComponent(LanFileProtocol.headerFileName(attachment.fileName))
    guard !FileManager.default.fileExists(atPath: destination.path),
      FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
      throw SessionAttachments.error(String(localized: "native.file.error.read", bundle: .lody))
    }
    var complete = false
    defer { if !complete { try? FileManager.default.removeItem(at: destination) } }
    let handle = try FileHandle(forWritingTo: destination)
    defer { try? handle.close() }

    var offset = 0
    var revision: String?
    var totalSize: Int?

    while true {
      try Task.checkCancellation()
      guard isCurrent() else { throw CancellationError() }
      let params = RuntimeContract.DownloadFileChunkParams(
        sessionId: sessionId,
        path: path,
        attachment: ref,
        offset: offset,
        revision: offset > 0 ? revision : nil
      )
      let response = try await fetchChunk(params)
      try Task.checkCancellation()
      guard isCurrent() else { throw CancellationError() }
      switch response {
      case .error(let failure):
        throw error(for: failure.code)
      case .ok(let chunk):
        guard !chunk.revision.isEmpty else {
          throw SessionAttachments.error(String(localized: "native.file.error.decode", bundle: .lody))
        }
        guard chunk.sizeBytes >= 0, chunk.sizeBytes <= maxBytes else {
          throw SessionAttachments.error(String(localized: "native.file.error.tooLarge", bundle: .lody))
        }
        guard chunk.offset == offset else {
          throw SessionAttachments.error(String(localized: "native.file.error.decode", bundle: .lody))
        }
        if let expectedRevision = revision {
          guard chunk.revision == expectedRevision else { throw error(for: "file_changed") }
        } else {
          revision = chunk.revision
        }
        if let expectedSize = totalSize {
          guard chunk.sizeBytes == expectedSize else { throw error(for: "file_changed") }
        } else {
          totalSize = chunk.sizeBytes
        }
        guard let bytes = Data(base64Encoded: chunk.data) else {
          throw SessionAttachments.error(String(localized: "native.file.error.decode", bundle: .lody))
        }
        if !bytes.isEmpty {
          guard offset + bytes.count <= chunk.sizeBytes, offset + bytes.count <= maxBytes else {
            throw SessionAttachments.error(String(localized: "native.file.error.decode", bundle: .lody))
          }
          try handle.write(contentsOf: bytes)
          offset += bytes.count
        }
        if offset == chunk.sizeBytes {
          complete = true
          return destination
        }
        guard !bytes.isEmpty else {
          throw SessionAttachments.error(String(localized: "native.file.error.decode", bundle: .lody))
        }
      }
    }
  }

  static func error(for code: String) -> NSError {
    let key: String
    switch code {
    case "file_changed":
      key = "native.file.error.stale"
    case "file_not_found", "not_a_file":
      key = "native.file.error.notFound"
    case "path_not_allowed", "invalid_path":
      key = "native.file.error.pathNotAllowed"
    case "permission_denied", "paid_plan_required":
      key = "native.file.error.permissionDenied"
    case "too_large":
      key = "native.file.error.tooLarge"
    case "machine_offline", "session_not_found", "workspace_root_unavailable":
      key = "native.file.error.offline"
    case "decode_error":
      key = "native.file.error.decode"
    case "unsupported_protocol":
      key = "native.attachment.error.unavailable"
    default:
      key = "native.file.error.read"
    }
    return SessionAttachments.error(String(localized: String.LocalizationValue(key), bundle: .lody))
  }
}
