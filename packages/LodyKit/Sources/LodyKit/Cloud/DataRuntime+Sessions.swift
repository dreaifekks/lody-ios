import LodyCore
import Foundation

extension DataRuntime {
  func confirmSessionCreation(_ payload: String, sink: ReplySink) {
    guard inWorkspace(payload, sink: sink) else { return }
    callJSON(RuntimeContract.Calls.ConfirmSessionCreation.self, payload: payload, sink: sink)
  }
  func confirmSessionTurn(_ payload: String, sink: ReplySink) {
    guard workspace != nil else { fail(sink, "not_ready", "Session unavailable"); return }
    callJSON(RuntimeContract.Calls.ConfirmSessionTurn.self, payload: payload, sink: sink)
  }

  /// The current workspace's plan for a typed call that the free-plan quota gates (a Tab);
  /// nil when unavailable, which fails open like the other writes.
  func billingEntitlement() async -> RuntimeContract.BillingEntitlement? {
    guard let workspace else { return nil }
    guard let value = await billing.entitlement(workspace: workspace, user: userId),
          let tier = (value["effectivePlanTier"] as? String).flatMap(RuntimeContract.BillingEntitlementEffectivePlanTier.init(rawValue:)),
          let pending = value["checkoutPending"] as? Bool else { return nil }
    return .init(effectivePlanTier: tier, checkoutPending: pending)
  }
  func releaseReserve(_ id: String) {
    reservedSessions.removeAll { $0 == id }
    dispatch(RuntimeContract.Calls.ReleaseReserve.self, .init(sessionId: id))
  }
  func createSession(_ payload: String, sink: ReplySink) {
    guard let workspace else { fail(sink, "not_ready", String(localized: "native.runtime.sessionNotSynced", bundle: .lody)); return }
    let user = userId, generation = self.generation, scope = attachmentScope
    Task { @MainActor in
      let entitlement = await billing.entitlement(workspace: workspace, user: user)
      guard self.generation == generation, self.workspace == workspace, self.userId == user, self.attachmentScope == scope else {
        sink.resolve(#"{"state":"rejected"}"#); return
      }
      guard self.inWorkspace(payload, sink: sink) else { return }
      self.callJSON(RuntimeContract.Calls.CreateSession.self, payload: payload,
        inject: ["billingEntitlement": entitlement ?? NSNull(), "preferRoost": LodyPreferences.roostHistoryEnabled], sink: sink)
    }
  }
  func controlTurn(_ payload: String, sink: ReplySink) {
    guard inOpenSession(payload, sink: sink) else { return }
    callJSON(RuntimeContract.Calls.ControlTurn.self, payload: payload, sink: sink)
  }
  func prepareSessionEdit(_ payload: String, sink: ReplySink) {
    let generation = self.generation, scope = attachmentScope
    guard let workspace, let session = sessionId else { fail(sink, "not_ready", "Session unavailable"); return }
    Task { @MainActor in
      do {
        let result: String = try await withCheckedThrowingContinuation {
          self.dispatchTurn(payload, sink: .continuation($0), billing: nil, edit: true)
        }
        guard var draft = try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any],
              draft["state"] as? String == "ready" else { sink.resolve(result); return }
        var attachments: [[String: Any]] = []
        let originals = draft["attachments"] as? [[String: Any]] ?? []
        guard originals.count <= (isLAN ? 8 : 16) else { throw SessionAttachments.error(String(localized: "native.attachment.error.limit", bundle: .lody)) }
        let downloads = AttachmentDownloadBatch()
        // ponytail: download at most 16 originals for the shared local-file composer; use lazy remote previews if large attachments make editing slow.
        for block in originals {
          guard let editID = block["editId"] as? String else {
            throw SessionAttachments.error(String(localized: "native.attachment.error.invalid", bundle: .lody))
          }
          let blockType = block["type"] as? String ?? ""
          let directory = downloads.makeDirectory()
          var file: ChatMessageAttachment
          if blockType == "local_attachment" {
            guard let machineId = block["machineId"] as? String, !machineId.isEmpty,
                  let path = block["path"] as? String, !path.isEmpty else {
              throw SessionAttachments.error(String(localized: "native.attachment.error.invalid", bundle: .lody))
            }
            let name = block["fileName"] as? String ?? "file"
            file = ChatMessageAttachment(
              id: "local:\(machineId):\(path)", fileName: name,
              transport: "local_attachment",
              sizeBytes: block["sizeBytes"] as? Int, mimeType: block["mimeType"] as? String,
              machineId: machineId, path: path, kind: block["kind"] as? String
            )
          } else {
            let image = blockType == "image"
            let rawId = image ? (block["imageId"] as? String ?? block["localImageId"] as? String) : (block["fileId"] as? String)
            guard let id = rawId, !id.isEmpty else {
              throw SessionAttachments.error(String(localized: "native.attachment.error.invalid", bundle: .lody))
            }
            let name = block["fileName"] as? String ?? (image ? "image.jpg" : "file")
            let local = block["transport"] as? String == "local"
            let chatImage: ChatImage? = image ? ChatImage(
              id: id, fileName: name, storageSessionId: block["storageSessionId"] as? String,
              width: nil, height: nil, transport: block["transport"] as? String,
              machineId: block["machineId"] as? String, localImageId: block["localImageId"] as? String,
              sha256: block["sha256"] as? String, sizeBytes: block["sizeBytes"] as? Int,
              mimeType: block["mimeType"] as? String
            ) : nil
            file = ChatMessageAttachment(id: id, fileName: name, image: chatImage,
              storageSessionId: block["storageSessionId"] as? String, transport: block["transport"] as? String,
              sizeBytes: block["sizeBytes"] as? Int, mimeType: block["mimeType"] as? String,
              machineId: block["machineId"] as? String, sha256: block["sha256"] as? String)
            if local { file = file.shownAsImage }
          }
          let url = try await self.downloadAttachment(file, workspace: workspace, session: session, directory: directory)
          guard self.generation == generation, self.sessionId == session, self.attachmentScope == scope else { throw CancellationError() }
          let kind = (file.image != nil || file.kind == "image") ? "image" : "file"
          attachments.append(["id": editID, "name": file.fileName, "uri": url.absoluteString, "kind": kind])
        }
        guard self.generation == generation, self.sessionId == session, self.attachmentScope == scope else { throw CancellationError() }
        draft["attachments"] = attachments
        let encoded = String(data: try JSONSerialization.data(withJSONObject: draft), encoding: .utf8)!
        downloads.handOff()
        sink.resolve(encoded)
      } catch { fail(sink, "edit_prepare_failed", error.localizedDescription) }
    }
  }
  func sendTurn(_ payload: String, sink: ReplySink, edit: Bool = false) {
    guard let workspace else { dispatchTurn(payload, sink: sink, billing: nil, edit: edit); return }
    let user = userId, generation = self.generation, scope = attachmentScope
    Task { @MainActor in
      let entitlement = await billing.entitlement(workspace: workspace, user: user)
      guard self.generation == generation, self.workspace == workspace, self.userId == user, self.attachmentScope == scope else {
        sink.resolve(notSentJSON("native.runtime.connectionSwitched")); return
      }
      let hasAttachments = payload.data(using: .utf8)
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        .flatMap { $0["attachments"] as? [[String: Any]] }
        .map { !$0.isEmpty } ?? false
      if hasAttachments, let quota = await turnQuota(payload, billing: entitlement) {
        sink.resolve(quota); return
      }
      sendTurnWithBilling(payload, sink: sink, billing: entitlement, edit: edit)
    }
  }
  private func turnQuota(_ payload: String, billing: [String: Any]?) async -> String? {
    guard health.ready, contractReady, let channel, workspace != nil, payload.utf8.count <= 128 * 1024,
          let target = Self.scope(payload)?["sessionId"] as? String, !target.isEmpty else {
      return notSentJSON("native.runtime.sessionNotSyncedRetry")
    }
    let entitlement = billing.flatMap { try? RuntimeJSON.decode(RuntimeContract.BillingEntitlement.self, from: $0) }
    let params = RuntimeContract.CheckTurnQuotaParams(sessionId: target, billingEntitlement: entitlement)
    guard case .notSent(let value)? = try? await channel.call(RuntimeContract.Calls.CheckTurnQuota.self, params),
          let data = try? JSONEncoder().encode(RuntimeContract.CheckTurnQuotaResult.notSent(value)) else { return nil }
    return String(decoding: data, as: UTF8.self)
  }
  private func sendTurnWithBilling(_ payload: String, sink: ReplySink, billing: [String: Any]?, edit: Bool) {
    guard let data = payload.data(using: .utf8), data.count <= 128 * 1024,
          var args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let attachments = args.removeValue(forKey: "attachments") as? [[String: Any]], !attachments.isEmpty else {
      dispatchTurn(payload, sink: sink, billing: billing, edit: edit); return
    }
    guard health.ready, let workspace,
          let target = args["sessionId"] as? String, !target.isEmpty,
          attachmentTasks[target] == nil else {
      sink.resolve(notSentJSON("native.runtime.sessionNotReady")); return
    }
    if !backgrounded {
      args["backgroundTaskId"] = SessionBackgroundTasks.shared.begin(owner: owner)
    }
    let backgroundTaskId = args["backgroundTaskId"] as? String
    let generation = self.generation, transferScope = attachmentScope
    let sendID = args["id"] as? String ?? ""
    let attempt = UUID()
    let billingTier = billing?["effectivePlanTier"] as? String
    let checkoutPending = billing?["checkoutPending"] as? Bool
    attachmentAttempts[target] = attempt
    attachmentTasks[target] = Task { @MainActor [weak self] in
      do {
        guard let self, self.attachmentScope == transferScope, self.attachmentAttempts[target] == attempt else { throw CancellationError() }
        args["attachmentBlocks"] = try await self.uploadAttachments(attachments, session: target, machineId: args["machineId"] as? String) { [weak self] attachmentID, phase, percent in
          DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation, self.workspace == workspace,
              self.attachmentScope == transferScope, self.attachmentAttempts[target] == attempt, self.attachmentTasks[target] != nil else { return }
            var event: [String: Any] = ["sessionId": target, "sendId": sendID,
              "attachmentId": attachmentID, "phase": phase]
            if let percent { event["percent"] = percent }
            NotificationCenter.default.post(name: .lodyAttachmentUploadProgress, object: nil, userInfo: event)
          }
        }
        try Task.checkCancellation()
        let prepared = String(data: try JSONSerialization.data(withJSONObject: args), encoding: .utf8)!
        await MainActor.run { [weak self] in
          guard let self, self.generation == generation, self.workspace == workspace,
            self.attachmentScope == transferScope, self.attachmentAttempts[target] == attempt, !Task.isCancelled else {
            if let backgroundTaskId { SessionBackgroundTasks.shared.finish(backgroundTaskId, success: false) }
            sink.resolve(notSentJSON("native.runtime.connectionSwitched")); return
          }
          self.attachmentTasks[target] = nil
          self.attachmentAttempts[target] = nil
          var projection: [String: Any]?
          if let billingTier, let checkoutPending {
            projection = ["effectivePlanTier": billingTier, "checkoutPending": checkoutPending]
          }
          self.dispatchTurn(prepared, sink: sink, billing: projection, edit: edit)
        }
      } catch {
        let result = (try? JSONSerialization.data(withJSONObject: ["state": "not_sent", "reason": error.localizedDescription])) ?? Data()
        await MainActor.run { [weak self] in
          if let self, self.generation == generation, self.attachmentAttempts[target] == attempt {
            self.attachmentTasks[target] = nil
            self.attachmentAttempts[target] = nil
          }
          if let backgroundTaskId { SessionBackgroundTasks.shared.finish(backgroundTaskId, success: false) }
          sink.resolve(String(data: result, encoding: .utf8)!)
        }
      }
    }
  }
  func dispatchTurn(_ payload: String, sink: ReplySink, billing: [String: Any]?, edit: Bool) {
    let args = payload.data(using: .utf8).flatMap { data in
      data.count <= 128 * 1024 ? (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] : nil
    }
    let target = args?["sessionId"] as? String
    var task = args?["backgroundTaskId"] as? String
    let allowed = edit ? target == sessionId : workspace != nil && target?.isEmpty == false
    guard health.ready, contractReady, channel != nil, let args, allowed else {
      if let task { SessionBackgroundTasks.shared.finish(task, success: false) }
      if edit { fail(sink, "not_ready", String(localized: "native.runtime.sessionNotSynced", bundle: .lody)) }
      else { sink.resolve(notSentJSON("native.runtime.sessionNotSyncedRetry")) }
      return
    }
    var inject: [String: Any] = ["billingEntitlement": billing ?? NSNull()]
    if edit { inject["userId"] = userId }
    if task == nil, !edit || args["action"] as? String == "send", !backgrounded {
      task = SessionBackgroundTasks.shared.begin(owner: owner)
      if let task { inject["backgroundTaskId"] = task }
    }
    if edit {
      turnCall(RuntimeContract.Calls.EditSession.self, payload, inject: inject, sink: sink, task: task)
      return
    }
    // Clearable on the wire: null clears (an explicit None Role, the agent's default model).
    for key in ["modelId", "reasoningEffort", "agentRoleId"] {
      if let value = args[key] { inject[key] = ["value": value] }
    }
    let text = args["text"] as? String ?? ""
    // Catalog expansion precedes the durable send and has its own bounded read.
    let expands = text.contains("$") || text.contains("@session:") || text.contains("@role:")
    turnCall(RuntimeContract.Calls.SendTurn.self, payload, inject: inject, sink: sink, task: task, timeout: expands ? 90 : nil)
  }
  private func turnCall<C: RuntimeCall>(_ call: C.Type, _ payload: String, inject: [String: Any], sink: ReplySink,
    task: String?, timeout: Double? = nil) where C.Params: Decodable, C.Result: Encodable {
    let release: @MainActor (Bool) -> Void = { success in
      if let task { SessionBackgroundTasks.shared.finish(task, success: success) }
    }
    guard let params = decodeParams(C.self, payload: payload, inject: inject, sink: sink) else { release(false); return }
    self.call(C.self, params, sink: sink, timeout: timeout, failed: { release(false) }) { result in
      let data = try? JSONEncoder().encode(result)
      let reply = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
      if reply?["state"] as? String != "accepted" && reply?["awaitingGuide"] as? Bool != true {
        release(reply?["state"] as? String == "queued")
      }
      return data.map { String(decoding: $0, as: UTF8.self) }
    }
  }
}

private func notSentJSON(_ key: String) -> String {
  let waiting = ["native.runtime.sessionNotSyncedRetry", "native.runtime.sessionNotReady", "native.runtime.connectionSwitched"].contains(key)
  let payload: [String: Any]
  if waiting { payload = ["state": "not_sent", "reason": "session_not_ready", "retryable": true] }
  else { payload = ["state": "not_sent", "reason": String(localized: String.LocalizationValue(key), bundle: .lody)] }
  guard let data = try? JSONSerialization.data(withJSONObject: payload),
        let json = String(data: data, encoding: .utf8) else { return #"{"state":"not_sent"}"# }
  return json
}
