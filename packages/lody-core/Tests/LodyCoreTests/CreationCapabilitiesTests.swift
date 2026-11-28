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
}
