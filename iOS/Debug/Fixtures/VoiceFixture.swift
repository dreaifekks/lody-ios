import UIKit
import LodyCore

@MainActor
final class VoiceFixture: VoiceDictationPeer {
  var onMessage: ((String) -> Void)?
  var onFailure: (() -> Void)?
  var startReply: CheckedContinuation<[String: Any], Never>?
  private var pollReply: CheckedContinuation<[String: Any], Never>?
  var calls: [String] = []
  var onCalls: (() -> Void)?
  var fail = false
  private var closed = false

  static let agents = RuntimeContract.VoiceAgentsResult(shared: .init(configId: "codex", machineId: "mini"), agents: [
    .init(configId: "codex", machineId: "mini", name: "Codex", machineName: "Mini", supported: true),
    .init(configId: "other", machineId: "laptop", name: "Codex", machineName: "Laptop", supported: false),
  ])
  func offer() async throws -> String { "fixture-offer" }
  func answer(_ sdp: String) async throws {}
  func close() { closed = true }
  func request(_ body: [String: Any], _ machine: String?, _ agent: [String: String]?) async -> [String: Any] {
    let action = body["action"] as! String
    calls.append(action)
    onCalls?()
    switch action {
    case "start":
      closed = false
      if fail { return ["success": false, "error": "voice_unsupported"] }
      return await withCheckedContinuation { startReply = $0 }
    case "poll":
      return await withCheckedContinuation { pollReply = $0 }
    default:
      pollReply?.resume(returning: ["success": true, "closed": true]); pollReply = nil
      return ["success": true]
    }
  }
  func connect() {
    startReply?.resume(returning: ["success": true, "machineId": "mini", "voiceSessionId": "fixture-call", "sdp": "fixture-answer"])
    startReply = nil
  }
  func transcript() {
    if !closed { onMessage?(#"{"type":"input_transcript.added","item":{"text":"Dictated offline text"}}"#) }
  }
  func dictation() -> VoiceDictation {
    VoiceDictation(request: { self.request }, permission: { true }, makePeer: { self })
  }
}
