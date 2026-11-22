import Lexical
import UIKit

enum DictationEvent {
  case listening
  case text(String, isFinal: Bool)
  case ended(Error?)
}

@MainActor
protocol ComposerDictating: AnyObject {
  func start(language: String?, onEvent: @escaping @MainActor (DictationEvent) -> Void)
  func stop()
}

enum ComposerDictationError: LocalizedError {
  case microphoneDenied, unsupportedLanguage, unavailable

  var errorDescription: String? {
    switch self {
    case .microphoneDenied: String(localized: "native.chat.dictation.microphoneDenied", bundle: .lody)
    case .unsupportedLanguage: String(localized: "native.chat.dictation.unsupportedLanguage", bundle: .lody)
    case .unavailable: String(localized: "native.chat.dictation.failed", bundle: .lody)
    }
  }
}

enum ComposerDictationLanguage {
  static func resolve(keyboard: String?, preferred: [String]) -> String? {
    if let keyboard, Locale.Language(identifier: keyboard).languageCode?.isISOLanguage == true { return keyboard }
    return preferred.first
  }
}

struct DictationSpan {
  let location: Int
  private(set) var length: Int
  private var finalized = ""
  private var volatile = ""

  init(location: Int, replacing length: Int) {
    self.location = location
    self.length = length
  }

  var range: NSRange { NSRange(location: location, length: length) }
  var inserted: String { finalized + volatile }

  mutating func apply(_ text: String, isFinal: Bool) -> String {
    if isFinal {
      finalized += text
      volatile = ""
    } else {
      volatile = text
    }
    return inserted
  }

  mutating func commit(_ inserted: String) {
    length = (inserted as NSString).length
  }
}

@MainActor
final class ComposerDictator {
  enum State {
    case idle, preparing, listening, finishing
  }

  static var defaultEngine: ComposerDictating?

  var engine: ComposerDictating? = ComposerDictator.defaultEngine
  private(set) var state = State.idle
  private weak var input: ChatComposerInput?
  private let onChange: () -> Void
  private var span: DictationSpan?
  private var session = 0
  private let feedback = UIImpactFeedbackGenerator(style: .light)

  init(input: ChatComposerInput, onChange: @escaping () -> Void) {
    self.input = input
    self.onChange = onChange
  }

  var isActive: Bool { state != .idle }
  var isAvailable: Bool { engine != nil }

  // Dictation only starts from an empty draft, so whitespace left in it is replaced by the spoken text.
  func start() {
    guard let input, let engine, state == .idle, input.isEditable else { return }
    input.unmarkText()
    span = DictationSpan(location: 0, replacing: (input.text as NSString).length)
    session += 1
    let current = session
    state = .preparing
    feedback.impactOccurred()
    onChange()
    let language = ComposerDictationLanguage.resolve(keyboard: input.textInputMode?.primaryLanguage, preferred: Locale.preferredLanguages)
    engine.start(language: language) { [weak self] event in
      guard let self, session == current else { return }
      handle(event)
    }
  }

  // Results already spoken keep arriving after Stop and still land in the draft.
  func stop() {
    guard state == .preparing || state == .listening else { return }
    state = .finishing
    engine?.stop()
    onChange()
  }

  func cancel() {
    guard state != .idle else { return }
    session += 1
    state = .idle
    span = nil
    engine?.stop()
    onChange()
  }

  private func handle(_ event: DictationEvent) {
    switch event {
    case .listening:
      if state == .preparing { state = .listening }
      onChange()
    case .text(let text, let isFinal):
      write(text, isFinal: isFinal)
    case .ended(let error):
      state = .idle
      span = nil
      onChange()
      guard let error else { return }
      let message = (error as? LocalizedError)?.errorDescription ?? ComposerDictationError.unavailable.errorDescription
      LodyToastOverlay.shared.show(message: message ?? "", kind: .error)
    }
  }

  private func write(_ text: String, isFinal: Bool) {
    guard let input, var span else { return }
    let replaced = span.range
    let inserted = span.apply(text, isFinal: isFinal)
    guard replaced.length > 0 || !inserted.isEmpty,
      input.delegate?.textView?(input, shouldChangeTextIn: replaced, replacementText: inserted) != false
    else { return }
    input.selectedRange = replaced
    try? input.editor.update {
      guard let selection = try getSelection() as? RangeSelection else { return }
      try selection.insertText(inserted)
    }
    span.commit(inserted)
    self.span = span
    let caret = NSRange(location: NSMaxRange(span.range), length: 0)
    input.selectedRange = caret
    input.scrollRangeToVisible(caret)
    onChange()
  }
}
