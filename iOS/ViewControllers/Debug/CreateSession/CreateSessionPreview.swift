import LodyCore
import UIKit

@MainActor
final class CreateSessionPreviewController: CreateSessionHostController {
  private let scenario: String
  private var polling: Task<Void, Never>?
  private var presence = ""

  init(scenario: String) {
    self.scenario = scenario
    let fixture = CreateSessionFixture(scenario: scenario)
    super.init(params: fixture.params, service: fixture.service())
    if scenario == "create-lan" { input.usesLAN = { true } }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override var refreshNotifications: [Notification.Name] { [] }

  override func viewDidLoad() {
    super.viewDidLoad()
    guard scenario == "create-recovery" else { return }
    polling = Task { [weak self] in
      while !Task.isCancelled {
        let raw = await CreateSessionFixture.read("ui-device-presence") ?? ""
        self?.presenceChanged(raw)
        try? await Task.sleep(for: .milliseconds(500))
      }
    }
  }

  isolated deinit { polling?.cancel() }

  private func presenceChanged(_ raw: String) {
    presence = raw
    refreshIfNeeded()
  }

  override func currentRefreshKey() -> String { presence }
}

@MainActor
struct CreateSessionFixture {
  private static let optionsJSON = ##"{"sessionId":"SESSION","agents":[{"id":"agent","name":"Fixture Agent","machineId":"ui","machineName":"Fixture Mac","cliType":"builtin","agentType":"codex"},{"id":"grok","name":"grok","machineId":"ui","machineName":"Fixture Mac","cliType":"builtin","agentType":"grok"},{"id":"claude","name":"claude","machineId":"ui","machineName":"Fixture Mac","cliType":"builtin","agentType":"claude"},{"id":"deepseek","name":"deepseek","machineId":"ui","machineName":"Fixture Mac","cliType":"builtin","agentType":"deepseek"}],"capabilities":[{"machineId":"ui","cliType":"builtin","agentType":"codex","models":[{"id":"a","name":"Model A"},{"id":"b","name":"Model B"}],"modes":[{"id":"read-only","name":"Read Only"},{"id":"agent-full-access","name":"Full Access"}],"reasoningEfforts":{"a":["low","high"],"b":["low","high"]},"configOptions":[{"id":"fast-mode","name":"Fast mode","category":"model_config","type":"boolean","currentValue":false,"options":[]},{"id":"collaboration_mode","name":"Collaboration mode","category":"collaboration_mode","type":"select","currentValue":"default","options":[{"id":"default","name":"default"},{"id":"plan","name":"plan"}]}],"steer":true},{"machineId":"ui","cliType":"builtin","agentType":"grok","models":[{"id":"grok-a","name":"Grok A"},{"id":"grok-b","name":"Grok B"}],"modes":[{"id":"agent","name":"Agent"},{"id":"plan","name":"Plan"}],"reasoningEfforts":{"grok-a":["low","high"],"grok-b":["low","high"]},"configOptions":[{"id":"interaction_mode","name":"Interaction Mode","category":"mode","type":"select","currentValue":"agent","options":[{"id":"agent","name":"agent"},{"id":"plan","name":"plan"}]},{"id":"permission_mode","name":"Permission Mode","category":"_permission","type":"select","currentValue":"ask","options":[{"id":"ask","name":"ask"},{"id":"auto","name":"auto"},{"id":"always-approve","name":"always-approve"}]}],"steer":false},{"machineId":"ui","cliType":"builtin","agentType":"claude","models":[{"id":"claude","name":"Claude"}],"modes":[],"reasoningEfforts":{},"configOptions":[{"id":"model","name":"Model","category":"model","type":"select","currentValue":"claude","options":[{"id":"claude","name":"claude"}]},{"id":"effort","name":"Effort","category":"thought_level","type":"select","currentValue":"low","options":[{"id":"low","name":"low"},{"id":"high","name":"high"}]},{"id":"fast","name":"Fast mode","category":"model_config","type":"boolean","currentValue":false,"options":[]}],"steer":false},{"machineId":"ui","cliType":"builtin","agentType":"deepseek","models":[],"modes":[],"reasoningEfforts":{},"configOptions":[{"id":"agent_preset","name":"Agent preset","category":"agent_preset","type":"select","currentValue":"standard","options":[{"id":"standard","name":"standard"},{"id":"coder","name":"coder"}]}],"steer":false}]}"##

  let scenario: String

  var params: CreateSessionHostParams {
    var params = CreateSessionHostParams()
    params.userId = scenario == "create-lan" ? "local:ui-create" : (SettingsSource.live.state.account?.user.id ?? "")
    switch scenario {
    case "model-memory":
      params.workspaceId = "ui-model-memory"
      params.projects = [CreateProject(id: "ui:local:models", machineId: "ui", name: "Model Memory", rootPath: "/fixture")]
      params.projectId = "ui:local:models"
    case "create-lan":
      params.workspaceId = "lw_ui-create"
      params.projects = [Self.alpha]
      params.sendHandoff = false
      params.relay = false
    case "create-recovery":
      params.workspaceId = "ui-home"
      params.projects = [Self.alpha]
      params.initialText = "Keep this draft"
      params.initialAttachmentsJSON = ##"[{"id":"device-draft","name":"notes.txt","kind":"file","uri":"file:///tmp/device-recovery-notes.txt"}]"##
    default:
      params.workspaceId = "ui-project-picker"
      params.projects = [Self.alpha, CreateProject(id: "ui:local:beta", machineId: "ui", name: "Beta", rootPath: "/tmp/beta")]
    }
    return params
  }

  func service() -> CreateSessionService {
    var service = CreateSessionService.live
    let params = params
    let scenario = scenario
    service.persistShare = false
    Self.write(CreateSessionService.prefsKey(userId: params.userId, workspaceId: params.workspaceId), "null")
    if scenario == "create-recovery" { Self.write("ui-device-options-error", "true") }
    service.options = { _, projectId in
      let project = params.projects.first { $0.id == projectId }
      switch scenario {
      case "model-memory": return Self.options("ui-model-memory", project: params.projects.first)
      case "create-recovery": return try await Self.recovery(project: projectId == nil ? nil : project)
      default: return Self.options("ui-create-parity", project: project)
      }
    }
    if scenario == "create-lan" {
      let evidence = LANCreationEvidence()
      service.repositories = { workspace in
        precondition(workspace == params.workspaceId)
        evidence.repositoriesRequested = true
        return ["Owner/Paged", "Owner/Unavailable", "Owner/Empty"]
      }
      service.branches = { _, repo, page in
        evidence.branchRequests.append("\(repo):\(page)")
        if repo == "Owner/Unavailable" { throw CocoaError(.fileReadUnknown) }
        if repo == "Owner/Empty" { return CreateBranches(names: []) }
        if page == 1 { return CreateBranches(names: ["trunk", "develop"], defaultBranch: "trunk", nextPage: 2) }
        return CreateBranches(names: ["feature/search-across-pages"])
      }
      service.options = { _, projectId in
        evidence.optionProjects.append(projectId ?? "chat")
        let project = projectId.flatMap { id in
          id.hasPrefix("github:") ? CreateSessionService.githubProject(String(id.dropFirst(7))) : nil
        } ?? params.projects.first { $0.id == projectId }
        var options = Self.options("ui-lan-create", project: project)
        options.agents.append(CreationAgent(id: "remote", name: "LAN Agent", machineId: "lan-mac", machineName: "LAN Mac", cliType: "builtin", agentType: "codex"))
        return options
      }
      service.readPrefs = { _ in
        try? FileManager.default.removeItem(at: LANCreationEvidence.url)
        try? await OutboxSession.shared.remove(user: params.userId, workspace: params.workspaceId, sessionId: "ui-lan-create").value
        return nil
      }
      service.writePrefs = { _, _ in }
      service.put = { user, workspace, json in
        // Use the ordinary outbox, scoped away from the fixture app's catalog.
        let saved = OutboxSession.shared.put(user: user, workspace: workspace, json: json)
        return Task { @MainActor in
          try await saved.value
          let snapshot = OutboxSession.read(user: user, workspace: workspace)
          try evidence.save(outbox: snapshot)
        }
      }
    }
    return service
  }

  private static let alpha = CreateProject(id: "ui:local:alpha", machineId: "ui", name: "Alpha", rootPath: "/tmp/alpha")

  private static func options(_ sessionId: String, project: CreateProject?) -> CreationOptions {
    var options = CreateJSON.decode(CreationOptions.self, optionsJSON) ?? CreationOptions(sessionId: sessionId, agents: [], capabilities: [])
    options.sessionId = sessionId
    options.project = project
    return options
  }

  private static func recovery(project: CreateProject?) async throws -> CreationOptions {
    if await read("ui-device-options-error") == "true" { throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "fixture_device_unavailable"]) }
    struct Presence: Decodable { var state: String?; var onlineMachineIds: [String]? }
    let presence = await read("ui-device-presence").flatMap { CreateJSON.decode(Presence.self, $0) }
    var options = options("ui-device-recovery", project: project)
    var availability = "unknown"
    if presence?.state == "live" { availability = presence?.onlineMachineIds?.contains("ui") == true ? "online" : "offline" }
    options.availability = availability
    if availability != "online" { options.agents = [] }
    return options
  }

  static func read(_ key: String) async -> String? {
    await withCheckedContinuation { continuation in
      LocalStore.queue.async { continuation.resume(returning: (try? LocalStore.shared.read(key)) ?? nil) }
    }
  }

  // The store queue is serial, so these land before the page's first prefs or options read.
  private static func write(_ key: String, _ value: String) {
    LocalStore.queue.async { _ = try? LocalStore.shared.write(key, value) }
  }
}

// Only the offline UI fixture exports this credential-free observation. Production
// form submission and OutboxSession persistence run before the evidence is written.
@MainActor
private final class LANCreationEvidence {
  static var url: URL { FileManager.default.temporaryDirectory.appendingPathComponent("lody-lan-create.json") }
  var repositoriesRequested = false
  var branchRequests: [String] = []
  var optionProjects: [String] = []

  func save(outbox: String) throws {
    let value: [String: Any] = [
      "repositoriesRequested": repositoriesRequested,
      "branchRequests": branchRequests,
      "optionProjects": optionProjects,
      "outbox": try JSONSerialization.jsonObject(with: Data(outbox.utf8)),
    ]
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: Self.url, options: .atomic)
  }
}
