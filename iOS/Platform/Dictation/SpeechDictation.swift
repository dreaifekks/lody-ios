import AVFoundation
import OSLog
import Speech
import UIKit

/// On-device composer dictation through SpeechAnalyzer and SpeechTranscriber.
/// Audio stays on the device; the recording is neither saved nor uploaded.
@MainActor
final class SpeechDictation: ComposerDictating {
  static let shared: SpeechDictation? = SpeechTranscriber.isAvailable ? SpeechDictation() : nil

  private static let log = Logger(subsystem: "app.innei.lody", category: "dictation")
  private var session: Task<Void, Never>?
  private var generation = 0
  private var capture: DictationCapture?
  private var analyzer: SpeechAnalyzer?
  private var background: NSObjectProtocol?

  private init() {
    background = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.stop() }
    }
  }

  func start(language: String?, onEvent: @escaping @MainActor (DictationEvent) -> Void) {
    let previous = session
    stop()
    generation += 1
    let current = generation
    session = Task { [weak self] in
      await previous?.value
      var failure: Error?
      do {
        try await self?.run(language: language, onEvent: onEvent)
      } catch is CancellationError {
      } catch {
        failure = error
        Self.log.error("Dictation failed: \(error.localizedDescription, privacy: .public)")
      }
      self?.finish(current)
      onEvent(.ended(failure))
    }
  }

  func stop() {
    guard let session else { return }
    guard let capture, let analyzer else { return session.cancel() }
    capture.stop()
    self.capture = nil
    self.analyzer = nil
    Task {
      do {
        try await analyzer.finalizeAndFinishThroughEndOfInput()
      } catch {
        await analyzer.cancelAndFinishNow()
        Self.log.error("Dictation finalize failed: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  private func finish(_ finished: Int) {
    capture?.stop()
    capture = nil
    analyzer = nil
    if generation == finished { session = nil }
  }

  private func run(language: String?, onEvent: @MainActor (DictationEvent) -> Void) async throws {
    guard await AVAudioApplication.requestRecordPermission() else { throw ComposerDictationError.microphoneDenied }
    let wanted = Locale(identifier: language ?? Locale.current.identifier)
    guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else { throw ComposerDictationError.unsupportedLanguage }
    let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
    try await Self.installAssets(for: transcriber, locale: locale)
    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { throw ComposerDictationError.unavailable }
    try Task.checkCancellation()
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let (inputs, continuation) = AsyncStream<AnalyzerInput>.makeStream()
    capture = try DictationCapture(format: format, continuation: continuation)
    self.analyzer = analyzer
    try await analyzer.start(inputSequence: inputs)
    onEvent(.listening)
    for try await result in transcriber.results {
      onEvent(.text(String(result.text.characters), isFinal: result.isFinal))
    }
  }

  private static func installAssets(for transcriber: SpeechTranscriber, locale: Locale) async throws {
    let reserved = await AssetInventory.reservedLocales
    let wanted = locale.identifier(.bcp47)
    if !reserved.contains(where: { $0.identifier(.bcp47) == wanted }) {
      for stale in reserved.prefix(max(0, reserved.count - AssetInventory.maximumReservedLocales + 1)) {
        await AssetInventory.release(reservedLocale: stale)
      }
      try await AssetInventory.reserve(locale: locale)
    }
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
      try await request.downloadAndInstall()
    }
  }
}

private final class DictationCapture: @unchecked Sendable {
  private let engine = AVAudioEngine()
  private let continuation: AsyncStream<AnalyzerInput>.Continuation

  init(format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) throws {
    self.continuation = continuation
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.record, mode: .measurement, options: .duckOthers)
      try session.setActive(true, options: .notifyOthersOnDeactivation)
      let source = engine.inputNode.outputFormat(forBus: 0)
      guard source.sampleRate > 0, let converter = DictationConverter(from: source, to: format) else { throw ComposerDictationError.unavailable }
      engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: source, block: Self.tap(converter, continuation))
      engine.prepare()
      try engine.start()
    } catch {
      stop()
      throw error
    }
  }

  // Built outside any actor: the audio thread calls this block, and a closure formed in main-actor code traps there.
  private static func tap(_ converter: DictationConverter, _ continuation: AsyncStream<AnalyzerInput>.Continuation) -> AVAudioNodeTapBlock {
    { buffer, _ in
      guard let converted = converter.convert(buffer) else { return }
      continuation.yield(AnalyzerInput(buffer: converted))
    }
  }

  func stop() {
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    continuation.finish()
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }
}

private final class DictationConverter: @unchecked Sendable {
  private let converter: AVAudioConverter
  private let format: AVAudioFormat

  init?(from source: AVAudioFormat, to format: AVAudioFormat) {
    guard let converter = AVAudioConverter(from: source, to: format) else { return nil }
    // Priming pads the first buffer, which shifts every later result's audio time.
    converter.primeMethod = .none
    self.converter = converter
    self.format = format
  }

  func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    let capacity = AVAudioFrameCount((Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate).rounded(.up))
    guard capacity > 0, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
    nonisolated(unsafe) var consumed = false
    var failure: NSError?
    let status = converter.convert(to: output, error: &failure) { _, inputStatus in
      if consumed {
        inputStatus.pointee = .noDataNow
        return nil
      }
      consumed = true
      inputStatus.pointee = .haveData
      return buffer
    }
    if status == .error || output.frameLength == 0 { return nil }
    return output
  }
}
