import Foundation

@MainActor
enum LanKeptImages {
  static let didCache = LanImageCache.didCache
  private static let cache = LanImageCache(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("lan-images", isDirectory: true))

  static func file(_ image: ChatImage, workspace: String, session: String) async throws -> URL {
    guard let scope = AuthSession.shared.attachmentIdentity(workspace: workspace),
      AuthSession.shared.snapshot.account?.lan != nil else {
      throw SessionAttachments.error(String(localized: "native.attachment.error.invalid", bundle: .lody))
    }
    let epoch = DataRuntime.current?.attachmentScope ?? "unavailable"
    let isCurrent: @MainActor () -> Bool = {
      AuthSession.shared.attachmentIdentity(workspace: workspace) == scope &&
        (DataRuntime.current?.attachmentScope ?? "unavailable") == epoch
    }
    let url: URL
    if let digest = image.sha256, let machine = image.machineId, !machine.isEmpty,
       let size = image.sizeBytes, size > 0, size <= 10 * 1024 * 1024 {
      url = try await cache.file(digest: digest, scope: scope, epoch: epoch, isCurrent: isCurrent) { scratch in
        // The runtime is required only on a miss. Its I/O generation fence remains
        // authoritative and rejects recovery races without replaying the read.
        guard let runtime = DataRuntime.current, runtime.isLAN, runtime.workspace == workspace,
          runtime.attachmentScope == epoch else {
          throw SessionAttachments.error(String(localized: "native.runtime.notConnected", bundle: .lody))
        }
        let reference = ChatMessageAttachment(id: image.id, fileName: image.fileName,
          storageSessionId: image.storageSessionId, transport: "local", sizeBytes: size,
          machineId: machine, sha256: digest)
        return try await runtime.downloadAttachment(reference, workspace: workspace, session: session, directory: scratch)
      }
    } else if image.transport == "local", let localImageId = image.localImageId, UUID(uuidString: localImageId) != nil {
      if let size = image.sizeBytes, size <= 0 || size > 20 * 1024 * 1024 {
        throw SessionAttachments.error(String(localized: "native.attachment.error.invalid", bundle: .lody))
      }
      url = try await cache.file(localImageId: localImageId, scope: scope, epoch: epoch, isCurrent: isCurrent) { scratch in
        guard let runtime = DataRuntime.current, runtime.isLAN, runtime.workspace == workspace,
          runtime.attachmentScope == epoch else {
          throw SessionAttachments.error(String(localized: "native.runtime.notConnected", bundle: .lody))
        }
        let reference = ChatMessageAttachment(
          id: "image-\(localImageId)",
          fileName: image.fileName,
          image: image,
          storageSessionId: image.storageSessionId,
          transport: "local",
          sizeBytes: image.sizeBytes,
          mimeType: image.mimeType,
          machineId: image.machineId
        )
        return try await runtime.downloadAttachment(reference, workspace: workspace, session: session, directory: scratch)
      }
    } else {
      throw SessionAttachments.error(String(localized: "native.attachment.error.invalid", bundle: .lody))
    }
    try Task.checkCancellation()
    guard AuthSession.shared.attachmentIdentity(workspace: workspace) == scope else { throw CancellationError() }
    return url
  }
}
