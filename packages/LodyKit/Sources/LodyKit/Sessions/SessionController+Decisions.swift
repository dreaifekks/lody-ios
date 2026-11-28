import LodyCore
import UIKit

extension SessionController {
  func wireDecisionEvents() {
    planDecision.changed = { [weak self] in self?.renderComposer() }
    errorRetry.changed = { [weak self] in self?.renderComposer() }
    chat.onPlanDecision = { [weak self] body in
      guard let self else { return }
      let (entryId, itemId) = (body["entryId"] as? String ?? "", body["itemId"] as? String ?? "")
      let action = body["action"] as? String ?? "", id = body["id"] as? String ?? ""
      let target = feed?.state.transcript.proposedPlan, enabled = decisionsEnabled.plan
      let choice = SessionDecision.planExecutionChoice(composerModel.active, composerModel.capability)
      Task {
        await self.planDecision.decide(
          target: target, enabled: enabled, entryId: entryId, itemId: itemId, action: action, id: id
        ) { [weak self] _, id in
          try await self?.turn(id: id, text: String(localized: "native.chat.proposedPlan.executePrompt", bundle: .lody), choice: choice) ?? ""
        }
      }
    }
    chat.onProposalDecision = { [weak self] row, accept in self?.decideProposal(row, accept: accept) }
    chat.onProposalInspect = { [weak self] row in self?.inspectProposal(row) }
    chat.onAgentSignIn = { [weak self] in self?.signInAgent() }
    chat.onProposalOpenSchedule = { [weak self] id in
      guard let self else { return }
      // Schedules opens that schedule's editor once its live list names it.
      let page = SchedulesController()
      page.opening = id
      _ = LodyShell.shared.pushNative(page, title: String(localized: "native.chat.proposal.schedules", bundle: .lody), from: self)
    }
    chat.onEditMessage = { [weak self] body in
      guard let self, let entryId = body["entryId"] as? String, !entryId.isEmpty, entryId == chat.editableMessageID else { return }
      let editor = EditMessageController(sessionId: sessionId, entryId: entryId)
      editor.quotesSupported = { [weak self] in self?.supportsMessageQuotes == true }
      editor.onFinish = { [weak self] id in self?.chat.editedMessageID = id }
      LodyShell.shared.presentNative(editor, title: String(localized: "chat.edit.title", bundle: .lody), dismissible: false, style: "fullScreen")
    }
    chat.onErrorRetry = { [weak self] body in
      guard let self else { return }
      let target = feed?.state.transcript.retryableError, enabled = decisionsEnabled.retry
      let choice = composerModel.active
      Task {
        await self.errorRetry.decide(
          target: target, enabled: enabled, entryId: body["entryId"] as? String ?? "", itemId: body["itemId"] as? String ?? "",
          id: body["id"] as? String ?? ""
        ) { [weak self] target, id in
          let retry = SessionDecision.retryTurn(reason: target.detail)
          return try await self?.turn(id: id, text: retry.text, choice: choice, deliveryKind: retry.deliveryKind) ?? ""
        }
      }
    }
  }

  /// Save / create or dismiss an Agent's proposal (`decideProposal`); never retried on its own.
  /// The transcript carries the outcome once recorded, so success only clears the pending state.
  func decideProposal(_ row: ChatRow, accept: Bool) {
    let (entryId, itemId) = (row.entryID, row.itemID)
    let workspaceId = source.state.workspaceId, sessionId = self.sessionId
    chat.proposalInspectFailures.remove(entryId + "/" + itemId)
    chat.setProposalState(entryId: entryId, itemId: itemId, ChatProposalState(pending: true))
    Task { [weak self] in
      var failure: String?
      do {
        guard let runtime = DataRuntime.current, runtime.sessionId == sessionId, runtime.workspace == workspaceId else {
          throw OutboxError.scopeExpired
        }
        _ = try await runtime.perform(RuntimeContract.Calls.DecideProposal.self, .init(
          workspaceId: workspaceId, sessionId: sessionId, entryId: entryId, itemId: itemId,
          decision: accept ? .accept : .dismiss
        ))
      } catch {
        failure = Self.proposalFailure(error)
      }
      guard let self, self.sessionId == sessionId else { return }
      self.chat.setProposalState(entryId: entryId, itemId: itemId, failure.map { ChatProposalState(message: $0) })
      // A refused edit may be refused because its schedule moved: read it again.
      if failure != nil, row.proposal?.isEdit == true { self.chat.setProposalInspection(entryId: entryId, itemId: itemId, nil) }
    }
  }

  /// Web's `AcpAuthenticationPanel` under an `acp_auth_required` failure: the same machine
  /// authentication flow Settings › Agents uses, for this session's computer and Agent config.
  func signInAgent() {
    let state = source.state
    guard chat.agentSignInAvailable, let session = state.catalog.session(sessionId),
      let config = session.agentConfigId, !config.isEmpty else { return }
    let target = ProviderTarget(workspaceId: state.workspaceId, machineId: session.machineId, id: config)
    let page = AgentProviderAuthController(target: target, methods: [], scope: .live(["userId": state.userId, "workspaceId": state.workspaceId]),
      service: .cloud)
    LodyShell.shared.presentNative(page, title: String(localized: "native.chat.error.signIn", bundle: .lody), detents: [1])
  }

  /// Web `ScheduleEditProposalNotice` follows the live schedule; the card reads it once per
  /// appearance (`inspectProposal`) and again after a refused decision.
  func inspectProposal(_ row: ChatRow) {
    let (entryId, itemId) = (row.entryID, row.itemID)
    let workspaceId = source.state.workspaceId, sessionId = self.sessionId
    Task { [weak self] in
      var result: RuntimeContract.InspectProposalResult?
      var failure: String?
      do {
        guard let runtime = DataRuntime.current, runtime.sessionId == sessionId, runtime.workspace == workspaceId else {
          throw OutboxError.scopeExpired
        }
        result = try await runtime.perform(RuntimeContract.Calls.InspectProposal.self, .init(
          workspaceId: workspaceId, sessionId: sessionId, entryId: entryId, itemId: itemId
        ))
      } catch {
        failure = Self.proposalFailure(error)
      }
      guard let self, self.sessionId == sessionId else { return }
      let key = entryId + "/" + itemId
      if let result {
        if self.chat.proposalInspectFailures.remove(key) != nil { self.chat.setProposalState(entryId: entryId, itemId: itemId, nil) }
        self.chat.setProposalInspection(entryId: entryId, itemId: itemId, result)
      } else if let failure {
        self.chat.proposalInspectFailures.insert(key)
        self.chat.setProposalState(entryId: entryId, itemId: itemId, ChatProposalState(message: failure))
      }
    }
  }

  static let proposalCodes = [
    "proposal_not_requester", "proposal_unavailable", "role_duplicate", "role_read_only", "role_forbidden",
    "role_target_unavailable", "schedule_target_unavailable", "schedule_not_owner", "schedule_machine_unsupported",
    "schedule_trigger_invalid", "schedule_edit_stale",
  ]

  static func proposalFailure(_ error: Error) -> String {
    let description = error.localizedDescription
    let code = proposalCodes.first { description.contains($0) } ?? "failed"
    return String(localized: String.LocalizationValue("native.chat.proposal.error." + code), bundle: .lody)
  }

  var decisionsEnabled: (plan: Bool, retry: Bool) {
    guard let session = source.state.catalog.session(sessionId), let feed = feed?.state, let sender else { return (false, false) }
    let state = source.state
    let control = control.state(
      session: session, transcript: feed.transcript, live: feed.status == "live", overflow: feed.overflow,
      steerable: composerModel.steerable
    )
    let billable = feed.status == "live" ? feed.billableTurnCount : nil
    let ready = feed.status == "live" && state.connected && !state.loading && sender.canSend && !sender.sending
      && !sender.awaitingReply && !control.running && !control.controlling && !feed.overflow && !session.archived
      && !state.userId.isEmpty
    let retry = ready
    let plan = ready && session.agentType == "codex" && session.status == "idle" && !errorRetry.pending
      && !SessionActions.isDeleting(state.workspaceId, sessionId) && !SessionQuota.locked(count: billable, tier: composerModel.tier)
    return (plan, retry)
  }

  func renderDecisions(_ feed: SessionFeedState) {
    let live = feed.status == "live"
    if live, !proposalsLive {
      chat.proposalInspectRequested = chat.proposalInspectRequested.filter { chat.proposalInspections[$0] != nil }
    }
    proposalsLive = live
    let enabled = decisionsEnabled
    let plan = planDecision.state(target: feed.transcript.proposedPlan, enabled: enabled.plan, answered: feed.transcript.answered)
    let retry = errorRetry.state(target: feed.transcript.retryableError, enabled: enabled.retry, answered: feed.transcript.answered)
    apply("plan", Self.json(plan), chat.setPlanDecisionState)
    apply("retry", Self.json(retry), chat.setErrorRetryState)
  }

  func renderEditable(_ feed: SessionFeedState, enabled: Bool) {
    let latest = feed.transcript.editableUserId ?? ""
    let check = enabled && !latest.isEmpty ? "\(feed.transcript.editEligibility):\(self.feed?.generation ?? 0)" : ""
    if check != editCheck {
      editCheck = check
      editable = ""
      if !check.isEmpty { readEditable(latest, check: check) }
    }
    let value = enabled && editable == latest ? editable : ""
    if chat.editableMessageID != value { chat.editableMessageID = value }
  }

  private func readEditable(_ id: String, check: String) {
    let payload = Self.json(["action": "read", "sessionId": sessionId, "expectedUserTurnId": id])
    Task { [weak self] in
      guard let self, let result = try? await environment.readEdit(payload) else { return }
      let reply = try? JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any]
      guard editCheck == check, reply?["state"] as? String == "ready" else { return }
      editable = id
      renderComposer()
    }
  }

  private func turn(id: String, text: String, choice: ModelChoice, deliveryKind: String? = nil) async throws -> String {
    guard let session = source.state.catalog.session(sessionId) else { throw OutboxError.scopeExpired }
    let capability = composerModel.capability
    var payload: [String: Any] = [
      "id": id, "sessionId": sessionId, "machineId": session.machineId, "userId": source.state.userId,
      "cliType": session.cliType, "agentType": session.agentType, "text": text, "attachments": [Any](),
      "queue": false, "guide": false,
    ]
    payload["deliveryKind"] = deliveryKind
    payload["resume"] = session.resume
    payload["modeId"] = choice.modeId
    payload["reasoningEffortConfigId"] = capability?.reasoningEffortConfigId
    for (key, value) in [("modelId", choice.modelId), ("reasoningEffort", choice.effort)] {
      if let value { payload[key] = value } else if capability != nil { payload[key] = NSNull() }
    }
    if let values = choice.configOptionValues {
      payload["configOptionValues"] = values.mapValues { value -> Any in
        switch value {
        case .string(let text): text
        case .bool(let flag): flag
        }
      }
    }
    return try await environment.turn(Self.json(payload))
  }
}
