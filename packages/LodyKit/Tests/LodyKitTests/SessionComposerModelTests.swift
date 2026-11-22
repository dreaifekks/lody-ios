import Foundation
import LodyCore
import XCTest
@testable import LodyKit

/// The conversation composer's run config when the computer's creation options arrive late: the
/// runtime can answer before the computer's stream caught up, listing no capability for it.
@MainActor
final class SessionComposerModelTests: XCTestCase {
  private struct Unready: Error {}

  private final class Options {
    var replies: [Result<CreationOptions, Error>] = []
    var reads = 0
  }

  private let session = SessionItem(id: "s1", agentConfigId: "a1", machineId: "m1", cliType: "builtin", agentType: "codex")
  private let complete = CreationOptions(
    sessionId: "s1",
    agents: [CreationAgent(id: "a1", name: "Codex", machineId: "m1", machineName: "Mac", cliType: "builtin", agentType: "codex")],
    capabilities: [Capability(
      machineId: "m1", agentConfigId: "a1", cliType: "builtin", agentType: "codex",
      models: [CapabilityChoice(id: "gpt", name: "GPT")], reasoningEfforts: ["gpt": ["low", "high"]])])
  private var caughtUpLate: CreationOptions { CreationOptions(sessionId: "s1", agents: complete.agents, capabilities: []) }

  private func model(_ options: Options, probes: Probes? = nil, configNames: [String: String] = [:]) -> SessionComposerModel {
    SessionComposerModel(choice: nil, service: SessionComposerService(
      options: { _, _ in
        options.reads += 1
        return try options.replies.removeFirst().get()
      },
      tier: { _, _ in nil },
      roles: { _ in [] },
      probe: { _, _, configId in probes?.configs.append(configId) },
      configName: { _, configId in configNames[configId] }))
  }

  private final class Probes {
    var configs: [String] = []
  }

  private let custom = SessionItem(
    id: "s2", agentConfigId: "c1", machineId: "m1", cliType: "custom", agentType: "custom-8c130ff1-9d74-4f46-a79b-6a1f0e2d3c4b")

  private func agentTitle(_ model: SessionComposerModel) -> String? {
    model.runConfig.first { $0.id == "agent" }?.title
  }

  /// The run-config rows the computer's options decide (the Role row follows the Roles list).
  private func rows(_ model: SessionComposerModel) -> [String] {
    model.runConfig.map(\.id).filter { $0 != "role" }
  }

  /// Runs an action and waits for the options read it started.
  private func settle(_ model: SessionComposerModel, _ action: () -> Void) async {
    action()
    await model.capabilityTask?.value
  }

  func testOptionsWithoutTheComputersCapabilityAreReadAgainWhenTheyChange() async {
    let options = Options()
    options.replies = [.success(caughtUpLate), .success(complete)]
    let model = model(options)
    await settle(model) { model.load(workspaceId: "w1", projectId: nil, session: session) }
    XCTAssertNil(model.capability)
    XCTAssertEqual(rows(model), ["agent"], "without a capability the sheet has only the locked agent")

    // Renders of the same conversation do not re-read; changed options do.
    model.load(workspaceId: "w1", projectId: nil, session: session)
    XCTAssertEqual(options.reads, 1)
    await settle(model) { model.optionsChanged() }
    XCTAssertEqual(options.reads, 2)
    XCTAssertEqual(rows(model), ["agent", "model"])
    XCTAssertEqual(model.runConfig.first { $0.id == "agent" }?.title, "Codex")

    // Once complete, further option changes leave the conversation alone.
    model.optionsChanged()
    model.load(workspaceId: "w1", projectId: nil, session: session)
    XCTAssertEqual(options.reads, 2)
  }

  func testAFailedReadWaitsForChangedOptionsAndRetriesKeepTheCapability() async {
    let options = Options()
    options.replies = [.failure(Unready()), .success(CreationOptions(sessionId: "s1", agents: [], capabilities: complete.capabilities)), .failure(Unready())]
    let model = model(options)
    await settle(model) { model.load(workspaceId: "w1", projectId: nil, session: session) }
    XCTAssertNil(model.capability)
    // A failed read is not retried by every render (that re-read in a loop while the runtime started).
    model.load(workspaceId: "w1", projectId: nil, session: session)
    XCTAssertEqual(options.reads, 1)

    // The computer is offline: its capability is listed, its agent is not, so it reads again.
    await settle(model) { model.optionsChanged() }
    XCTAssertEqual(rows(model), ["agent", "model"])
    XCTAssertNil(model.agentName)

    await settle(model) { model.optionsChanged() }
    XCTAssertEqual(options.reads, 3)
    XCTAssertEqual(rows(model), ["agent", "model"], "a failed retry keeps the capability it had")

    // A retry while the computer's stream imports updates lists neither; what was found stays.
    options.replies.append(.success(CreationOptions(sessionId: "s1", agents: [], capabilities: [])))
    await settle(model) { model.optionsChanged() }
    XCTAssertEqual(options.reads, 4)
    XCTAssertEqual(rows(model), ["agent", "model"], "a retry missing the computer keeps its capability")
  }

  func testACustomAgentShowsItsConfiguredNameNeverItsInternalType() async {
    let options = Options()
    // The computer is offline: the options list neither its agent nor a capability.
    options.replies = [.success(CreationOptions(sessionId: "s2", agents: [], capabilities: []))]
    let named = model(options, configNames: ["c1": "Cursor yolo"])
    await settle(named) { named.load(workspaceId: "w1", projectId: nil, session: custom) }
    XCTAssertEqual(agentTitle(named), "Cursor yolo")
    XCTAssertTrue(named.optionsJSON.contains("Cursor yolo"), "the collapsed mark names it too")

    options.replies = [.failure(Unready())]
    let unknown = model(options)
    await settle(unknown) { unknown.load(workspaceId: "w1", projectId: nil, session: custom) }
    let title = agentTitle(unknown) ?? ""
    XCTAssertFalse(title.isEmpty)
    XCTAssertFalse(title.contains("custom-"), "the agent type is an internal slug, not a name")
    XCTAssertFalse(unknown.optionsJSON.contains("custom-8c130ff1"))
  }

  func testAnOnlineAgentWithoutACapabilityIsProbedOnceAndItsAnswerLoadsTheOptions() async {
    let options = Options(), probes = Probes()
    let agent = CreationAgent(id: "c1", name: "Cursor yolo", machineId: "m1", machineName: "Mac", cliType: "custom", agentType: custom.agentType)
    let unprobed = CreationOptions(sessionId: "s2", agents: [agent], capabilities: [])
    let probed = CreationOptions(sessionId: "s2", agents: [agent], capabilities: [Capability(
      machineId: "m1", agentConfigId: "c1", cliType: "custom", agentType: custom.agentType,
      models: [CapabilityChoice(id: "auto", name: "Auto")], reasoningEfforts: [:])])
    options.replies = [.success(unprobed), .success(unprobed), .success(probed)]
    let model = model(options, probes: probes)
    await settle(model) { model.load(workspaceId: "w1", projectId: nil, session: custom) }
    await model.probeTask?.value
    XCTAssertEqual(probes.configs, ["c1"])
    XCTAssertEqual(agentTitle(model), "Cursor yolo")
    XCTAssertEqual(rows(model), ["agent"])

    // A change before the probe answers does not probe again.
    await settle(model) { model.optionsChanged() }
    XCTAssertEqual(probes.configs, ["c1"])

    await settle(model) { model.optionsChanged() }
    XCTAssertEqual(rows(model), ["agent", "model"])
    XCTAssertEqual(probes.configs, ["c1"])
  }
}
