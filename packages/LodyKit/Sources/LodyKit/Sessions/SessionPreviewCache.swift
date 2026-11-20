import Foundation
import UIKit

/// Bounded in-memory cache that keeps active device preview streams (iOS Simulator / Android
/// Emulator) and managed browser previews alive across conversation switches until explicitly
/// stopped, evicted, cleared on logout / workspace switch, or purged on memory warning.
///
/// Capability URLs and preview tokens live strictly in memory — never written to UserDefaults,
/// SQLite, or any synced store.
@MainActor
final class SessionPreviewCache {
  static let shared = SessionPreviewCache()
  static let maxDevices = 4
  static let maxBrowsers = 4
  static let defaultBrowserTTL: TimeInterval = 60 * 60

  struct SessionKey: Hashable, Sendable {
    let workspaceId: String
    let userId: String
    let sessionId: String
  }

  struct DeviceKey: Hashable, Sendable {
    let session: SessionKey
    let platform: DevicePlatform
  }

  final class BrowserEntry {
    var url: URL
    var expiresAt: Date
    let controller: BrowserPreviewController

    init(url: URL, expiresAt: Date, controller: BrowserPreviewController) {
      self.url = url
      self.expiresAt = expiresAt
      self.controller = controller
    }

    func isValid(at now: Date = Date()) -> Bool {
      expiresAt > now
    }
  }

  private final class DeviceEntry {
    let store: SessionSimulator
    var stream: SimulatorStreamView?

    init(store: SessionSimulator) {
      self.store = store
    }
  }

  private var devices: [DeviceKey: DeviceEntry] = [:]
  private var deviceOrder: [DeviceKey] = []
  private var browsers: [SessionKey: BrowserEntry] = [:]
  private var browserOrder: [SessionKey] = []
  private var memoryObserver: NSObjectProtocol?

  init(observeMemoryWarning: Bool = true) {
    if observeMemoryWarning {
      memoryObserver = NotificationCenter.default.addObserver(
        forName: UIApplication.didReceiveMemoryWarningNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.clearAll() }
      }
    }
  }

  isolated deinit {
    if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
  }

  // MARK: - Device Previews (iOS Simulator & Android Emulator)

  func device(for key: DeviceKey, create: () -> SessionSimulator) -> SessionSimulator {
    if let existing = devices[key] {
      bumpDevice(key)
      syncDeviceStream(for: key, entry: existing)
      return existing.store
    }
    let store = create()
    let entry = DeviceEntry(store: store)
    devices[key] = entry
    deviceOrder.append(key)
    store.onStop = { [weak self] in
      self?.removeDevice(for: key)
    }
    store.watch(self) { [weak self] in
      guard let self, let current = self.devices[key] else { return }
      self.syncDeviceStream(for: key, entry: current)
    }
    syncDeviceStream(for: key, entry: entry)
    evictDevicesIfNeeded(preserving: key)
    return store
  }

  func cachedDevice(for key: DeviceKey) -> SessionSimulator? {
    devices[key]?.store
  }

  func isDeviceCached(_ store: SessionSimulator) -> Bool {
    devices.values.contains { $0.store === store }
  }

  func removeDevice(for key: DeviceKey) {
    deviceOrder.removeAll { $0 == key }
    guard let entry = devices.removeValue(forKey: key) else { return }
    teardownDevice(entry)
  }

  private func syncDeviceStream(for key: DeviceKey, entry: DeviceEntry) {
    let json = entry.store.sourceJSON
    if !json.isEmpty {
      if let next = SimulatorStreamView.shared(json) {
        if entry.stream !== next {
          releaseStream(entry.stream)
          next.isRetainedByCache = true
          entry.stream = next
        }
      }
      bumpDevice(key)
    } else if !entry.store.running {
      releaseStream(entry.stream)
      entry.stream = nil
    }
  }

  private func bumpDevice(_ key: DeviceKey) {
    deviceOrder.removeAll { $0 == key }
    deviceOrder.append(key)
  }

  private func evictDevicesIfNeeded(preserving protectedKey: DeviceKey) {
    while devices.count > Self.maxDevices {
      // Prefer evicting an idle/stopped entry over an actively running stream.
      let candidate = deviceOrder.first { $0 != protectedKey && devices[$0]?.store.running != true }
        ?? deviceOrder.first { $0 != protectedKey }
      guard let key = candidate else { break }
      removeDevice(for: key)
    }
  }

  private func teardownDevice(_ entry: DeviceEntry) {
    releaseStream(entry.stream)
    entry.stream = nil
    entry.store.onStop = nil
    entry.store.finish()
  }

  private func releaseStream(_ stream: SimulatorStreamView?) {
    guard let stream else { return }
    stream.isRetainedByCache = false
    stream.stop()
  }

  // MARK: - Browser Previews

  func cachedBrowser(for key: SessionKey) -> BrowserEntry? {
    browsers[key]
  }

  func browser(for key: SessionKey) -> BrowserEntry? {
    guard let entry = browsers[key] else { return nil }
    bumpBrowser(key)
    return entry
  }

  @discardableResult
  func storeBrowser(url: URL, expiresAt: Date, controller: BrowserPreviewController, for key: SessionKey) -> BrowserEntry {
    if let existing = browsers[key], existing.controller !== controller {
      existing.controller.teardown()
    }
    let entry = BrowserEntry(url: url, expiresAt: expiresAt, controller: controller)
    browsers[key] = entry
    bumpBrowser(key)
    evictBrowsersIfNeeded(preserving: key)
    return entry
  }

  func updateBrowser(for key: SessionKey, url: URL, expiresAt: Date) {
    guard let entry = browsers[key] else { return }
    entry.url = url
    entry.expiresAt = expiresAt
    bumpBrowser(key)
  }

  func removeBrowser(for key: SessionKey) {
    browserOrder.removeAll { $0 == key }
    guard let entry = browsers.removeValue(forKey: key) else { return }
    entry.controller.teardown()
  }

  private func bumpBrowser(_ key: SessionKey) {
    browserOrder.removeAll { $0 == key }
    browserOrder.append(key)
  }

  private func evictBrowsersIfNeeded(preserving protectedKey: SessionKey) {
    while browsers.count > Self.maxBrowsers {
      guard let key = browserOrder.first(where: { $0 != protectedKey }) else { break }
      removeBrowser(for: key)
    }
  }

  // MARK: - Scope / Lifecycle Cleanup

  func clearOutside(workspaceId: String, userId: String) {
    for key in Array(devices.keys) where key.session.workspaceId != workspaceId || key.session.userId != userId {
      removeDevice(for: key)
    }
    for key in Array(browsers.keys) where key.workspaceId != workspaceId || key.userId != userId {
      removeBrowser(for: key)
    }
  }

  func clearAll() {
    for entry in devices.values { teardownDevice(entry) }
    devices.removeAll()
    deviceOrder.removeAll()
    for entry in browsers.values { entry.controller.teardown() }
    browsers.removeAll()
    browserOrder.removeAll()
  }

  // MARK: - Preview URL Helpers

  private static let tokenParam = "__lody_preview_token"
  private static let tunnelHostRegex = try! NSRegularExpression(pattern: "^[a-z0-9]+(?:-[a-z0-9]+)*\\.trycloudflare\\.com$")

  static func validatedPreviewURL(_ raw: String?) -> URL? {
    guard let raw, let url = URL(string: raw),
          url.scheme == "https",
          url.user == nil,
          url.password == nil,
          url.port == nil,
          let host = url.host else { return nil }
    let range = NSRange(host.startIndex..<host.endIndex, in: host)
    guard tunnelHostRegex.firstMatch(in: host, range: range) != nil else { return nil }
    return url
  }

  static func resolveExpiresAt(_ expiresAtMs: Double?, now: Date = Date()) -> Date {
    if let expiresAtMs, expiresAtMs.isFinite, expiresAtMs > 0 {
      return Date(timeIntervalSince1970: expiresAtMs / 1000)
    }
    return now.addingTimeInterval(defaultBrowserTTL)
  }

  /// Combines a newly regenerated tunnel URL (origin + fresh token) with the path, non-token
  /// query parameters, and fragment the user was last browsing.
  static func mergedPreviewURL(newBase: URL, previousPage: URL?) -> URL {
    guard let previousPage,
          var nextComponents = URLComponents(url: newBase, resolvingAgainstBaseURL: false),
          let previousComponents = URLComponents(url: previousPage, resolvingAgainstBaseURL: false) else {
      return newBase
    }
    let previousPath = previousComponents.percentEncodedPath
    if !previousPath.isEmpty, previousPath.hasPrefix("/"), !previousPath.hasPrefix("//") {
      nextComponents.percentEncodedPath = previousPath
    }
    let tokenItems = (nextComponents.queryItems ?? []).filter { $0.name == tokenParam }
    let preservedItems = (previousComponents.queryItems ?? []).filter { $0.name != tokenParam }
    let mergedQuery = preservedItems + tokenItems
    nextComponents.queryItems = mergedQuery.isEmpty ? nil : mergedQuery
    nextComponents.fragment = previousComponents.fragment
    guard let merged = nextComponents.url,
          merged.scheme == newBase.scheme,
          merged.host == newBase.host,
          merged.port == newBase.port else {
      return newBase
    }
    return merged
  }
}
