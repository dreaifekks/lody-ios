import Foundation

// Compile this check with packages/LodyData/Sources/LAN/LanImageCache.swift.
// Deterministic coalescing, retry and late-scope fencing; no network/listener.
@MainActor
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  precondition(condition(), message)
}

@MainActor
final class Gate {
  var next: CheckedContinuation<Void, Never>?
  var entered = false
  func wait() async {
    entered = true
    await withCheckedContinuation { next = $0 }
  }
  func release() { next?.resume(); next = nil }
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("lan-cache-check-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: root) }
let cache = await LanImageCache(directory: root)
let digest = String(repeating: "a", count: 64)
let gate = await Gate()
var fetches = 0
let first = Task { @MainActor in
  try await cache.file(digest: digest, scope: "account-A") { directory in
    fetches += 1
    await gate.wait()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("first.png")
    try Data("picture".utf8).write(to: file)
    return file
  }
}
while await !gate.entered { await Task.yield() }
let second = Task { @MainActor in
  try await cache.file(digest: digest.uppercased(), scope: "account-A") { _ in
    fatalError("Same digest must join the first load even with another filename")
  }
}
await Task.yield()
await gate.release()
let a = try await first.value
let b = try await second.value
check(a == b && a.lastPathComponent == digest && fetches == 1, "digest coalescing")

let retryDigest = String(repeating: "b", count: 64)
do {
  _ = try await cache.file(digest: retryDigest, scope: "account-A") { _ in throw CocoaError(.fileReadUnknown) }
  fatalError("failed fetch must throw")
} catch {}
let retried = try await cache.file(digest: retryDigest, scope: "account-A") { directory in
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let url = directory.appendingPathComponent("retry.jpg")
  try Data("retried".utf8).write(to: url)
  return url
}
check(FileManager.default.fileExists(atPath: retried.path), "failed load released for retry")

let lateGate = await Gate()
let late = Task { @MainActor in
  try await cache.file(digest: String(repeating: "c", count: 64), scope: "account-A") { directory in
    await lateGate.wait() // Ignores cancellation like a late native callback.
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("late.png")
    try Data("old account".utf8).write(to: url)
    return url
  }
}
while await !lateGate.entered { await Task.yield() }
let switched = try await cache.file(digest: digest, scope: "account-B") { directory in
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let url = directory.appendingPathComponent("new.png")
  try Data("new account".utf8).write(to: url)
  return url
}
await lateGate.release()
do { _ = try await late.value; fatalError("late old account result must fail") } catch {}
check(switched != a, "accounts must not reuse disk identity")
let items = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
check(!items.contains { $0.lastPathComponent.hasPrefix("fetch-") }, "scratch removed after late failure")
print("PASS: LAN image digest coalescing, retry, account switch and late-result fencing")
