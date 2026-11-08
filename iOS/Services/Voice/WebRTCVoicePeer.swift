import AVFoundation
import UIKit
@preconcurrency import WebRTC

@MainActor
final class WebRTCVoicePeer: VoiceDictationPeer {
  private static let factory: RTCPeerConnectionFactory = {
    RTCInitializeSSL()
    return RTCPeerConnectionFactory()
  }()
  private let peer: RTCPeerConnection
  private let link = VoicePeerLink()
  private let track: RTCAudioTrack
  private var channel: RTCDataChannel?
  private var closed = false
  var onMessage: ((String) -> Void)?
  var onFailure: (() -> Void)?
  private let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

  init?() {
    let configuration = RTCConfiguration()
    configuration.sdpSemantics = .unifiedPlan
    guard let peer = Self.factory.peerConnection(with: configuration, constraints: constraints, delegate: link) else { return nil }
    self.peer = peer
    track = Self.factory.audioTrack(with: Self.factory.audioSource(with: constraints), trackId: "microphone")
    peer.add(track, streamIds: ["microphone"])
    link.owner = self
    link.channel = { [weak self] in self?.onMessage?($0) }
    link.failed = { [weak self] in self?.onFailure?() }
    channel = peer.dataChannel(forLabel: "oai-events", configuration: RTCDataChannelConfiguration())
    channel?.delegate = link
  }

  func offer() async throws -> String {
    let sdp = try await Self.offer(peer, constraints: constraints)
    try await Self.setLocal(peer, sdp: sdp)
    let deadline = ContinuousClock.now + .seconds(4)
    while peer.iceGatheringState != .complete, ContinuousClock.now < deadline, !closed {
      try? await Task.sleep(for: .milliseconds(100))
    }
    guard let gathered = peer.localDescription?.sdp else { throw NSError(domain: "LodyVoice", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "native.voice.failed", bundle: .lody)]) }
    return gathered
  }

  func answer(_ sdp: String) async throws {
    try await Self.setRemote(peer, sdp: sdp)
    for receiver in peer.receivers { receiver.track?.isEnabled = false }
  }

  func close() {
    closed = true
    track.isEnabled = false
    channel?.close()
    peer.close()
    link.owner = nil
  }

  private static func offer(_ peer: RTCPeerConnection, constraints: RTCMediaConstraints) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      peer.offer(for: constraints) { @Sendable description, error in
        if let description { continuation.resume(returning: description.sdp) }
        else { continuation.resume(throwing: error ?? NSError(domain: "LodyVoice", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "native.voice.failed", bundle: .lody)])) }
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
  @MainActor weak var owner: WebRTCVoicePeer?
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
