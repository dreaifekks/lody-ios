import LodyCore

/// Agent Roles in an existing conversation, after web's session composer
/// (`selectSessionAgentRoles`, `use-session-agent-role.ts`). The agent never changes: a Role is
/// offered only when it binds the conversation's own computer AND Agent Config, picking one
/// applies just the values it pins, and a turn runs as it only while those values still hold.
enum SessionRoles {
  /// What a turn says about its Role (`SendTurnParams.agentRoleId`).
  enum Send: Equatable {
    /// Omit: the runtime inherits the latest turn's Role (and detaches it if the config moved).
    case inherit
    /// Explicit None: the conversation no longer runs as a Role.
    case none
    case role(String)
  }

  /// Roles bound to this conversation's computer and Agent Config, sorted by name. Unavailable
  /// ones stay listed with their reason; `online` is the agent configs online on that computer.
  static func items(
    roles: [RuntimeContract.AgentRoleItem], machineId: String, agentConfigId: String?, online: Set<String>
  ) -> [CreateRoleItem] {
    guard let agentConfigId, !agentConfigId.isEmpty, !machineId.isEmpty else { return [] }
    return roles.compactMap { role -> CreateRoleItem? in
      guard let target = role.targets.first(where: { $0.machineId == machineId }),
            target.agentConfigId == agentConfigId else { return nil }
      var reason: String?
      switch target.state {
      case .machineUnavailable: reason = "create.role.unavailable.machine"
      case .agentUnavailable: reason = "create.role.unavailable.agent"
      case .configured: if !online.contains(agentConfigId) { reason = "create.role.unavailable.offline" }
      }
      return CreateRoleItem(role: role, target: target, unavailable: reason)
    }
    .sorted { lhs, rhs in
      let order = lhs.role.name.localizedCompare(rhs.role.name)
      return order == .orderedSame ? lhs.role.id < rhs.role.id : order == .orderedAscending
    }
  }

  /// The Role the composer IS: the one picked here (`.some(nil)` is an explicit None), else the
  /// one the latest turn ran as, while it can run and every value it pins is what will run.
  static func active(
    _ items: [CreateRoleItem], picked: String??, durable: String??, choice: ModelChoice,
    effortId: String?, modelOptionId: String? = nil, cliType: String? = nil
  ) -> CreateRoleItem? {
    let id: String? = picked ?? durable ?? nil
    guard let id, let item = items.first(where: { $0.role.id == id }), item.unavailable == nil else { return nil }
    return CreateSessionForm.applied(
      item.target.runConfig, to: choice, effortId: effortId,
      modelOptionId: modelOptionId, cliType: cliType
    ) ? item : nil
  }

  /// Picking a Role sets the values it pins that this agent offers; everything else stays the
  /// conversation's own (web applies pins through the composer's ordinary callbacks).
  static func choice(applying item: CreateRoleItem, to current: ModelChoice, capability: Capability?) -> ModelChoice {
    let modelKey = CreateLogic.modelOptionId(capability) ?? "model"
    let preliminary = CreateSessionForm.choice(
      item.target.runConfig,
      effortId: capability?.reasoningEffortConfigId,
      modelOptionId: modelKey
    )
    let previousModel = CreateLogic.selectedModelId(capability, current, modelOptionId: modelKey)
    let effortKey = CreateLogic.effortOptionId(capability, modelId: preliminary.modelId ?? previousModel)
    let pinned = CreateSessionForm.choice(
      item.target.runConfig,
      effortId: effortKey,
      modelOptionId: modelKey
    )
    var next = current
    if let model = pinned.modelId, capability.map({ $0.models.contains { $0.id == model } }) ?? true {
      next.modelId = model
      next.configOptionValues?.removeValue(forKey: modelKey)
      if modelKey != "model" { next.configOptionValues?.removeValue(forKey: "model") }
      if pinned.effort == nil, next.modelId != previousModel {
        next.effort = nil
        for stale in [effortKey, "thought_level", "reasoning_effort", "effort"].compactMap({ $0 }) {
          next.configOptionValues?.removeValue(forKey: stale)
        }
      }
    }
    if let mode = pinned.modeId, capability.map({ $0.modes.contains { $0.id == mode } }) ?? true { next.modeId = mode }
    if let effort = pinned.effort {
      next.effort = effort
      for stale in [effortKey, "thought_level", "reasoning_effort", "effort"].compactMap({ $0 }) {
        next.configOptionValues?.removeValue(forKey: stale)
      }
    }
    if let options = pinned.configOptionValues, !options.isEmpty {
      let configDriven = capability?.cliType == "registry" || capability?.cliType == "custom"
      let permIds = CreateLogic.permissionOptionIds(capability)
      if configDriven, options.keys.contains(where: { permIds.contains($0) }) {
        next.modeId = nil
        for stale in permIds where options[stale] == nil {
          next.configOptionValues?.removeValue(forKey: stale)
        }
      }
      next.configOptionValues = (next.configOptionValues ?? [:]).merging(options) { _, pin in pin }
    }
    if next.configOptionValues?.isEmpty == true { next.configOptionValues = nil }
    return next
  }

  /// What the next turn carries. Until the Role list has loaded nothing is claimed either way.
  static func send(loaded: Bool, active: CreateRoleItem?, picked: String??, durable: String??) -> Send {
    if let active { return .role(active.role.id) }
    guard loaded else { return .inherit }
    if case .some(.none) = picked { return .none }
    let selected: String? = picked ?? durable ?? nil
    if selected != nil { return .none }
    if case .some(.none) = durable { return .none }
    return .inherit
  }
}
