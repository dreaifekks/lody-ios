import LodyCore
import Foundation

/// The device platforms behind the shared device-preview route. Each keeps its own
/// signed lifecycle call, state and stream; an iOS proof never authorizes Android.
enum DevicePlatform: String, CaseIterable, Sendable {
  case ios, android

  /// The generic `smartphone` symbol is iOS 17; earlier systems use the closest phone glyph.
  static var androidSymbol: String {
    if #available(iOS 17.0, *) { return "smartphone" }
    return "iphone.gen2"
  }
}

/// Android capture tiers. Remote previews start Balanced; switching starts the same AVD again.
enum DevicePreviewQuality: String, CaseIterable, Sendable {
  case saver, balanced, clear
}

/// One platform's lifecycle calls, normalized so the store, picker and pages stay shared.
@MainActor
struct SimulatorService {
  enum Command: Equatable {
    case list
    case start(id: String, quality: DevicePreviewQuality?)
    case status(operationId: String?)
    case stop(operationId: String, shutdownDevice: Bool = false)
  }
  /// iOS UDIDs and Android AVD names are both `id`.
  struct Device: Equatable, Sendable {
    var id: String
    var name: String
    var runtime: String
    var deviceType: String
    var state: String
    var available: Bool
    var unavailableReason: String?
    var occupied: Bool
  }
  struct Preview: Equatable, Sendable {
    var operationId: String
    var deviceId: String
    var phase: String
    var viewerUrl: String?
    var message: String?
  }
  struct Reply {
    var success: Bool
    var devices: [Device]?
    var preview: Preview?
    var error: String?
    var message: String?
  }

  let platform: DevicePlatform
  let isLAN: Bool
  var release: @MainActor () -> Void
  var whenReleased: @MainActor (@escaping @MainActor () -> Void) -> Void
  var canReuse: @MainActor () -> Bool
  var call: @MainActor (Command) async throws -> Reply

  init(platform: DevicePlatform, isLAN: Bool = false, release: @escaping @MainActor () -> Void = {},
       whenReleased: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void = { _ in },
       canReuse: @escaping @MainActor () -> Bool = { true },
       call: @escaping @MainActor (Command) async throws -> Reply) {
    self.platform = platform
    self.isLAN = isLAN
    self.release = release
    self.whenReleased = whenReleased
    self.canReuse = canReuse
    self.call = call
  }

  static func ios(isLAN: Bool = false, release: @escaping @MainActor () -> Void = {},
                  whenReleased: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void = { _ in },
                  canReuse: @escaping @MainActor () -> Bool = { true },
                  _ call: @escaping @MainActor (RuntimeContract.IosSimulatorControlParamsCommand) async throws -> RuntimeContract.IosSimulatorControlResult) -> Self {
    Self(platform: .ios, isLAN: isLAN, release: release, whenReleased: whenReleased, canReuse: canReuse, call: { command in
      let wire: RuntimeContract.IosSimulatorControlParamsCommand = switch command {
      case .list: .list(.init())
      case .start(let id, _): .start(.init(udid: id))
      case .status(let operationId): .status(.init(operationId: operationId))
      case .stop(let operationId, let shutdownDevice): .stop(.init(operationId: operationId, shutdownDevice: shutdownDevice ? true : nil))
      }
      let reply = try await call(wire)
      return Reply(success: reply.success == true,
        devices: reply.devices?.map { Device(id: $0.udid, name: $0.name, runtime: $0.runtime, deviceType: $0.deviceType, state: $0.state,
          available: $0.available, unavailableReason: $0.unavailableReason, occupied: $0.occupancy == .otherSession) },
        preview: reply.preview.map { Preview(operationId: $0.operationId, deviceId: $0.udid, phase: $0.phase.rawValue, viewerUrl: $0.viewerUrl, message: $0.message) },
        error: reply.error, message: reply.message)
    })
  }

  static func android(_ call: @escaping @MainActor (RuntimeContract.AndroidEmulatorControlParamsCommand) async throws -> RuntimeContract.AndroidEmulatorControlResult) -> Self {
    Self(platform: .android, call: { command in
      let wire: RuntimeContract.AndroidEmulatorControlParamsCommand = switch command {
      case .list: .list(.init())
      case .start(let id, let quality): .start(.init(id: id, quality: quality.flatMap { RuntimeContract.AndroidEmulatorControlParamsCommandStartQuality(rawValue: $0.rawValue) }))
      case .status(let operationId): .status(.init(operationId: operationId))
      case .stop(let operationId, let shutdownDevice): .stop(.init(operationId: operationId, shutdownDevice: shutdownDevice ? true : nil))
      }
      let reply = try await call(wire)
      return Reply(success: reply.success == true,
        devices: reply.devices?.map { Device(id: $0.id, name: $0.name, runtime: $0.runtime, deviceType: $0.deviceType, state: $0.state,
          available: $0.available, unavailableReason: $0.unavailableReason, occupied: $0.occupancy == .otherSession) },
        preview: reply.preview.map { Preview(operationId: $0.operationId, deviceId: $0.id, phase: $0.phase.rawValue, viewerUrl: $0.viewerUrl, message: $0.message) },
        error: reply.error, message: reply.message)
    })
  }
}

@MainActor
final class SessionSimulator {
  typealias Device = SimulatorService.Device
  private struct Watcher { weak var owner: AnyObject?; let changed: () -> Void }
  let sessionId: String
  let service: SimulatorService
  var platform: DevicePlatform { service.platform }
  var canShutdownDevice = false {
    didSet {
      guard oldValue != canShutdownDevice else { return }
      publish()
    }
  }
  private(set) var deviceType = ""
  private(set) var name = ""
  private(set) var phase = "closed"
  private(set) var message = ""
  private(set) var preview: SimulatorService.Preview?
  private(set) var ownership = 0
  /// Android only; the host does not report the tier, so this is the last one requested.
  private(set) var quality = DevicePreviewQuality.balanced
  var onStop: (() -> Void)?
  private var version = 0
  private var task: Task<Void, Never>?
  private var watchers: [Watcher] = []
  private var hidden: String?
  var running: Bool { !["failed", "closed"].contains(phase) }
  var connecting: Bool { ["preparing", "booting", "connecting"].contains(phase) }
  var phaseText: String {
    let key = ["preparing": "starting", "booting": "starting", "connecting": "connecting", "ready": "ready", "failed": "failed", "closed": "closed"][phase]!
    // Starting and failure name the device kind; the other phases read the same on both platforms.
    let prefix = platform == .android && ["starting", "failed"].contains(key) ? "emulator.phase." : "simulator.phase."
    return String(localized: String.LocalizationValue(prefix + key), bundle: .lody)
  }
  var sourceJSON: String {
    guard phase == "ready", let preview, let url = preview.viewerUrl else { return "" }
    // Streams are shared by `streamId`, so it carries the platform as well as the operation.
    let data = try! JSONSerialization.data(withJSONObject: ["streamId": platform.rawValue + ":" + sessionId + ":" + preview.operationId,
      "url": url, "udid": preview.deviceId, "name": name, "operationId": preview.operationId, "platform": platform.rawValue])
    return String(decoding: data, as: UTF8.self)
  }
  var previewJSON: String { hidden == preview?.operationId ? "" : sourceJSON }

  init(sessionId: String, service: SimulatorService) {
    self.sessionId = sessionId; self.service = service
    service.whenReleased { [weak self] in self?.released() }
  }
  isolated deinit { task?.cancel(); service.release() }
  private func released() {
    ownership += 1
    version += 1; task?.cancel(); task = nil
    preview = nil; phase = "closed"; publish()
  }
  func finish() {
    ownership += 1
    version += 1; task?.cancel(); task = nil; service.release()
    if service.isLAN { preview = nil; phase = "closed"; publish() }
  }
  func watch(_ owner: AnyObject, changed: @escaping () -> Void) {
    watchers.removeAll { $0.owner == nil || $0.owner === owner }
    watchers.append(.init(owner: owner, changed: changed))
  }
  private func publish() { watchers.removeAll { $0.owner == nil }; for watcher in watchers { watcher.changed() } }
  func hidePreview() { hidden = preview?.operationId; publish() }
  func revealPreview() { hidden = nil; publish() }

  func devices() async throws -> [Device] {
    let reply = try await request(.list)
    guard let devices = reply.devices else { throw NSError(domain: "LodyKit.Simulator", code: 1, userInfo: [NSLocalizedDescriptionKey: "simulator_invalid_response"]) }
    return devices
  }
  func resume() async throws -> Bool {
    version += 1
    let token = version
    if !running { phase = "connecting" }
    message = ""; publish()
    do {
      let reply = try await request(.status(operationId: nil))
      guard token == version else { return false }
      guard let preview = reply.preview, preview.phase != "failed", preview.phase != "closed" else {
        phase = "closed"; self.preview = nil; publish(); return false
      }
      let devices = try await devices()
      guard token == version else { return false }
      let current = devices.first { $0.id == preview.deviceId }
      name = current?.name ?? preview.deviceId
      deviceType = current?.deviceType ?? ""
      apply(reply)
      poll(token: token)
      return true
    } catch {
      if token == version { fail(error) }
      throw error
    }
  }
  func start(_ device: Device) {
    deviceType = device.deviceType
    start(id: device.id, name: device.name)
  }
  /// Android: starts the running AVD again at another tier, replacing the capture operation.
  func setQuality(_ next: DevicePreviewQuality) {
    guard platform == .android, let preview, next != quality else { return }
    quality = next
    start(id: preview.deviceId, name: name)
  }
  private func start(id: String, name: String) {
    version += 1
    let token = version
    task?.cancel(); self.name = name; preview = nil; hidden = nil; phase = "preparing"; message = ""; publish()
    let quality = platform == .android ? quality : nil
    task = Task { [weak self] in
      guard let self else { return }
      do {
        let reply = try await request(.start(id: id, quality: quality))
        guard !Task.isCancelled, token == version else { return }
        apply(reply)
        try await polling(token: token)
      } catch { if !Task.isCancelled, token == version { fail(error) } }
    }
  }
  func stop(shutdownDevice: Bool = false) async throws {
    version += 1; task?.cancel(); task = nil
    let operationId = preview?.operationId
    service.release()
    preview = nil; phase = "closed"; publish()
    onStop?()
    guard let operationId else { return }
    _ = try await request(.stop(operationId: operationId, shutdownDevice: shutdownDevice))
  }
  private func request(_ command: SimulatorService.Command) async throws -> SimulatorService.Reply {
    let reply = try await service.call(command)
    guard reply.success else {
      // A list failure on Android usually means the SDK or emulator binary is missing.
      let missing = platform == .android && command == .list && reply.error == "unavailable"
      let fallback = String(localized: String.LocalizationValue(missing ? "emulator.sdkUnavailable" : "simulator.phase.failed"), bundle: .lody)
      throw NSError(domain: "LodyKit.Simulator", code: 1,
        userInfo: [NSLocalizedDescriptionKey: missing ? fallback : reply.message ?? reply.error ?? fallback])
    }
    return reply
  }
  private func apply(_ reply: SimulatorService.Reply) {
    preview = reply.preview; phase = reply.preview?.phase ?? "closed"; message = reply.preview?.message ?? ""; publish()
  }
  private func fail(_ error: Error) { phase = "failed"; message = error.localizedDescription; publish() }
  private func poll(token: Int) {
    task?.cancel()
    task = Task { [weak self] in
      do { try await self?.polling(token: token) }
      catch { if !Task.isCancelled, let self, token == version { fail(error) } }
    }
  }
  private func polling(token: Int) async throws {
    for _ in 0..<180 {
      guard token == version, connecting, let operationId = preview?.operationId else { return }
      try await Task.sleep(for: .seconds(1))
      let reply = try await request(.status(operationId: operationId))
      guard token == version, !Task.isCancelled else { return }
      apply(reply)
    }
    if token == version, connecting { throw NSError(domain: "LodyKit.Simulator", code: 1,
      userInfo: [NSLocalizedDescriptionKey: String(localized: String.LocalizationValue(platform == .android ? "emulator.phase.failed" : "simulator.phase.failed"), bundle: .lody)]) }
  }
}
