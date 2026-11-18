import ChatKit
import LodyCore
import UIKit

@MainActor enum PromptShortcutsController {
  static func body(id: String) async throws -> RuntimeContract.PromptShortcut {
    throw NSError(domain: "ComposerOfflineFixture", code: 1)
  }
}

@MainActor func descendants(_ view: UIView) -> [UIView] {
  [view] + view.subviews.flatMap(descendants)
}

let ready = #"{"editable":true,"canSend":true,"sending":false,"notice":"","reconnect":false,"placeholder":"任务"}"#

@MainActor func makeRichComposer() -> (ChatComposerView, ChatComposerInput) {
  let composer = ChatComposerView(frame: CGRect(x: 0, y: 0, width: 390, height: 64))
  let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
  window.addSubview(composer)
  window.isHidden = false
  composer.setComposerState(ready)
  composer.layoutIfNeeded()
  let input = descendants(composer).compactMap { $0 as? ChatComposerInput }.first!
  precondition(input.becomeFirstResponder())
  return (composer, input)
}
@MainActor func typeInto(_ input: ChatComposerInput, _ text: String) {
  for character in text { input.insertText(String(character)) }
}
@MainActor func tapSend(on composer: ChatComposerView) {
  let button = descendants(composer).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "session-send" }!
  for action in button.actions(forTarget: composer, forControlEvent: .touchUpInside) ?? [] {
    composer.perform(NSSelectorFromString(action))
  }
}


func composerLabel(_ key: String) -> String { String(localized: String.LocalizationValue(key), bundle: .lody) }

@MainActor final class FakeDictation: ComposerDictating {
  var language: String?
  var starts = 0
  var stops = 0
  var emit: (@MainActor (DictationEvent) -> Void)?

  func start(language: String?, onEvent: @escaping @MainActor (DictationEvent) -> Void) {
    starts += 1
    self.language = language
    emit = onEvent
  }

  func stop() { stops += 1 }
}

@MainActor func makeDictatingComposer() -> (ChatComposerView, ChatComposerInput, FakeDictation, UIButton) {
  let (composer, input) = makeRichComposer()
  let engine = FakeDictation()
  composer.dictation = engine
  let button = descendants(composer).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "session-send" }!
  return (composer, input, engine, button)
}

do {
  let (plain, _) = makeRichComposer()
  let plainButton = descendants(plain).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "session-send" }!
  precondition(!plainButton.isEnabled && plainButton.accessibilityLabel == composerLabel("native.chat.composer.send"), "Without an engine the empty composer keeps a disabled Send, got \(plainButton.isEnabled) \(plainButton.accessibilityLabel ?? "nil")")

  let (composer, input, engine, button) = makeDictatingComposer()
  var dictationSent: [String] = []
  composer.onSend = { dictationSent.append($0["text"] as! String) }
  precondition(button.isEnabled && button.accessibilityLabel == composerLabel("native.chat.composer.dictate"), "An empty composer offers Dictate, got \(button.accessibilityLabel ?? "")")
  tapSend(on: composer)
  precondition(engine.starts == 1 && dictationSent.isEmpty, "Dictate must start the engine without sending")
  engine.emit?(.listening)
  precondition(button.accessibilityLabel == composerLabel("native.chat.composer.stopDictation") && button.isEnabled, "Listening shows Stop Dictation")
  engine.emit?(.text("Check", isFinal: false))
  engine.emit?(.text("Check the", isFinal: false))
  precondition(input.text == "Check the", "Volatile results replace each other, got \(input.text ?? "")")
  engine.emit?(.text("Check the build. ", isFinal: true))
  engine.emit?(.text("Then", isFinal: false))
  precondition(input.text == "Check the build. Then", "Final results accumulate, got \(input.text ?? "")")
  tapSend(on: composer)
  precondition(engine.stops == 1 && dictationSent.isEmpty, "Tapping while listening stops without sending")
  engine.emit?(.text("Then ship.", isFinal: true))
  engine.emit?(.ended(nil))
  precondition(input.text == "Check the build. Then ship.", "Results after Stop still land, got \(input.text ?? "")")
  precondition(button.accessibilityLabel == composerLabel("native.chat.composer.send"), "Dictated text turns the action back into Send")
  tapSend(on: composer)
  precondition(dictationSent == ["Check the build. Then ship."], "Dictated text sends as typed text, got \(dictationSent)")
}

do {
  let (composer, input, engine, button) = makeDictatingComposer()
  tapSend(on: composer)
  engine.emit?(.listening)
  engine.emit?(.text("Coffee", isFinal: false))
  typeInto(input, "!")
  precondition(engine.stops == 1, "Typing during dictation ends it")
  engine.emit?(.text("Coffee shop", isFinal: true))
  precondition(input.text == "Coffee!", "Results after typing are ignored, got \(input.text ?? "")")
  precondition(button.accessibilityLabel == composerLabel("native.chat.composer.send"))

  let (failing, _, failingEngine, failingButton) = makeDictatingComposer()
  tapSend(on: failing)
  failingEngine.emit?(.ended(ComposerDictationError.microphoneDenied))
  LodyToastOverlay.shared.dismiss()
  precondition(failingButton.accessibilityLabel == composerLabel("native.chat.composer.dictate"), "A failed session returns to Dictate")
  tapSend(on: failing)
  precondition(failingEngine.starts == 2)

  let (locked, _, lockedEngine, _) = makeDictatingComposer()
  tapSend(on: locked)
  lockedEngine.emit?(.listening)
  locked.setComposerState(#"{"editable":false,"canSend":true,"sending":false,"notice":"","reconnect":false,"placeholder":"任务"}"#)
  precondition(lockedEngine.stops == 1, "A composer that stops being editable ends dictation")

  let (running, _, runningEngine, runningButton) = makeDictatingComposer()
  running.setComposerState(#"{"editable":true,"canSend":true,"sending":false,"running":true,"canStop":true,"notice":"","reconnect":false,"placeholder":"任务"}"#)
  precondition(runningButton.accessibilityIdentifier == "session-stop", "A running turn keeps Stop over Dictate")
  precondition(runningEngine.starts == 0)
}

do {
  let (spaced, spacedInput, spacedEngine, _) = makeDictatingComposer()
  typeInto(spacedInput, "  ")
  tapSend(on: spaced)
  spacedEngine.emit?(.text("拉面", isFinal: false))
  precondition(spacedInput.text == "拉面", "Whitespace left in an empty draft is replaced, got \(spacedInput.text ?? "")")
  precondition(ComposerDictationLanguage.resolve(keyboard: "ja-JP", preferred: ["en-US"]) == "ja-JP")
  precondition(ComposerDictationLanguage.resolve(keyboard: "emoji", preferred: ["zh-Hans-CN"]) == "zh-Hans-CN")
  precondition(ComposerDictationLanguage.resolve(keyboard: nil, preferred: ["en-US"]) == "en-US")
}
do {
  let (composer, _, engine, _) = makeDictatingComposer()
  var saved: [String] = []
  composer.onDraftChange = { saved.append($0) }
  tapSend(on: composer)
  engine.emit?(.listening)
  engine.emit?(.text("Dictated draft survives", isFinal: true))
  RunLoop.main.run(until: Date().addingTimeInterval(0.8))
  precondition(saved.last?.contains("Dictated draft survives") == true, "Dictated text must autosave like typing, got \(saved)")
}
print("Composer dictation: offer, volatile/final results, stop, typing, failure, lock, running, whitespace and language passed")
