#if !LODY_SHARE_EXTENSION
import UIKit

/// One realtime dictation call hosted by the Codex agent chosen in Settings
/// (Lody `machine/voice`). The microphone and the WebRTC peer live here; the
/// machine only negotiates the call, and the user's words arrive on the
/// call's own event channel. Dictation never plays what the voice says.
@MainActor
final class VoiceDictation {
  enum State { case idle, connecting, active }

  private(set) var state: State = .idle {
    didSet { if oldValue != state { onState?(state) } }
  }
  var onState: ((State) -> Void)?
  /// Everything said since the call started.
  var onTranscript: ((String) -> Void)?
  var onError: ((String) -> Void)?

  /// How long the machine holds one poll open while nothing happens.
  private static let pollWaitMs = 12_000
  private final class Call {
    let peer: any VoiceDictationPeer
    let request: Request
    var machineId: String?
    var voiceSessionId: String?
    var transcript = ""
    var stopped = false
    init(peer: any VoiceDictationPeer, request: @escaping Request) { self.peer = peer; self.request = request }
  }

  typealias Request = @MainActor ([String: Any], String?, [String: String]?) async -> [String: Any]
  private let makeRequest: @MainActor () -> Request
  private let permission: @MainActor () async -> Bool
  private let makePeer: @MainActor () -> (any VoiceDictationPeer)?

  private var call: Call?
  /// Identifies the newest start, so a stop during the permission prompt wins.
  private var startToken = 0
  private var observer: NSObjectProtocol?

  init(request: @escaping @MainActor () -> Request, permission: @escaping @MainActor () async -> Bool,
       makePeer: @escaping @MainActor () -> (any VoiceDictationPeer)?) {
    self.makeRequest = request
    self.permission = permission
    self.makePeer = makePeer
    observer = NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.stop() }
    }
  }

  isolated deinit { observer.map(NotificationCenter.default.removeObserver) }

  func start(agent: [String: String]?) {
    guard state == .idle else { return }
    startToken += 1
    let token = startToken
    state = .connecting
    let request = makeRequest()
    Task {
      let granted = await permission()
      guard token == self.startToken else { return }
      guard granted else {
        self.state = .idle
        self.onError?(String(localized: "native.voice.microphoneDenied", bundle: .lody))
        return
      }
      await self.connect(agent: agent, token: token, request: request)
    }
  }

  func stop() {
    startToken += 1
    guard let call else {
      state = .idle
      return
    }
    teardown(call)
    if let machineId = call.machineId, let id = call.voiceSessionId {
      Task { _ = await call.request(["action": "stop", "voiceSessionId": id], machineId, nil) }
    }
  }

  private func connect(agent: [String: String]?, token: Int, request: @escaping Request) async {
    guard let peer = makePeer() else {
      state = .idle
      onError?(String(localized: "native.voice.failed", bundle: .lody))
      return
    }
    let call = Call(peer: peer, request: request)
    self.call = call
    peer.onMessage = { [weak self, weak call] text in
      guard let self, let call else { return }
      self.receive(text, call: call)
    }
    peer.onFailure = { [weak self, weak call] in
      guard let self, let call else { return }
      self.fail(call, String(localized: "native.voice.dropped", bundle: .lody))
    }
    do {
      let sdp = try await peer.offer()
      guard !call.stopped, token == startToken else { return }
      let reply = await request(["action": "start", "mode": "dictation", "sdp": sdp], nil, agent)
      if let machineId = reply["machineId"] as? String { call.machineId = machineId }
      guard reply["success"] as? Bool == true, let id = reply["voiceSessionId"] as? String,
            let answer = reply["sdp"] as? String else {
        throw VoiceFailure(Self.message(reply))
      }
      call.voiceSessionId = id
      if call.stopped {
        if let machineId = call.machineId {
          _ = await request(["action": "stop", "voiceSessionId": id], machineId, nil)
        }
        return
      }
      try await peer.answer(answer)
      guard !call.stopped else { return }
      state = .active
      await poll(call, voiceSessionId: id)
    } catch {
      fail(call, (error as? VoiceFailure)?.message ?? error.localizedDescription)
    }
  }

  private func poll(_ call: Call, voiceSessionId: String) async {
    var after = 0
    while !call.stopped, let machineId = call.machineId {
      let reply = await call.request(
        ["action": "poll", "voiceSessionId": voiceSessionId, "after": after, "waitMs": Self.pollWaitMs],
        machineId, nil
      )
      if call.stopped { return }
      guard reply["success"] as? Bool == true else {
        fail(call, Self.message(reply))
        return
      }
      for item in reply["events"] as? [[String: Any]] ?? [] {
        if let seq = (item["seq"] as? NSNumber)?.intValue { after = seq }
        let event = item["event"] as? [String: Any]
        if event?["type"] as? String == "error", let message = event?["message"] as? String {
          onError?(message)
        }
      }
      if reply["closed"] as? Bool == true {
        teardown(call)
        return
      }
    }
  }

  private func receive(_ text: String, call: Call) {
    guard !call.stopped, self.call === call,
          let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
          object["type"] as? String == "input_transcript.added",
          let words = (object["item"] as? [String: Any])?["text"] as? String else { return }
    call.transcript += words
    onTranscript?(call.transcript)
  }

  private func fail(_ call: Call, _ message: String) {
    guard !call.stopped else { return }
    teardown(call)
    if let machineId = call.machineId, let id = call.voiceSessionId {
      Task { _ = await call.request(["action": "stop", "voiceSessionId": id], machineId, nil) }
    }
    onError?(message)
  }

  private func teardown(_ call: Call) {
    guard !call.stopped else { return }
    call.stopped = true
    call.peer.close()
    if self.call === call {
      self.call = nil
      state = .idle
    }
  }

  // MARK: - Machine requests

  private struct VoiceFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
  }

  private static func message(_ reply: [String: Any]) -> String {
    let error = reply["error"] as? String ?? ""
    let known = [
      "voice_no_agent": "native.voice.noAgent",
      "voice_unsupported": "native.voice.unsupported",
      "machine_unavailable": "native.voice.machineUnavailable",
      "metadata_not_ready": "native.runtime.sessionNotSynced",
    ]
    if let key = known[error] { return String(localized: String.LocalizationValue(key), bundle: .lody) }
    return error.isEmpty ? String(localized: "native.voice.failed", bundle: .lody) : error
  }

}

@MainActor
protocol VoiceDictationPeer: AnyObject {
  var onMessage: ((String) -> Void)? { get set }
  var onFailure: (() -> Void)? { get set }
  func offer() async throws -> String
  func answer(_ sdp: String) async throws
  func close()
}
#endif
