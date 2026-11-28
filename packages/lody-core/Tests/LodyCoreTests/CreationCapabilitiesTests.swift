import XCTest
import LodyCore

final class CreationCapabilitiesTests: XCTestCase {
  func testModelControlsSurviveCacheAndFollowSelectedModel() throws {
    let wire = """
    {"machineId":"m","agentConfigId":"a","cliType":"builtin","agentType":"codex","models":[],"modes":[],
     "reasoningEfforts":{"small":[],"large":["high","max"]},"fastModes":{"small":false,"large":true},
     "configOptions":[{"id":"model","name":"Model","category":"model","type":"select","currentValue":"small","options":[{"id":"small","name":"Small"},{"id":"large","name":"Large"}]},
     {"id":"fast-mode","name":"Fast","type":"boolean","currentValue":false,"options":[]}]}
    """
    let capability = try JSONDecoder().decode(Capability.self, from: Data(wire.utf8))
    let restored = try JSONDecoder().decode(Capability.self, from: JSONEncoder().encode(capability))
    XCTAssertEqual(CreateLogic.effortsFor(restored, modelId: "large"), ["high", "max"])
    XCTAssertEqual(CreateLogic.effortsFor(restored, modelId: "small"), [])
    XCTAssertNil(CreateLogic.fastMode(restored, ModelChoice()))
    XCTAssertNil(CreateLogic.fastMode(restored, ModelChoice(modelId: "small")))
    XCTAssertEqual(CreateLogic.fastMode(restored, ModelChoice(modelId: "large"))?.enabled, false)
  }

  func testInheritedModelAndEffortResolveWithoutBecomingOverrides() throws {
    let wire = """
    {"machineId":"m","cliType":"builtin","agentType":"codex","models":[{"id":"small","name":"Small"},{"id":"large","name":"Large"}],"modes":[],
     "reasoningEfforts":{"small":[],"large":["low","high"]},
     "configOptions":[{"id":"model","name":"Model","category":"model","type":"select","currentValue":"large","options":[]},
     {"id":"thought_level","name":"Effort","category":"thought_level","type":"select","currentValue":"high","options":[{"id":"low","name":"Low"},{"id":"high","name":"High"}]}]}
    """
    let capability = try JSONDecoder().decode(Capability.self, from: Data(wire.utf8))
    XCTAssertEqual(CreateLogic.resolvedModelId(capability), "large")
    XCTAssertEqual(CreateLogic.resolvedModelId(capability, modelId: "default"), "large")
    XCTAssertEqual(CreateLogic.resolvedModelId(capability, modelId: "small"), "small")
    XCTAssertEqual(CreateLogic.resolvedEffort(capability, ModelChoice()), "high")
    XCTAssertEqual(CreateLogic.resolvedEffort(capability, ModelChoice(effort: "low")), "low")
    XCTAssertNil(CreateLogic.resolvedEffort(capability, ModelChoice(modelId: "small")))
    XCTAssertNil(CreateLogic.resolvedModelId(nil))
  }

  func testObservedModelConfigOptionsDrivePermissionReadWriteAndPersistence() throws {
    let wire = """
    {"machineId":"m1","agentConfigId":"agy","cliType":"registry","agentType":"antigravity",
     "models":[{"id":"gemini-3","name":"Gemini 3"},{"id":"gemini-4-neon","name":"Gemini 4 Neon"}],
     "modes":[{"id":"ask","name":"Ask"},{"id":"yolo","name":"YOLO"}],
     "legacyModes":[],
     "reasoningEfforts":{},
     "configOptions":[
       {"id":"model","name":"Model","category":"model","type":"select","currentValue":"gemini-3",
        "options":[{"id":"gemini-3","name":"Gemini 3"},{"id":"gemini-4-neon","name":"Gemini 4 Neon"}]},
       {"id":"interaction_mode","name":"Interaction","category":"mode","type":"select","currentValue":"code",
        "options":[{"id":"code","name":"Code"}]},
       {"id":"mode","name":"Permission","category":"mode","type":"select","currentValue":"ask",
        "options":[{"id":"ask","name":"Ask"},{"id":"yolo","name":"YOLO"}]}
     ],
     "observedModelConfigOptions":{
       "gemini-4-neon":[
         {"id":"interaction_mode","name":"Interaction","category":"mode","type":"select","currentValue":"code",
          "options":[{"id":"code","name":"Code"}]},
         {"id":"permission_mode","name":"Permission","category":"mode","type":"select","currentValue":"ask",
          "options":[{"id":"ask","name":"Ask"},{"id":"yolo","name":"YOLO"}]}
       ]
     }}
    """
    let capability = try JSONDecoder().decode(Capability.self, from: Data(wire.utf8))
    let restored = try JSONDecoder().decode(Capability.self, from: JSONEncoder().encode(capability))
    XCTAssertEqual(restored.observedModelConfigOptions?["gemini-4-neon"]?.map(\.id), ["interaction_mode", "permission_mode"])

    // Snapshot model uses `mode`.
    let baseChoice = ModelChoice(modelId: "gemini-3", configOptionValues: ["mode": .string("ask"), "permission_mode": .string("yolo")])
    let basePermission = CreateLogic.permissionMode(restored, baseChoice)
    XCTAssertEqual(basePermission?.configId, "mode")
    XCTAssertEqual(basePermission?.value, "ask")

    // Target model `gemini-4-neon` uses `permission_mode`, never shadowed by old `mode: ask`.
    let neonChoice = ModelChoice(modelId: "gemini-4-neon", configOptionValues: ["mode": .string("ask"), "permission_mode": .string("yolo")])
    let neonPermission = CreateLogic.permissionMode(restored, neonChoice)
    XCTAssertEqual(neonPermission?.configId, "permission_mode")
    XCTAssertEqual(neonPermission?.value, "yolo")

    // Changing permission writes `permission_mode` so panel and send stay identical.
    let switchedToAsk = CreateLogic.withPermissionMode(restored, neonChoice, value: "ask")
    XCTAssertEqual(switchedToAsk.configOptionValues?["permission_mode"], .string("ask"))
    XCTAssertEqual(CreateLogic.permissionMode(restored, switchedToAsk)?.value, "ask")

    // Remembered prefs and applicableChoice keep target-model observed options.
    let prefs = CreateLogic.withSelection(
      nil, target: "chat",
      selection: ProjectPrefs(modelId: "gemini-4-neon", configOptionValues: ["permission_mode": .string("yolo")], machineId: "m1", agentKey: "m1:agy"),
      chat: true
    )
    let remembered = CreateLogic.rememberedModelChoice(prefs, agentKey: "m1:agy", capability: restored, modelId: "gemini-4-neon")
    XCTAssertEqual(remembered.configOptionValues?["permission_mode"], .string("yolo"))
    let applicable = CreateLogic.applicableChoice(
      ModelChoice(configOptionValues: ["model": .string("gemini-4-neon"), "permission_mode": .string("yolo")]),
      capability: restored
    )
    XCTAssertEqual(applicable.modelId, "gemini-4-neon")
    XCTAssertEqual(applicable.configOptionValues?["permission_mode"], .string("yolo"))
  }

  func testCanonicalSelectedModelAndComposerModelSwitchClearStaleModelOption() {
    let capability = Capability(
      machineId: "m1", cliType: "registry", agentType: "custom-acp",
      models: [CapabilityChoice(id: "model-a", name: "A"), CapabilityChoice(id: "model-b", name: "B")],
      configOptions: [
        ConfigOption(id: "model_selector", name: "Model", category: "model", type: "select", currentValue: .string("model-a"),
                     options: [CapabilityChoice(id: "model-a", name: "A"), CapabilityChoice(id: "model-b", name: "B")]),
      ]
    )
    let fromOptionOnly = ModelChoice(configOptionValues: ["model_selector": .string("model-b")])
    XCTAssertEqual(CreateLogic.selectedModelId(capability, fromOptionOnly), "model-b")
    let switched = CreateLogic.applyingComposerChange(capability, fromOptionOnly, body: ["modelId": "model-a", "effort": ""])
    XCTAssertEqual(switched.modelId, "model-a")
    XCTAssertNil(switched.configOptionValues?["model_selector"])
    XCTAssertEqual(CreateLogic.selectedModelId(capability, switched), "model-a")
  }

  func testAntigravityLegacyModesAndConfigModePreferConfigOptionAndThoughtLevel() {
    let modes = [
      CapabilityChoice(id: "ask", name: "Ask"),
      CapabilityChoice(id: "auto", name: "Auto"),
      CapabilityChoice(id: "yolo", name: "YOLO"),
    ]
    let capability = Capability(
      machineId: "m1", agentConfigId: "agy", cliType: "registry", agentType: "antigravity",
      models: [CapabilityChoice(id: "gemini-4-neon", name: "Gemini 4 Neon")],
      modes: modes, legacyModes: modes,
      reasoningEfforts: ["gemini-4-neon": ["low", "high", "xhigh"]],
      reasoningEffortConfigId: "thought_level",
      configOptions: [
        ConfigOption(id: "model", name: "Model", category: "model", type: "select", currentValue: .string("gemini-4-neon"),
                     options: [CapabilityChoice(id: "gemini-4-neon", name: "Gemini 4 Neon")]),
        ConfigOption(id: "interaction_mode", name: "Interaction", category: "mode", type: "select", currentValue: .string("code"),
                     options: [CapabilityChoice(id: "code", name: "Code")]),
        ConfigOption(id: "mode", name: "Permission", category: "mode", type: "select", currentValue: .string("ask"), options: modes),
        ConfigOption(id: "thought_level", name: "Reasoning", category: "thought_level", type: "select", currentValue: .string("high"),
                     options: [CapabilityChoice(id: "low", name: "Low"), CapabilityChoice(id: "high", name: "High"), CapabilityChoice(id: "xhigh", name: "XHigh")]),
      ]
    )

    // Config-option-driven agent prefers configOptions.mode even when legacyModes is non-empty.
    let roleChoice = ModelChoice(
      modelId: "gemini-4-neon", modeId: "ask",
      configOptionValues: ["mode": .string("yolo"), "thought_level": .string("xhigh")]
    )
    let permission = CreateLogic.permissionMode(capability, roleChoice)
    XCTAssertEqual(permission?.configId, "mode")
    XCTAssertEqual(permission?.value, "yolo")
    XCTAssertEqual(CreateLogic.effortOptionId(capability, modelId: "gemini-4-neon"), "thought_level")
    XCTAssertEqual(CreateLogic.selectedEffort(capability, roleChoice), "xhigh")

    // Changing permission writes configOptionValues.mode and clears competing top-level modeId.
    let edited = CreateLogic.withPermissionMode(capability, roleChoice, value: "auto")
    XCTAssertEqual(edited.configOptionValues?["mode"], .string("auto"))
    XCTAssertNil(edited.modeId)
    XCTAssertEqual(CreateLogic.permissionMode(capability, edited)?.value, "auto")

    // Applicable and remembered choices preserve thought_level effort and canonicalize mode option.
    let applicable = CreateLogic.applicableChoice(roleChoice, capability: capability)
    XCTAssertEqual(applicable.effort, "xhigh")
    XCTAssertEqual(applicable.configOptionValues?["mode"], .string("yolo"))
    XCTAssertNil(applicable.modeId)
    let prefs = CreateLogic.withSelection(
      nil, target: "chat",
      selection: ProjectPrefs(modelId: "gemini-4-neon", effort: "xhigh", configOptionValues: ["mode": .string("auto")], machineId: "m1", agentKey: "m1:agy"),
      chat: true
    )
    let remembered = CreateLogic.rememberedModelChoice(prefs, agentKey: "m1:agy", capability: capability, modelId: "gemini-4-neon")
    XCTAssertEqual(remembered.effort, "xhigh")
    XCTAssertEqual(remembered.configOptionValues?["mode"], .string("auto"))
    XCTAssertNil(remembered.modeId)
  }

  func testDeclaredFastModePreservedAcrossObservedModelConfigOptionsSwitch() {
    let capability = Capability(
      machineId: "m1", agentConfigId: "codex", cliType: "builtin", agentType: "codex",
      models: [CapabilityChoice(id: "gpt-5.3", name: "GPT-5.3"), CapabilityChoice(id: "gpt-5.4", name: "GPT-5.4")],
      modes: [CapabilityChoice(id: "agent", name: "Agent")],
      reasoningEfforts: ["gpt-5.3": ["low", "high"], "gpt-5.4": ["low", "high"]],
      reasoningEffortConfigId: "reasoning_effort",
      fastModes: ["gpt-5.3": false, "gpt-5.4": true],
      configOptions: [
        ConfigOption(id: "model", name: "Model", category: "model", type: "select", currentValue: .string("gpt-5.3"),
                     options: [CapabilityChoice(id: "gpt-5.3", name: "GPT-5.3"), CapabilityChoice(id: "gpt-5.4", name: "GPT-5.4")]),
        ConfigOption(id: "reasoning_effort", name: "Reasoning", category: "thought_level", type: "select", currentValue: .string("high"),
                     options: [CapabilityChoice(id: "low", name: "Low"), CapabilityChoice(id: "high", name: "High")]),
        ConfigOption(id: "fast-mode", name: "Fast", type: "boolean", currentValue: .bool(false), options: []),
      ],
      observedModelConfigOptions: [
        "gpt-5.3": [
          ConfigOption(id: "reasoning_effort", name: "Reasoning", category: "thought_level", type: "select", currentValue: .string("high"),
                       options: [CapabilityChoice(id: "low", name: "Low"), CapabilityChoice(id: "high", name: "High")]),
        ],
        "gpt-5.4": [
          ConfigOption(id: "reasoning_effort", name: "Reasoning", category: "thought_level", type: "select", currentValue: .string("high"),
                       options: [CapabilityChoice(id: "low", name: "Low"), CapabilityChoice(id: "high", name: "High")]),
        ],
      ]
    )

    // Model declaring fastMode: false hides Fast.
    XCTAssertNil(CreateLogic.fastMode(capability, ModelChoice(modelId: "gpt-5.3")))
    XCTAssertFalse(CreateLogic.extraConfigOptions(capability, modelId: "gpt-5.3").contains { $0.id == "fast-mode" })

    // Model declaring fastMode: true retains the Fast toggle even when omitted from observedModelConfigOptions.
    let fastChoice = ModelChoice(modelId: "gpt-5.4")
    XCTAssertEqual(CreateLogic.fastMode(capability, fastChoice)?.id, "fast-mode")
    XCTAssertEqual(CreateLogic.fastMode(capability, fastChoice)?.enabled, false)
    let enabled = CreateLogic.withFastMode(capability, fastChoice, enabled: true)
    XCTAssertEqual(enabled.configOptionValues?["fast-mode"], .bool(true))
    XCTAssertEqual(CreateLogic.fastMode(capability, enabled)?.enabled, true)
    XCTAssertEqual(CreateLogic.applicableChoice(enabled, capability: capability).configOptionValues?["fast-mode"], .bool(true))

    // Claude synthesizes `fast` when fastModes[model] == true and snapshot had no fast option.
    let claude = Capability(
      machineId: "m1", agentConfigId: "claude", cliType: "builtin", agentType: "claude",
      models: [CapabilityChoice(id: "sonnet", name: "Sonnet"), CapabilityChoice(id: "opus", name: "Opus")],
      fastModes: ["sonnet": false, "opus": true],
      configOptions: [
        ConfigOption(id: "model", name: "Model", category: "model", type: "select", currentValue: .string("sonnet"),
                     options: [CapabilityChoice(id: "sonnet", name: "Sonnet"), CapabilityChoice(id: "opus", name: "Opus")]),
      ],
      observedModelConfigOptions: ["opus": []]
    )
    XCTAssertNil(CreateLogic.fastMode(claude, ModelChoice(modelId: "sonnet")))
    XCTAssertEqual(CreateLogic.fastMode(claude, ModelChoice(modelId: "opus"))?.id, "fast")
  }
}
