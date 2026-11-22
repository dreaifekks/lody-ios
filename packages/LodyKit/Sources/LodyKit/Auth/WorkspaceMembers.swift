import LodyCore
import Foundation

/// Display-only member cache. Each request is fenced by account, workspace and store generation.
@MainActor enum WorkspaceMembers {
  static func key(userId: String, workspaceId: String) -> String {
    "workspace-members:v1:" + CreateJSON.encode([userId, workspaceId])
  }

  /// Whether the signed-in user is a read-only member of the workspace, as last read from the member
  /// list (cached or fresh); nil until one has been read. The data runtime passes it to `start`, and
  /// Home withdraws status, pin and section actions with it.
  static func readOnly(userId: String, workspaceId: String) -> Bool? {
    roles[key(userId: userId, workspaceId: workspaceId)]
  }

  private static var roles: [String: Bool] = [:]

  private static func learn(_ members: [String: WorkspaceMember], userId: String, workspaceId: String) {
    guard let me = members[userId], me.role != nil else { return }
    let scope = key(userId: userId, workspaceId: workspaceId)
    guard roles[scope] != me.readOnly else { return }
    roles[scope] = me.readOnly
    NotificationCenter.default.post(name: .lodyWorkspaceRoleDidChange, object: nil)
  }

  static func learnFixtureViewer() {
    guard LodyUIVerify.status else { return }
    learn(["ui-home": WorkspaceMember(id: "ui-home", name: "UI fixture", image: nil, role: "viewer")],
      userId: "ui-home", workspaceId: "ui-home")
  }

  static func load(userId: String, workspaceId: String, receive: @escaping @MainActor ([String: WorkspaceMember]) -> Void) async {
    let generation = LocalStore.shared.generation
    func ownsScope() -> Bool {
      let account = AuthSession.shared.snapshot.account
      return !Task.isCancelled && LocalStore.shared.generation == generation
        && account?.user.id == userId && account?.workspaces.contains { $0.id == workspaceId } == true
    }
    guard ownsScope() else { return }
    let cacheKey = key(userId: userId, workspaceId: workspaceId)
    let raw: String? = await withCheckedContinuation { continuation in
      LocalStore.queue.async { continuation.resume(returning: (try? LocalStore.shared.read(cacheKey)) ?? nil) }
    }
    guard ownsScope() else { return }
    if let raw, let cached = CreateJSON.decode([WorkspaceMember].self, raw) {
      let members = Dictionary(cached.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
      learn(members, userId: userId, workspaceId: workspaceId)
      receive(members)
    }
    do {
      guard let token = try AuthKeychain.read(), !token.isEmpty else { return }
      let fresh = try await AuthAPI().members(token: token, workspaceId: workspaceId)
      guard ownsScope(), try AuthKeychain.read() == token else { return }
      let members = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
      learn(members, userId: userId, workspaceId: workspaceId)
      receive(members)
      let value = CreateJSON.encode(fresh)
      LocalStore.queue.async { try? LocalStore.shared.write(cacheKey, value, generation: generation) }
    } catch { /* Keep cached identities when the refresh fails. */ }
  }
}

extension Notification.Name {
  static let lodyWorkspaceRoleDidChange = Notification.Name("LodyWorkspaceRoleDidChange")
}
