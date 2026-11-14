import Foundation
import LodyCore

/// `--ui-verify --ui-verify-dictation` stands in for SpeechTranscriber, which the Simulator lacks.
/// It speaks a fixed script, then waits for Stop to deliver the final result.
@MainActor
final class DictationFixture: ComposerDictating {
  static let engine: ComposerDictating? = LodyUIVerify.enabled && LodyUIVerify.has("--ui-verify-dictation") ? DictationFixture() : nil

  private static let script = ["Check", "Check the", "Check the failing", "Check the failing build log"]
  private var session: Task<Void, Never>?

  func start(language: String?, onEvent: @escaping @MainActor (DictationEvent) -> Void) {
    session?.cancel()
    session = Task {
      var spoken = ""
      do {
        try await Task.sleep(for: .milliseconds(400))
        onEvent(.listening)
        for step in Self.script {
          try await Task.sleep(for: .milliseconds(400))
          spoken = step
          onEvent(.text(step, isFinal: false))
        }
        try await Task.sleep(for: .seconds(3600))
      } catch {}
      if !spoken.isEmpty { onEvent(.text(spoken + ".", isFinal: true)) }
      onEvent(.ended(nil))
    }
  }

  func stop() { session?.cancel() }
}
