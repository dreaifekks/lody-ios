import AVFoundation
import LodyCore
import LodyData

@MainActor
enum VoiceService {
  static func agents() async throws -> RuntimeContract.VoiceAgentsResult {
    guard let runtime = DataRuntime.current else { throw URLError(.notConnectedToInternet) }
    return try await runtime.workspaceCall(RuntimeContract.Calls.VoiceAgents.self) { workspace, _ in
      .init(workspaceId: workspace)
    }
  }

  static func dictation() -> VoiceDictation {
    VoiceDictation(request: {
      let runtime = DataRuntime.current
      let workspace = runtime?.workspace
      return { body, machine, agent in await request(body, machineId: machine, agent: agent, runtime: runtime, workspace: workspace) }
    }, permission: { await AVAudioApplication.requestRecordPermission() }, makePeer: { WebRTCVoicePeer() })
  }

  static func request(_ body: [String: Any], machineId: String?, agent: [String: String]?, runtime: DataRuntime?, workspace: String?) async -> [String: Any] {
    guard let runtime, let workspace else {
      return ["success": false, "error": "metadata_not_ready"]
    }
    do {
      let request = try RuntimeJSON.decode([String: RuntimeContract.JSONValue].self, from: body)
      let choice = agent.map { RuntimeContract.VoiceAgent(configId: $0["configId"]!, machineId: $0["machineId"]!) }
      let reply = try await runtime.perform(RuntimeContract.Calls.MachineVoice.self,
        .init(workspaceId: workspace, request: request, agent: choice, machineId: machineId),
        timeout: body["action"] as? String == "start" ? 190 : 35)
      return try JSONSerialization.jsonObject(with: JSONEncoder().encode(reply)) as! [String: Any]
    } catch {
      return ["success": false, "error": error.localizedDescription]
    }
  }
}
