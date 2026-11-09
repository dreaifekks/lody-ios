import Foundation
import LodyCore

extension DataRuntime {
  /// Scope every async transfer to the runtime/account that started it.
  public var attachmentScope: String {
    let account = AuthSession.shared.snapshot.account
    return "\(owner):\(userId):\(workspace ?? ""):\(generation):\(account?.user.id ?? ""):\(account?.lan?.id ?? "cloud")"
  }

  private var attachmentAccountMatches: Bool {
    let account = AuthSession.shared.snapshot.account
    return account?.user.id == userId && account?.lan?.id == lan?.id
  }

  public func lanFileMachine(sessionId: String? = nil, machineId: String?) async throws -> (LanInvite, LanSessionFiles.Machine) {
    guard attachmentAccountMatches, let lan, let workspace else {
      throw SessionAttachments.error(String(localized: "native.runtime.notConnected", bundle: .lodyData))
    }
    let scope = attachmentScope
    let result = try await perform(RuntimeContract.Calls.LanFileTarget.self, .init(sessionId: sessionId, machineId: machineId))
    try Task.checkCancellation()
    guard attachmentScope == scope, self.workspace == workspace else { throw CancellationError() }
    let data = try JSONEncoder().encode(result)
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let machine = LanSessionFiles.machine(value) else {
      throw SessionAttachments.error(String(localized: "native.attachment.error.invalid", bundle: .lodyData))
    }
    return (lan, machine)
  }

  /// Uploads bytes to the session's owning LAN member, or Cloud for a Cloud account.
  /// Used for ordinary turns and the reserved new session's first turn alike.
  func uploadAttachments(_ attachments: [[String: Any]], session: String, machineId: String?,
    onProgress: @escaping SessionAttachments.ProgressHandler) async throws -> [[String: Any]] {
    guard attachmentAccountMatches, let workspace else { throw CancellationError() }
    let scope = attachmentScope
    let input = AttachmentTransferPayload(items: attachments)
    let task: Task<AttachmentTransferPayload, Error>
    if isLAN {
      let (invite, machine) = try await lanFileMachine(sessionId: session, machineId: machineId)
      task = Task.detached {
        AttachmentTransferPayload(items: try await LanSessionFiles.upload(input.items, invite: invite, machine: machine,
          session: session, onProgress: onProgress))
      }
    } else {
      task = Task.detached {
        AttachmentTransferPayload(items: try await SessionAttachments.upload(input.items, workspace: workspace,
          session: session, onProgress: onProgress))
      }
    }
    let result = try await withTaskCancellationHandler {
      try await task.value
    } onCancel: { task.cancel() }
    try Task.checkCancellation()
    guard attachmentScope == scope else { throw CancellationError() }
    let blocks = result.items
    return blocks
  }

  public func downloadAttachment(_ file: ChatMessageAttachment, workspace: String, session: String, directory: URL) async throws -> URL {
    guard attachmentAccountMatches, self.workspace == workspace else { throw CancellationError() }
    let scope = attachmentScope
    let url: URL
    if file.transport == "local" {
      let (invite, machine) = try await lanFileMachine(machineId: file.machineId)
      url = try await LanSessionFiles.download(invite: invite, machine: machine, session: file.storageSessionId ?? session,
        fileId: file.id, fileName: file.fileName, sizeBytes: file.sizeBytes, sha256: file.sha256, directory: directory)
    } else {
      // A LAN never routes unknown/Cloud references through the Cloud blob service.
      guard !isLAN else { throw SessionAttachments.error(String(localized: "native.attachment.error.invalid", bundle: .lodyData)) }
      url = try await SessionAttachments.download(workspace: workspace, session: file.storageSessionId ?? session,
        fileId: file.id, fileName: file.fileName, sizeBytes: file.sizeBytes, directory: directory, image: file.image != nil)
    }
    guard attachmentScope == scope, !Task.isCancelled else {
      try? FileManager.default.removeItem(at: url)
      throw CancellationError()
    }
    return url
  }
}

/// Immutable transfer ownership across the detached native I/O task. Wire blocks
/// contain JSON values only and are never mutated concurrently.
private struct AttachmentTransferPayload: @unchecked Sendable {
  let items: [[String: Any]]
}
