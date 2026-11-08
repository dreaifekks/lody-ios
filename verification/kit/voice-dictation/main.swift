import UIKit
import LodyCore

@MainActor
final class Peer: VoiceDictationPeer {
  var onMessage: ((String) -> Void)?
  var onFailure: (() -> Void)?
  var closed = false
  var answerText = ""
  func offer() async throws -> String { "native-offer" }
  func answer(_ sdp: String) async throws { answerText = sdp }
  func close() { closed = true }
  func text(_ value: String) {
    let data = try! JSONSerialization.data(withJSONObject: ["type": "input_transcript.added", "item": ["text": value]])
    onMessage?(String(decoding: data, as: UTF8.self))
  }
}

@MainActor
final class RPC {
  var requests: [([String: Any], String?, [String: String]?)] = []
  var start: CheckedContinuation<[String: Any], Never>?
  var poll: CheckedContinuation<[String: Any], Never>?
  func request(_ body: [String: Any], _ machine: String?, _ agent: [String: String]?) async -> [String: Any] {
    requests.append((body, machine, agent))
    switch body["action"] as! String {
    case "start": return await withCheckedContinuation { start = $0 }
    case "poll": return await withCheckedContinuation { poll = $0 }
    default: return ["success": true]
    }
  }
  func started() {
    start!.resume(returning: ["success": true, "voiceSessionId": "call-1", "machineId": "mini", "sdp": "native-answer"])
    start = nil
  }
  func polled(_ reply: sending [String: Any]) { poll!.resume(returning: reply); poll = nil }
  var actions: [String] { requests.map { $0.0["action"] as! String } }
}

@main
struct Verify {
  @MainActor
  static func wait(_ condition: @escaping @MainActor () -> Bool) async {
    for _ in 0..<300 {
      if condition() { return }
      try! await Task.sleep(for: .milliseconds(10))
    }
    preconditionFailure("native voice check timed out")
  }

  @MainActor
  static func main() async {
    let peer = Peer(), rpc = RPC()
    let voice = VoiceDictation(request: { rpc.request }, permission: { true }, makePeer: { peer })
    var words: [String] = [], errors: [String] = []
    voice.onTranscript = { words.append($0) }; voice.onError = { errors.append($0) }
    voice.start(agent: ["configId": "codex", "machineId": "mini"])
    await wait { rpc.start != nil }
    precondition(voice.state == .connecting)
    precondition(rpc.requests[0].0["mode"] as? String == "dictation")
    precondition(rpc.requests[0].0["sdp"] as? String == "native-offer")
    precondition(rpc.requests[0].2?["configId"] == "codex")
    rpc.started(); await wait { rpc.poll != nil }
    precondition(voice.state == .active && peer.answerText == "native-answer")
    precondition(rpc.requests[1].1 == "mini" && rpc.requests[1].2 == nil)
    precondition(rpc.requests[1].0["after"] as? Int == 0 && rpc.requests[1].0["waitMs"] as? Int == 12000)
    peer.text("Hello "); peer.text("world")
    precondition(words == ["Hello ", "Hello world"])
    rpc.polled(["success": true, "events": [["seq": 7, "event": ["type": "error", "message": "fixture error"]]]])
    await wait { rpc.poll != nil }
    precondition(rpc.requests.last!.0["after"] as? Int == 7 && errors == ["fixture error"])
    voice.stop(); await wait { rpc.actions.last == "stop" }
    precondition(voice.state == .idle && peer.closed)
    precondition(rpc.requests.last!.0["voiceSessionId"] as? String == "call-1" && rpc.requests.last!.1 == "mini")
    peer.text(" ignored"); rpc.polled(["success": true, "closed": true])
    precondition(words.last == "Hello world")

    let lateRPC = RPC(), latePeer = Peer()
    let late = VoiceDictation(request: { lateRPC.request }, permission: { true }, makePeer: { latePeer })
    late.start(agent: nil); await wait { lateRPC.start != nil }
    precondition(lateRPC.requests[0].2 == nil, "workspace default passes no override")
    late.stop(); lateRPC.started(); await wait { lateRPC.actions.last == "stop" }
    precondition(late.state == .idle && lateRPC.actions == ["start", "stop"])

    let failedRPC = RPC(), failedPeer = Peer()
    let failed = VoiceDictation(request: { failedRPC.request }, permission: { true }, makePeer: { failedPeer })
    failed.start(agent: nil); await wait { failedRPC.start != nil }; failedRPC.started(); await wait { failedRPC.poll != nil }
    failedRPC.polled(["success": false, "error": "machine_unavailable"])
    await wait { failedRPC.actions.last == "stop" }
    precondition(failed.state == .idle && failedPeer.closed)

    var permission: CheckedContinuation<Bool, Never>?
    let cancelled = VoiceDictation(request: { rpc.request }, permission: { await withCheckedContinuation { permission = $0 } }, makePeer: { Peer() })
    cancelled.start(agent: nil); await wait { permission != nil }; cancelled.stop(); permission!.resume(returning: true)
    try! await Task.sleep(for: .milliseconds(30))
    precondition(cancelled.state == .idle && rpc.actions.filter { $0 == "start" }.count == 1)

    let priorEnabled = VoicePreferences.enabled, priorAgent = VoicePreferences.agent
    defer { VoicePreferences.save(enabled: priorEnabled, configId: priorAgent?["configId"] ?? "", machineId: priorAgent?["machineId"] ?? "") }
    VoicePreferences.save(enabled: false)
    precondition(VoiceSettings.section(snapshot: nil, failed: false, signedIn: true).rows.count == 1)
    VoicePreferences.save(enabled: true)
    // Native discovery consumes the typed RPC result, including old/unsupported members.
    let discovered = try! JSONDecoder().decode(RuntimeContract.VoiceAgentsResult.self, from: Data(#"{"shared":{"configId":"codex","machineId":"mini"},"agents":[{"configId":"codex","machineId":"mini","name":"Codex","machineName":"Mini","supported":true},{"configId":"other","machineId":"laptop","name":"Codex","machineName":"Laptop","supported":false}]}"#.utf8))
    let section = VoiceSettings.section(snapshot: discovered, failed: false, signedIn: true)
    precondition(section.rows.count == 2 && section.rows[1].options.count == 3)
    VoiceSettings.choose("agent:other:laptop", snapshot: discovered)
    precondition(VoicePreferences.agent == ["configId": "other", "machineId": "laptop"])
    VoiceSettings.choose("workspace", snapshot: discovered)
    precondition(VoicePreferences.agent == nil)
    precondition(VoiceSettings.section(snapshot: discovered, failed: false, signedIn: false).rows.count == 1)
    print("PASS native voice: start/poll/cursor/stop, transcript, late start cleanup, failed poll, permission cancellation, agent discovery and preferences")
    exit(0)
  }
}
