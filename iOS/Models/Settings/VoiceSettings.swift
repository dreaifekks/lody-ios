import Foundation
import LodyCore

@MainActor
enum VoiceSettings {
  typealias Snapshot = RuntimeContract.VoiceAgentsResult
  typealias Agent = RuntimeContract.VoiceAgentsResultAgentsItem

  static func id(_ agent: Agent) -> String { "agent:\(agent.configId):\(agent.machineId)" }
  static func title(_ agent: Agent) -> String {
    String(format: text(agent.supported ? "agentOption" : "needsUpdate"), agent.name, agent.machineName)
  }
  static func matches(_ agent: Agent, _ choice: [String: String]) -> Bool {
    agent.configId == choice["configId"] && agent.machineId == choice["machineId"]
  }
  static func section(snapshot: Snapshot?, failed: Bool, signedIn: Bool) -> LodyListSection {
    var toggle = LodyListRow()
    toggle.id = "voice-dictation"
    toggle.title = text("title")
    toggle.image = "mic"
    toggle.action = true
    toggle.toggle = VoicePreferences.enabled
    var rows = [toggle]
    if VoicePreferences.enabled && signedIn {
      var value = ""
      let own = VoicePreferences.agent
      if let snapshot {
        if let own {
          value = snapshot.agents.first { matches($0, own) }.map(title) ?? own["configId"]!
        } else if let shared = snapshot.shared {
          let choice = ["configId": shared.configId, "machineId": shared.machineId]
          let name = snapshot.agents.first { matches($0, choice) }.map(title) ?? shared.configId
          value = String(format: text("workspaceValue"), name)
        } else { value = text("notSet") }
      }
      var row = LodyListRow()
      row.id = "voice-agent"
      row.title = text("agent")
      row.value = value
      row.image = "waveform"
      if failed { row.subtitle = text("loadFailed") }
      else if snapshot?.agents.isEmpty == true { row.subtitle = text("noCodex") }
      row.action = snapshot != nil
      var workspace = LodyListAction()
      workspace.id = "workspace"
      workspace.title = text("workspace")
      workspace.selected = own == nil
      row.options = [workspace] + (snapshot?.agents ?? []).map { agent in
        var option = LodyListAction()
        option.id = id(agent)
        option.title = title(agent)
        option.selected = own.map { matches(agent, $0) } ?? false
        return option
      }
      rows.append(row)
    }
    var section = LodyListSection()
    section.id = "experimental"
    section.header = String(localized: "settings.section.experimental", bundle: .lody)
    section.footer = text("footer")
    section.rows = rows
    return section
  }
  static func choose(_ id: String, snapshot: Snapshot?) {
    if id == "workspace" { VoicePreferences.save(enabled: VoicePreferences.enabled) }
    else if let agent = snapshot?.agents.first(where: { Self.id($0) == id }) {
      VoicePreferences.save(enabled: VoicePreferences.enabled, configId: agent.configId, machineId: agent.machineId)
    }
  }
  private static func text(_ key: String) -> String { String(localized: String.LocalizationValue("settings.voice." + key), bundle: .lody) }
}
