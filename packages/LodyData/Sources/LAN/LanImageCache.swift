import CryptoKit
import Foundation

/// Disk identity is stable across runtime recovery. The independent epoch only
/// cancels/fences in-flight reads; it never changes a cached digest's path.
@MainActor
public final class LanImageCache {
  public static let didCache = Notification.Name("LanKeptImagesDidCache")
  private struct Pending {
    let id: UUID
    let task: Task<URL, Error>
  }
  private let root: URL
  private var scope = ""
  private var epoch = ""
  private var revision = UUID()
  private var loads: [String: Pending] = [:]

  public init(directory: URL) { root = directory }

  public func file(digest: String, scope: String, epoch: String = "",
    isCurrent: @escaping @MainActor () -> Bool = { true },
    load: @escaping @MainActor (URL) async throws -> URL) async throws -> URL {
    let digest = digest.lowercased()
    guard digest.utf8.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
      throw CocoaError(.fileReadInvalidFileName)
    }
    if self.scope != scope || self.epoch != epoch {
      loads.values.forEach { $0.task.cancel() }
      loads.removeAll()
      self.scope = scope
      self.epoch = epoch
      revision = UUID()
    }
    let revision = self.revision
    let account = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
    let directory = root.appendingPathComponent(account, isDirectory: true)
    let destination = directory.appendingPathComponent(digest)
    // A warm cache needs no runtime, member endpoint, or network availability.
    if FileManager.default.fileExists(atPath: destination.path) { return destination }
    if let pending = loads[digest] {
      let url = try await pending.task.value
      try Task.checkCancellation()
      guard self.revision == revision, isCurrent() else { throw CancellationError() }
      return url
    }
    let id = UUID()
    let task = Task { @MainActor in
      let scratch = root.appendingPathComponent("fetch-\(UUID().uuidString)", isDirectory: true)
      defer { try? FileManager.default.removeItem(at: scratch) }
      guard self.revision == revision, isCurrent() else { throw CancellationError() }
      let fetched = try await load(scratch)
      try Task.checkCancellation()
      guard self.revision == revision, isCurrent() else { throw CancellationError() }
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try FileManager.default.moveItem(at: fetched, to: destination)
      NotificationCenter.default.post(name: Self.didCache, object: self, userInfo: ["sha256": digest, "scope": scope])
      return destination
    }
    loads[digest] = Pending(id: id, task: task)
    do {
      let result = try await task.value
      if loads[digest]?.id == id { loads[digest] = nil }
      try Task.checkCancellation()
      guard self.revision == revision, isCurrent() else { throw CancellationError() }
      return result
    } catch {
      if loads[digest]?.id == id { loads[digest] = nil }
      throw error
    }
  }
}
