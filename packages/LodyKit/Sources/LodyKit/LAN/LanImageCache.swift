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
    return try await cached(key: digest, noticeKey: "sha256", noticeValue: digest,
      scope: scope, epoch: epoch, isCurrent: isCurrent, load: load)
  }

  /// Caches a LAN local-first image by its UUID `localImageId` in a namespace
  /// disjoint from 64-character hex digests (`local-<uuid>`).
  public func file(localImageId: String, scope: String, epoch: String = "",
    isCurrent: @escaping @MainActor () -> Bool = { true },
    load: @escaping @MainActor (URL) async throws -> URL) async throws -> URL {
    guard UUID(uuidString: localImageId) != nil else {
      throw CocoaError(.fileReadInvalidFileName)
    }
    let normalized = localImageId.lowercased()
    return try await cached(key: "local-\(normalized)", noticeKey: "localImageId", noticeValue: normalized,
      scope: scope, epoch: epoch, isCurrent: isCurrent, load: load)
  }

  private func cached(key: String, noticeKey: String, noticeValue: String,
    scope: String, epoch: String,
    isCurrent: @escaping @MainActor () -> Bool,
    load: @escaping @MainActor (URL) async throws -> URL) async throws -> URL {
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
    let destination = directory.appendingPathComponent(key)
    // A warm cache needs no runtime, member endpoint, or network availability.
    if FileManager.default.fileExists(atPath: destination.path) { return destination }
    if let pending = loads[key] {
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
      NotificationCenter.default.post(name: Self.didCache, object: self,
        userInfo: [noticeKey: noticeValue, "key": key, "scope": scope])
      return destination
    }
    loads[key] = Pending(id: id, task: task)
    do {
      let result = try await task.value
      if loads[key]?.id == id { loads[key] = nil }
      try Task.checkCancellation()
      guard self.revision == revision, isCurrent() else { throw CancellationError() }
      return result
    } catch {
      if loads[key]?.id == id { loads[key] = nil }
      throw error
    }
  }
}
