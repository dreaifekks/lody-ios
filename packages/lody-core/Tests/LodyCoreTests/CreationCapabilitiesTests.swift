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
}
