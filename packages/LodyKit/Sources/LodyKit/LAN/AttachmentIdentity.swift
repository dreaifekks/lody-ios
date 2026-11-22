import Foundation

/// Stable UI/cache namespace. Runtime owners, generations and addresses are
/// deliberately absent: recovering the transport does not change the account.
public enum AttachmentIdentity {
  public static func key(userId: String, workspaceId: String, lanId: String?) -> String {
    let mode = lanId == nil ? "cloud" : "lan"
    let fields = ["attachments-v1", userId, mode, lanId ?? "", workspaceId]
    return String(decoding: try! JSONEncoder().encode(fields), as: UTF8.self)
  }
}

extension AuthSession {
  /// The caller supplies its catalog/page workspace, never runtime.workspace.
  public func attachmentIdentity(workspace: String) -> String? {
    guard let account = snapshot.account, !account.user.id.isEmpty, !workspace.isEmpty,
      account.workspaces.contains(where: { $0.id == workspace }) else { return nil }
    return AttachmentIdentity.key(userId: account.user.id, workspaceId: workspace, lanId: account.lan?.id)
  }
}
