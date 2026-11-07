import CryptoKit
import Foundation

/// A digest has one canonical path regardless of filename or extension.
/// Scope changes cancel old loads and fence their disk/cache side effects.
@MainActor
public final class LanImageCache {
  public static let didCache = Notification.Name("LanKeptImagesDidCache")
  private let root: URL
  private var scope = ""
  private var loads: [String: Task<URL, Error>] = [:]

  public init(directory: URL) { root = directory }

  public func file(digest: String, scope: String, load: @escaping @MainActor (URL) async throws -> URL) async throws -> URL {
    let digest = digest.lowercased()
    guard digest.utf8.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
      throw CocoaError(.fileReadInvalidFileName)
    }
    if self.scope != scope {
      loads.values.forEach { $0.cancel() }
      loads.removeAll()
      self.scope = scope
    }
    let account = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
    let directory = root.appendingPathComponent(account, isDirectory: true)
    let destination = directory.appendingPathComponent(digest)
    if FileManager.default.fileExists(atPath: destination.path) { return destination }
    if let pending = loads[digest] {
      let url = try await pending.value
      try Task.checkCancellation()
      guard self.scope == scope else { throw CancellationError() }
      return url
    }
    let task = Task { @MainActor in
      let scratch = root.appendingPathComponent("fetch-\(UUID().uuidString)", isDirectory: true)
      defer { try? FileManager.default.removeItem(at: scratch) }
      let fetched = try await load(scratch)
      try Task.checkCancellation()
      guard self.scope == scope else { throw CancellationError() }
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try FileManager.default.moveItem(at: fetched, to: destination)
      NotificationCenter.default.post(name: Self.didCache, object: self, userInfo: ["sha256": digest, "scope": scope])
      return destination
    }
    loads[digest] = task
    do {
      let result = try await task.value
      if self.scope == scope { loads[digest] = nil }
      try Task.checkCancellation()
      guard self.scope == scope else { throw CancellationError() }
      return result
    } catch {
      if self.scope == scope { loads[digest] = nil }
      throw error
    }
  }
}
