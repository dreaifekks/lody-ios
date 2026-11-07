import Foundation

@MainActor
public enum LanKeptImages {
  public static let didCache = LanImageCache.didCache
  private static let cache = LanImageCache(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("lan-images", isDirectory: true))

  public static func file(_ image: ChatImage, workspace: String, session: String) async throws -> URL {
    guard let runtime = DataRuntime.current, runtime.isLAN, runtime.workspace == workspace,
      let digest = image.sha256, let machine = image.machineId, !machine.isEmpty,
      let size = image.sizeBytes, size > 0, size <= 10 * 1024 * 1024 else {
      throw SessionAttachments.error(String(localized: "native.attachment.error.invalid", bundle: .lodyData))
    }
    let scope = runtime.attachmentScope
    let url = try await cache.file(digest: digest, scope: scope) { scratch in
      do {
        let reference = ChatMessageAttachment(id: image.id, fileName: image.fileName,
          storageSessionId: image.storageSessionId, transport: "local", sizeBytes: size,
          machineId: machine, sha256: digest)
        return try await runtime.downloadAttachment(reference, workspace: workspace, session: session, directory: scratch)
      } catch {
        try? FileManager.default.removeItem(at: scratch)
        throw error
      }
    }
    try Task.checkCancellation()
    guard DataRuntime.current === runtime, runtime.attachmentScope == scope else { throw CancellationError() }
    return url
  }
}
