import UIKit

@MainActor
enum LanAgentUsagePreview {
  static func make() -> UIViewController {
    let scoped = try! JSONDecoder().decode(AgentUsage.self, from: Data(#"{"configs":[{"id":"personal","name":"Personal","provider":"codex","eligible":true},{"id":"work","name":"Work","provider":"codex","eligible":true}],"quotas":[{"id":"personal","provider":"codex","configId":"personal","name":"Personal quota","windows":[{"usedPercent":13}]},{"id":"work","provider":"codex","configId":"work","name":"Other account quota","windows":[{"usedPercent":81}]},{"id":"legacy","provider":"codex","name":"Legacy quota","windows":[{"usedPercent":29}]}]}"#.utf8))
    let legacy = AgentUsage(configs: [.init(id: "legacy", name: "Legacy", provider: "codex", eligible: true)], quotas: scoped.quotas)
    let agy = AgentUsage(configs: [.init(id: "agy", name: "Antigravity", provider: "antigravity-acp", eligible: true)], quotas: [
      .init(id: "gemini", provider: "antigravity-acp", configId: "agy", name: "Gemini", windows: [.init(usedPercent: 17)]),
      .init(id: "argon", provider: "antigravity-acp", configId: "agy", name: "Old model name", windows: [.init(usedPercent: 62)]),
      .init(id: "other", provider: "antigravity-acp", configId: "agy", windows: [.init(usedPercent: 99)]),
    ])
    let items = [
      RemoteSetting(kind: "agent", id: "personal", name: "Personal Codex", machineId: "scoped", machineName: "Config-scoped Mac", detail: "codex"),
      RemoteSetting(kind: "agent", id: "work", name: "Work Codex", machineId: "scoped", machineName: "Config-scoped Mac", detail: "codex"),
      RemoteSetting(kind: "agent", id: "legacy", name: "Legacy Codex", machineId: "legacy", machineName: "Legacy Mac", detail: "codex"),
      RemoteSetting(kind: "agent", id: "agy", name: "Antigravity", machineId: "agy", machineName: "Antigravity Mac", detail: "antigravity-acp"),
    ]
    return RemoteSettingsController(
      kind: "agent", scope: SettingsActor(userId: "fixture", workspaceId: "lw_quota-fixture"), service: { _ in items }, cache: .memory(),
      context: {
        RemoteSettingsContext(presence: SettingsMachinePresence(state: "live", onlineMachineIds: ["scoped", "legacy", "agy"]),
          agentUsage: ["scoped": scoped, "legacy": legacy, "agy": agy])
      }, refreshUsage: {}
    )
  }
}
