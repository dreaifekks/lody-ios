import Foundation

@MainActor
public enum LanKeptImages {
  public static let didCache = LanImageCache.didCache
  private static let cache = LanImageCache(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("lan-images", isDirectory: true))

  public static func file(_ image: ChatImage, workspace: String, session: String) async throws -> URL {
    guard let scope = AuthSession.shared.attachmentIdentity(workspace: workspace),
      AuthSession.shared.snapshot.account?.lan != nil,
      let digest = image.sha256, let machine = image.machineId, !machine.isEmpty,
      let size = image.sizeBytes, size > 0, size <= 10 * 1024 * 1024 else {
      throw SessionAttachments.error(String(localized: "native.attachment.error.invalid", bundle: .lodyData))
    }
    let epoch = DataRuntime.current?.attachmentScope ?? "unavailable"
    let url = try await cache.file(digest: digest, scope: scope, epoch: epoch, isCurrent: {
      AuthSession.shared.attachmentIdentity(workspace: workspace) == scope &&
        (DataRuntime.current?.attachmentScope ?? "unavailable") == epoch
    }) { scratch in
      // The runtime is required only on a miss. Its I/O generation fence remains
      // authoritative and rejects recovery races without replaying the read.
      guard let runtime = DataRuntime.current, runtime.isLAN, runtime.workspace == workspace,
        runtime.attachmentScope == epoch else {
        throw SessionAttachments.error(String(localized: "native.runtime.notConnected", bundle: .lodyData))
      }
      let reference = ChatMessageAttachment(id: image.id, fileName: image.fileName,
        storageSessionId: image.storageSessionId, transport: "local", sizeBytes: size,
        machineId: machine, sha256: digest)
      return try await runtime.downloadAttachment(reference, workspace: workspace, session: session, directory: scratch)
    }
    try Task.checkCancellation()
    guard AuthSession.shared.attachmentIdentity(workspace: workspace) == scope else { throw CancellationError() }
    return url
  }
}
