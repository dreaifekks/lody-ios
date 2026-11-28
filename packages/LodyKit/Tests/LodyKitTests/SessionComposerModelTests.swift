import Foundation
import LodyCore
import LodyDesignSystem
import UIKit
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

  @MainActor
  private final class Signal {
    private var count = 0
    private var waiter: CheckedContinuation<Void, Never>?

    func fire() {
      if let waiter {
        self.waiter = nil
        waiter.resume()
      } else {
        count += 1
      }
    }

    func wait() async {
      if count > 0 {
        count -= 1
        return
      }
      await withCheckedContinuation { continuation in
        waiter = continuation
      }
    }
  }

  func testCreateRunConfigSheetDismissesCleanlyAndNeverCollapsesWhenMachineGoesOffline() async {
    UIView.setAnimationsEnabled(false)
    defer { UIView.setAnimationsEnabled(true) }

    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
    let input = LodyComposerView(frame: .zero)
    let controller = CreateSessionController(composer: input.composer, host: input)
    controller.form = CreateSessionForm(
      userId: "u1",
      workspaceId: "w1",
      projects: [CreateProject(id: "github:LodyAI/Lody", machineId: "", name: "LodyAI/Lody")],
      machineNames: ["m1": "Mac Studio"],
      machineOs: ["m1": "darwin"]
    )
    controller.form.open(projectId: "github:LodyAI/Lody", context: nil)
    controller.form.applyBranches(CreateBranches(names: ["main"], defaultBranch: "main"))

    let selectionSignal = Signal()
    let liveGate = Signal()
    var liveReply: CheckedContinuation<CreationOptions, Error>?
    var nextOptions: CreationOptions?
    var presentedSheet: CreateRunConfigSheetController?

    controller.presentSheet = { viewController, _ in
      guard let sheet = viewController as? CreateRunConfigSheetController else { return }
      presentedSheet = sheet
      sheet.onDismissed = {
        if presentedSheet === sheet { presentedSheet = nil }
      }
    }
    controller.onSelection = { _ in selectionSignal.fire() }
    controller.loadCachedOptions = { [complete] in complete }
    controller.loadOptions = {
      if let nextOptions { return nextOptions }
      return try await withCheckedThrowingContinuation { continuation in
        liveReply = continuation
        liveGate.fire()
      }
    }

    window.rootViewController = UINavigationController(rootViewController: controller)
    window.makeKeyAndVisible()
    controller.loadViewIfNeeded()
    window.layoutIfNeeded()

    await selectionSignal.wait()
    await liveGate.wait()

    input.composer.onRunConfig?()
    guard let sheet = presentedSheet else {
      return XCTFail("Expected CreateRunConfigSheetController to be presented from cached options")
    }
    XCTAssertTrue(controller.runConfigSheet === sheet)
    sheet.loadViewIfNeeded()
    sheet.view.frame = CGRect(x: 0, y: 0, width: 393, height: 420)
    sheet.view.layoutIfNeeded()
    XCTAssertEqual(sheet.view.backgroundColor, LodyUIColor.bgBase)
    XCTAssertEqual(sheet.state.runConfig.map(\.id), ["agent", "model"])

    // Live options arrive with the selected computer offline while the sheet is open.
    let offline = CreationOptions(availability: "offline", sessionId: "s-offline", agents: [], capabilities: [])
    liveReply?.resume(returning: offline)
    liveReply = nil
    await selectionSignal.wait()

    XCTAssertTrue(sheet.isDismissPending, "Offline options must mark the presented run-config sheet for dismissal")
    XCTAssertEqual(
      sheet.state.runConfig.map(\.id),
      ["agent", "model"],
      "The dismissing sheet keeps its last rows rather than blanking out mid-transition"
    )
    XCTAssertFalse(controller.form.canSend)
    XCTAssertNotNil(controller.form.current.unavailableMessage)
    XCTAssertNil(controller.runConfigSheet)
    XCTAssertNil(presentedSheet, "The run-config sheet must dismiss when no rows remain")

    // Tapping run-config while the selected computer remains offline must not open an empty sheet.
    input.composer.onRunConfig?()
    XCTAssertNil(controller.runConfigSheet)
    XCTAssertNil(presentedSheet)

    // Defense-in-depth: even if a sheet's state is emptied directly, its scroll surface stays full-width
    // and its detent height stays above the minimum floor rather than collapsing to a narrow title pill.
    let standaloneWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 320))
    let standaloneState = CreatePanelState()
    standaloneState.runConfig = [CreatePicker(id: "agent", glyph: .lody(.agent), title: "Codex")]
    let standalone = CreateRunConfigSheetController(state: standaloneState)
    standaloneWindow.rootViewController = standalone
    standaloneWindow.makeKeyAndVisible()
    standaloneWindow.layoutIfNeeded()
    standaloneState.runConfig = []
    standaloneState.recents = []
    standalone.view.setNeedsLayout()
    standaloneWindow.layoutIfNeeded()
    let scrollViews = Self.descendantScrollViews(in: standalone.view)
    XCTAssertFalse(scrollViews.isEmpty)
    for scrollView in scrollViews {
      XCTAssertEqual(scrollView.bounds.width, 393, accuracy: 1, "Empty run-config ScrollView must never shrink horizontally to title width")
    }
    XCTAssertGreaterThanOrEqual(standalone.contentHeight, CreateRunConfigSheetController.minimumDetentHeight)
    standaloneWindow.isHidden = true

    // When the computer comes back online, run configuration can be opened again cleanly.
    nextOptions = complete
    controller.load(background: true)
    await selectionSignal.wait()
    XCTAssertTrue(controller.form.canSend)
    input.composer.onRunConfig?()
    guard let reopened = presentedSheet else {
      return XCTFail("Expected run-config sheet to reopen once the computer is online again")
    }
    XCTAssertTrue(controller.runConfigSheet === reopened)
    reopened.dismissCleanly(animated: false)
    XCTAssertNil(presentedSheet)
    window.isHidden = true
  }

  private static func descendantScrollViews(in root: UIView) -> [UIScrollView] {
    var result: [UIScrollView] = []
    if let scroll = root as? UIScrollView { result.append(scroll) }
    for child in root.subviews {
      result.append(contentsOf: descendantScrollViews(in: child))
    }
    return result
  }

  func testRegistryRoleReopenAndObservedPermissionOptionStayUnified() async {
    let neonModes = [CapabilityChoice(id: "ask", name: "Ask"), CapabilityChoice(id: "yolo", name: "YOLO")]
    let registryCapability = Capability(
      machineId: "m1", agentConfigId: "agy", cliType: "registry", agentType: "antigravity",
      models: [CapabilityChoice(id: "gemini-3", name: "Gemini 3"), CapabilityChoice(id: "gemini-4-neon", name: "Gemini 4 Neon")],
      modes: neonModes, legacyModes: [],
      configOptions: [
        ConfigOption(id: "model", name: "Model", category: "model", type: "select", currentValue: .string("gemini-3"),
                     options: [CapabilityChoice(id: "gemini-3", name: "Gemini 3"), CapabilityChoice(id: "gemini-4-neon", name: "Gemini 4 Neon")]),
        ConfigOption(id: "mode", name: "Permission", category: "mode", type: "select", currentValue: .string("ask"), options: neonModes),
      ],
      observedModelConfigOptions: [
        "gemini-4-neon": [
          ConfigOption(id: "permission_mode", name: "Permission", category: "mode", type: "select", currentValue: .string("ask"), options: neonModes),
        ],
      ]
    )
    let agent = CreationAgent(id: "agy", name: "Antigravity", machineId: "m1", machineName: "Mini", cliType: "registry", agentType: "antigravity")
    let agyRole = RuntimeContract.AgentRoleItem(
      id: "agy-yolo", ownerUserId: "u1", visibility: .private, name: "Agy YOLO", description: "", promptPrefix: "Ship.",
      emoji: "🚀", revision: 1, updatedAt: 1,
      targets: [.init(
        machineId: "m1", agentConfigId: "agy",
        runConfig: .init(configOptionValues: ["model": .string("gemini-4-neon"), "permission_mode": .string("yolo")]),
        machineName: "Mini", agentName: "Antigravity", state: .configured
      )]
    )
    let registrySession = SessionItem(id: "s-reg", agentConfigId: "agy", machineId: "m1", cliType: "registry", agentType: "antigravity")
    let model = SessionComposerModel(choice: nil, service: SessionComposerService(
      options: { _, _ in CreationOptions(sessionId: "s-reg", agents: [agent], capabilities: [registryCapability]) },
      tier: { _, _ in nil },
      roles: { _ in [agyRole] }
    ))
    await settle(model) { model.load(workspaceId: "w1", projectId: nil, session: registrySession) }
    // Wait for roles task to settle.
    for _ in 0..<20 where model.roleItems.isEmpty { await Task.yield() }

    // Reopen with model stored only in configOptionValues: Role stays active and permission panel shows YOLO.
    model.hydrate(
      pending: nil, ready: true,
      snapshot: ModelChoice(configOptionValues: ["model": .string("gemini-4-neon"), "permission_mode": .string("yolo")]),
      role: .some("agy-yolo")
    )
    XCTAssertEqual(model.activeRole?.role.id, "agy-yolo")
    XCTAssertEqual(model.sendRole, .string("agy-yolo"))
    XCTAssertEqual(model.sendChoice["modelId"], .string("gemini-4-neon"))
    XCTAssertEqual(model.runConfig.first { $0.id == "permission" }?.title, "YOLO")

    // Changing permission in the panel writes `permission_mode` = `ask` and detaches the Role cleanly.
    model.pick("permission", "ask")
    XCTAssertEqual(model.runConfig.first { $0.id == "permission" }?.title, "Ask")
    XCTAssertNil(model.activeRole)
    XCTAssertEqual(model.sendRole, .null)
    if case .object(let sentOptions)? = model.sendChoice["configOptionValues"] {
      XCTAssertEqual(sentOptions["permission_mode"], .string("ask"))
      XCTAssertNil(sentOptions["model"])
    } else {
      XCTFail("Expected configOptionValues in sendChoice")
    }
  }

  func testHiddenActiveMaintenanceTurnRemainsStoppableInSessionControl() throws {
    let envelope = try XCTUnwrap(SessionEnvelope.prepare(#"""
    {"v":1,"revision":5,"status":"live","activeTurnId":"a-compact","usage":{"context":null,"isContextCompacting":true,"quotaEligible":false,"quota":null},"entries":[
      {"id":"u1","role":"user","status":"handled","finished":true,"items":[]},
      {"id":"a1","role":"assistant","finished":true,"items":[]}
    ]}
    """#))
    XCTAssertEqual(envelope.transcript.unfinishedTurnId, "a-compact")
    var capturedPayload: String?
    let control = SessionControl { payload in
      capturedPayload = payload
      return #"{"state":"stopped"}"#
    }
    let state = control.state(session: session, transcript: envelope.transcript, live: true, overflow: false, steerable: false)
    XCTAssertTrue(state.running)
    XCTAssertTrue(state.canStop)
    control.act("stop", session: session, transcript: envelope.transcript, live: true, overflow: false, steerable: false)
    let expectation = expectation(description: "stop dispatched")
    Task { @MainActor in
      for _ in 0..<20 where capturedPayload == nil { await Task.yield() }
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1)
    let sent = try XCTUnwrap(capturedPayload)
    XCTAssertTrue(sent.contains(#""turnId":"a-compact""#), "Expected active maintenance turnId in stop payload: \(sent)")
  }
}
