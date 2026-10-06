#if !LODY_SHARE_EXTENSION
import AVFoundation
import UIKit
@preconcurrency import WebRTC

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
  /// A slow network still finishes ICE gathering well inside this; send what exists after.
  private static let iceGatheringLimit: Duration = .seconds(4)

  private static let factory: RTCPeerConnectionFactory = {
    RTCInitializeSSL()
    return RTCPeerConnectionFactory()
  }()

  private final class Call {
    let peer: RTCPeerConnection
    let link: VoicePeerLink
    let track: RTCAudioTrack
    var channel: RTCDataChannel?
    var machineId: String?
    var voiceSessionId: String?
    var transcript = ""
    var stopped = false
    init(peer: RTCPeerConnection, link: VoicePeerLink, track: RTCAudioTrack) {
      self.peer = peer
      self.link = link
      self.track = track
    }
  }

  private var call: Call?
  /// Identifies the newest start, so a stop during the permission prompt wins.
  private var startToken = 0
  private let observers = NotificationObservers()

  init() {
    observers.add(NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.stop() }
    })
  }

  func start(agent: [String: String]?) {
    guard state == .idle else { return }
    startToken += 1
    let token = startToken
    state = .connecting
    Task {
      let granted = await AVAudioApplication.requestRecordPermission()
      guard token == self.startToken else { return }
      guard granted else {
        self.state = .idle
        self.onError?(LodyStrings.text("native.voice.microphoneDenied"))
        return
      }
      await self.connect(agent: agent, token: token)
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
      Task { _ = await Self.request(["action": "stop", "voiceSessionId": id], machineId: machineId) }
    }
  }

  private func connect(agent: [String: String]?, token: Int) async {
    let link = VoicePeerLink()
    let configuration = RTCConfiguration()
    configuration.sdpSemantics = .unifiedPlan
    let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    guard let peer = Self.factory.peerConnection(with: configuration, constraints: constraints, delegate: link) else {
      state = .idle
      onError?(LodyStrings.text("native.voice.failed"))
      return
    }
    let track = Self.factory.audioTrack(with: Self.factory.audioSource(with: constraints), trackId: "microphone")
    peer.add(track, streamIds: ["microphone"])
    // Dictation keeps the voice silent; never play whatever it might say.
    for receiver in peer.receivers { receiver.track?.isEnabled = false }
    let call = Call(peer: peer, link: link, track: track)
    self.call = call
    link.owner = self
    link.channel = { [weak self, weak call] text in
      guard let self, let call else { return }
      self.receive(text, call: call)
    }
    link.failed = { [weak self, weak call] in
      guard let self, let call else { return }
      self.fail(call, LodyStrings.text("native.voice.dropped"))
    }
    let channel = peer.dataChannel(forLabel: "oai-events", configuration: RTCDataChannelConfiguration())
    channel?.delegate = link
    call.channel = channel

    do {
      let offer = try await Self.offer(peer, constraints: constraints)
      try await Self.setLocal(peer, sdp: offer)
      let deadline = ContinuousClock.now + Self.iceGatheringLimit
      while peer.iceGatheringState != .complete, ContinuousClock.now < deadline, !call.stopped {
        try? await Task.sleep(for: .milliseconds(100))
      }
      guard !call.stopped, token == startToken else { return }
      guard let sdp = peer.localDescription?.sdp else { throw VoiceFailure(LodyStrings.text("native.voice.failed")) }
      let reply = await Self.request(["action": "start", "mode": "dictation", "sdp": sdp], agent: agent)
      if let machineId = reply["machineId"] as? String { call.machineId = machineId }
      guard reply["success"] as? Bool == true, let id = reply["voiceSessionId"] as? String,
            let answer = reply["sdp"] as? String else {
        throw VoiceFailure(Self.message(reply))
      }
      call.voiceSessionId = id
      if call.stopped {
        if let machineId = call.machineId {
          _ = await Self.request(["action": "stop", "voiceSessionId": id], machineId: machineId)
        }
        return
      }
      try await Self.setRemote(peer, sdp: answer)
      for receiver in peer.receivers { receiver.track?.isEnabled = false }
      state = .active
      await poll(call, voiceSessionId: id)
    } catch {
      fail(call, (error as? VoiceFailure)?.message ?? error.localizedDescription)
    }
  }

  private func poll(_ call: Call, voiceSessionId: String) async {
    var after = 0
    while !call.stopped, let machineId = call.machineId {
      let reply = await Self.request(
        ["action": "poll", "voiceSessionId": voiceSessionId, "after": after, "waitMs": Self.pollWaitMs],
        machineId: machineId
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
      Task { _ = await Self.request(["action": "stop", "voiceSessionId": id], machineId: machineId) }
    }
    onError?(message)
  }

  private func teardown(_ call: Call) {
    guard !call.stopped else { return }
    call.stopped = true
    call.track.isEnabled = false
    call.channel?.close()
    call.peer.close()
    call.link.owner = nil
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

  private static func request(_ body: [String: Any], machineId: String? = nil, agent: [String: String]? = nil) async -> [String: Any] {
    guard let runtime = DataRuntime.active, let workspace = runtime.workspaceId else {
      return ["success": false, "error": "metadata_not_ready"]
    }
    var payload: [String: Any] = ["workspaceId": workspace, "request": body]
    if let machineId { payload["machineId"] = machineId }
    if let agent { payload["agent"] = agent }
    guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
      return ["success": false, "error": "invalid_request"]
    }
    do {
      let text = try await runtime.command("machineVoice", payload: String(decoding: data, as: UTF8.self))
      return (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        ?? ["success": false, "error": "invalid_voice_response"]
    } catch {
      return ["success": false, "error": (error as NSError).localizedDescription]
    }
  }

  private static func message(_ reply: [String: Any]) -> String {
    let error = reply["error"] as? String ?? ""
    let known = [
      "voice_no_agent": "native.voice.noAgent",
      "voice_unsupported": "native.voice.unsupported",
      "machine_unavailable": "native.voice.machineUnavailable",
      "metadata_not_ready": "native.runtime.sessionNotSynced",
    ]
    if let key = known[error] { return LodyStrings.text(key) }
    return error.isEmpty ? LodyStrings.text("native.voice.failed") : error
  }

  // MARK: - WebRTC completion handlers

  // WebRTC answers on its signaling thread; `@Sendable` keeps these handlers
  // from inheriting main-actor isolation and its executor check.

  private static func offer(_ peer: RTCPeerConnection, constraints: RTCMediaConstraints) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      peer.offer(for: constraints) { @Sendable description, error in
        if let description { continuation.resume(returning: description.sdp) }
        else { continuation.resume(throwing: error ?? VoiceFailure(LodyStrings.text("native.voice.failed"))) }
      }
    }
  }

  private static func setLocal(_ peer: RTCPeerConnection, sdp: String) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      peer.setLocalDescription(RTCSessionDescription(type: .offer, sdp: sdp)) { @Sendable error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
  }

  private static func setRemote(_ peer: RTCPeerConnection, sdp: String) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { @Sendable error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
  }
}

/// WebRTC calls back on its signaling thread; everything is handed to the main actor.
private final class VoicePeerLink: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate, @unchecked Sendable {
  @MainActor weak var owner: VoiceDictation?
  @MainActor var channel: ((String) -> Void)?
  @MainActor var failed: (() -> Void)?

  private func onMain(_ work: @escaping @MainActor @Sendable (VoicePeerLink) -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated { work(self) } }
  }

  func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
    guard newState == .failed else { return }
    onMain { link in if link.owner != nil { link.failed?() } }
  }

  func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
    rtpReceiver.track?.isEnabled = false
  }

  func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
    guard !buffer.isBinary else { return }
    let text = String(decoding: buffer.data, as: UTF8.self)
    onMain { link in if link.owner != nil { link.channel?(text) } }
  }

  func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {}
  func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
  func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
  func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
  func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
  func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
  func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
  func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
  func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
  func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
#endif
