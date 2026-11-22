import LodyCore
import Foundation

/// Presence transitions at the service boundary of the real chat and create hosts.
@MainActor
enum MentionPresenceFixture {
  static var active: Bool { LodyUIVerify.enabled && LodyUIVerify.has("--ui-verify-role-presence") }
  private static var live = false
  private static var revision = 0
  private static var failNext = true
  private static var holdNext = false
  private static var pending: CheckedContinuation<MentionCatalog, Error>?

  static func setLive(_ value: Bool) {
    precondition(active)
    live = value
    if !value { revision = 0 }
    publish()
  }

  static func reviseCatalog() {
    precondition(active && live)
    revision += 1
    publish()
  }

  private static func publish() {
    let value = live
    let presence = RuntimeContract.MachinePresence(state: value ? .live : .unknown, onlineMachineIds: value ? ["ui"] : [])
    let snapshot = CatalogSnapshot(connected: live, catalogRevision: revision, presence: CatalogPresence(workspaceId: "ui-home", presence: presence))
    _ = CatalogSession.published.set(snapshot.json, catalog: CatalogSession.published.raw)
    NotificationCenter.default.post(name: .lodyCatalogDidChange, object: nil)
  }

  static func armReload() {
    precondition(active && pending == nil)
    holdNext = true
  }

  static func finishReload(failed: Bool) {
    precondition(active && pending != nil)
    let completion = pending!
    pending = nil
    if failed { completion.resume(throwing: CocoaError(.fileReadUnknown)) }
    else { completion.resume(returning: MentionCatalog(items: [], truncated: false, incomplete: true)) }
  }

  static func response(_ source: MentionSource, _ category: String) async throws -> MentionCatalog? {
    guard active, source.workspaceId == "ui-home", category == "role" else { return nil }
    if failNext {
      failNext = false
      throw CocoaError(.fileReadUnknown)
    }
    if holdNext {
      holdNext = false
      return try await withCheckedThrowingContinuation { pending = $0 }
    }
    guard live else { return MentionCatalog(items: [], truncated: false, incomplete: true) }
    var items: [MentionItem] = [
      .init(path: "role-reviewer@ui@opus", name: "Reviewer · Opus · Fixture Mac", kind: .role,
        subtitle: "Review with Opus", insertText: "@role:role-reviewer@ui@opus", roleName: "Reviewer"),
      .init(path: "role-reviewer@ui@sol", name: "Reviewer · Sol · Fixture Mac", kind: .role,
        subtitle: "Review with Sol", insertText: "@role:role-reviewer@ui@sol", roleName: "Reviewer"),
    ]
    if revision > 0 {
      items.append(.init(path: "role-synced@ui", name: "Synced reviewer · Fixture Mac", kind: .role,
        subtitle: "Role from the newly synchronized catalog", insertText: "@role:role-synced@ui", roleName: "Synced reviewer"))
    }
    items.append(.init(path: "role-reviewer@remote", name: "Reviewer · Remote Mac", kind: .role,
      subtitle: "Review on another machine", insertText: "@role:role-reviewer@remote", roleName: "Reviewer"))
    return MentionCatalog(items: items, truncated: false, incomplete: false)
  }
}
