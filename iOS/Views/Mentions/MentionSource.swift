import LodyCore
import Foundation

typealias MentionCatalog = RuntimeContract.MentionCatalog
typealias MentionItem = RuntimeContract.MentionCatalogItemsItem

struct MentionSource: Codable, Equatable, Sendable {
  var workspaceId: String
  var sessionId: String?
  var projectId: String?
  var machineId: String?
  var agentConfigId: String?
  var cliType: String?
  var agentType: String?
}

@MainActor
struct MentionService {
  var load: @MainActor (MentionSource, String) async throws -> MentionCatalog

  static let live = MentionService { source, category in
    if let catalog = try await MentionPresenceFixture.response(source, category) { return catalog }
    if let fixture = MentionFixture.response(payload(source, category)),
       let catalog = try? JSONDecoder().decode(MentionCatalog.self, from: Data(fixture.utf8)) {
      return catalog
    }
    guard let runtime = DataRuntime.current, runtime.workspace == source.workspaceId,
          let kind = RuntimeContract.MentionCatalogParamsCategory(rawValue: category) else {
      throw DataRuntime.failure("not_ready", String(localized: "native.runtime.sessionNotSynced", bundle: .lody))
    }
    return try await runtime.workspaceCall(RuntimeContract.Calls.MentionCatalog.self) { workspaceId, userId in
      RuntimeContract.MentionCatalogParams(
        workspaceId: workspaceId, userId: userId, category: kind, sessionId: source.sessionId, projectId: source.projectId,
        machineId: source.machineId, agentConfigId: source.agentConfigId, cliType: source.cliType, agentType: source.agentType
      )
    }
  }

  private static func payload(_ source: MentionSource, _ category: String) -> String {
    var object = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(source))) as? [String: Any] ?? [:]
    object["category"] = category
    let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    return String(decoding: data, as: UTF8.self)
  }
}

@MainActor
final class MentionCatalogStore {
  static let didChange = Notification.Name("LodyMentionCatalogDidChange")
  static let categories = ["file", "skill", "session", "role", "issue", "pr", "cmd"]

  let source: MentionSource
  var changed: (() -> Void)?
  private let service: MentionService
  private var catalogs: [String: MentionCatalog] = [:]
  private var pending: [String: Task<MentionCatalog, Error>] = [:]
  private var failed: Set<String> = []
  private var observer: NSObjectProtocol?
  private var catalogState: CatalogState?

  private struct Presence: Decodable, Equatable {
    let workspaceId: String
    let presence: RuntimeContract.MachinePresence
  }

  private struct CatalogState: Decodable, Equatable {
    let presence: Presence
    let connected: Bool
    let catalogRevision: Int
  }

  init(source: MentionSource, service: MentionService = .live) {
    self.source = source
    self.service = service
    catalogState = Self.currentState()
    observer = NotificationCenter.default.addObserver(forName: .lodyCatalogDidChange, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.catalogChanged() }
    }
  }

  isolated deinit {
    if let observer { NotificationCenter.default.removeObserver(observer) }
  }

  private static func currentState() -> CatalogState? {
    try? JSONDecoder().decode(CatalogState.self, from: Data(CatalogSession.published.json.utf8))
  }

  private func catalogChanged() {
    let next = Self.currentState()
    guard next?.presence.workspaceId == source.workspaceId, next != catalogState else { return }
    catalogState = next
    Task { _ = try? await load("role", refresh: true) }
  }

  func catalog(_ category: String) -> MentionCatalog? { catalogs[category] }

  func preload() {
    for category in Self.categories { Task { _ = try? await load(category) } }
  }

  func load(_ category: String, refresh: Bool = false) async throws -> MentionCatalog {
    if !refresh, let task = pending[category] { return try await task.value }
    let task = Task { try await service.load(source, category) }
    pending[category] = task
    do {
      let value = try await task.value
      guard pending[category] == task else { return value }
      failed.remove(category)
      catalogs[category] = value
      changed?()
      NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: ["category": category])
      return value
    } catch {
      guard pending[category] == task else { throw error }
      pending[category] = nil
      failed.insert(category)
      changed?()
      throw error
    }
  }

  func composerItemsJSON() -> String {
    let rows: [[String: Any]] = Self.categories.filter { category in
      ["file", "skill", "session", "role"].contains(category) || failed.contains(category) || catalogs[category]?.incomplete == true || catalogs[category]?.items.isEmpty == false
    }.map { category in
      let subtitle = failed.contains(category) ? String(localized: "mentions.error", bundle: .lody) : Self.notice(catalogs[category])
      return [
        "path": category, "kind": "category", "subtitle": subtitle,
        "name": String(localized: String.LocalizationValue("native.chat.mention." + (ChatMentionItem.labels[category] ?? category)), bundle: .lody),
      ]
    }
    let items = Self.categories.compactMap { catalogs[$0] }.flatMap(\.items).compactMap {
      (try? JSONSerialization.jsonObject(with: JSONEncoder().encode($0))) as? [String: Any]
    }
    let data = (try? JSONSerialization.data(withJSONObject: rows + items)) ?? Data("[]".utf8)
    return String(decoding: data, as: UTF8.self)
  }

  static func notice(_ catalog: MentionCatalog?) -> String {
    if catalog == nil { return String(localized: "common.reading", bundle: .lody) }
    if catalog?.incomplete == true { return String(localized: "mentions.incomplete", bundle: .lody) }
    if catalog?.truncated == true { return String(localized: "mentions.truncated", bundle: .lody) }
    return ""
  }
}
