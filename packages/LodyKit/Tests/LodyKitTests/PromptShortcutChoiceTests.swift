import Foundation
import LodyCore
import UIKit
import XCTest
@testable import LodyKit

/// Choosing a prompt shortcut from the composer's `/` list: its trigger leaves at once, and a body
/// that arrives late never overwrites what was typed after the choice.
@MainActor
final class PromptShortcutChoiceTests: XCTestCase {
  private final class Reads {
    var holding = false
    var held: [CheckedContinuation<RuntimeContract.PromptShortcut, Error>] = []

    func release(_ body: RuntimeContract.PromptShortcut) {
      let waiting = held
      held = []
      for read in waiting { read.resume(returning: body) }
    }
  }

  private let item = ChatMentionItem(path: "review", name: "/shortcut:review", kind: "cmd", subtitle: "Review", insertText: "/shortcut:review", revision: "r1")
  private let body = try! JSONDecoder().decode(RuntimeContract.PromptShortcut.self, from: Data(#"""
  {"v":1,"id":"review","workspaceId":"w","ownerUserId":"u","name":"Review","slug":"review","scope":{},
   "revision":"r1","createdAt":1,"updatedAt":1,"prompt":"Review the diff\nthen summarise","mentions":[]}
  """#.utf8))
  private var window: UIWindow!

  override func tearDown() async throws {
    window?.isHidden = true
    window = nil
  }

  private func composer(_ reads: Reads) -> (ChatComposerInput, ChatMentionPanel) {
    window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    let editor = ChatComposerInput.makeEditorView()
    editor.frame = CGRect(x: 0, y: 400, width: 390, height: 120)
    let input = editor.textView as! ChatComposerInput
    let panel = ChatMentionPanel(frame: CGRect(x: 0, y: 120, width: 390, height: 280))
    window.addSubview(editor)
    window.addSubview(panel)
    window.makeKeyAndVisible()
    XCTAssertTrue(input.becomeFirstResponder())
    let body = body
    panel.loadShortcut = { _ in
      guard reads.holding else { return body }
      return try await withCheckedThrowingContinuation { reads.held.append($0) }
    }
    panel.onChange = { [unowned self] in panel.update(input: input, items: [self.listed]) }
    return (input, panel)
  }

  /// The shortcut as the catalog currently lists it.
  private lazy var listed = item

  private func type(_ text: String, into input: ChatComposerInput, panel: ChatMentionPanel) {
    for character in text {
      input.insertText(String(character))
      panel.update(input: input, items: [listed])
    }
  }

  private func settle(until done: () -> Bool = { false }) async {
    for _ in 0..<100 where !done() { await Task.yield() }
  }

  func testChoiceClearsTheTriggerAtOnceAndKeepsLaterTyping() async {
    let reads = Reads()
    reads.holding = true
    let (input, panel) = composer(reads)
    type("please", into: input, panel: panel)
    input.selectedRange = NSRange(location: 0, length: 0)
    type("/rev", into: input, panel: panel)
    XCTAssertTrue(panel.showing)

    panel.choose(item)
    XCTAssertEqual(input.text, "Review please")
    XCTAssertEqual(input.referenceTokens, ["Review"])
    XCTAssertEqual(input.markdown, "/shortcut:review please")
    XCTAssertFalse(panel.showing)
    await settle { !reads.held.isEmpty }
    XCTAssertEqual(reads.held.count, 1)

    type("now ", into: input, panel: panel)
    reads.release(body)
    await settle { input.referenceTokens.isEmpty }
    let typed = "Review the diff\nthen summarise now "
    XCTAssertEqual(input.text, typed + "please")
    XCTAssertEqual(input.labelledReferences, [:])
    XCTAssertEqual(input.selectedRange, NSRange(location: (typed as NSString).length, length: 0))
  }

  func testLateBodyNeverRevivesADeletedChip() async {
    let reads = Reads()
    reads.holding = true
    let (input, panel) = composer(reads)
    type("/rev", into: input, panel: panel)
    panel.choose(item)
    await settle { !reads.held.isEmpty }
    input.deleteBackward()
    input.deleteBackward()
    XCTAssertEqual(input.text, "")
    type("other", into: input, panel: panel)

    XCTAssertEqual(reads.held.count, 1)
    reads.release(body)
    await settle()
    XCTAssertEqual(input.text, "other")
  }

  func testListedShortcutWritesItsBodyAtOnce() async {
    let (input, panel) = composer(Reads())
    type("/re", into: input, panel: panel)
    await settle()

    panel.choose(item)
    XCTAssertEqual(input.text, "Review the diff\nthen summarise ")
    XCTAssertEqual(input.selectedRange, NSRange(location: (input.text! as NSString).length, length: 0))
  }

  func testBodyReadAheadIsNotReusedForAnEditedShortcut() async {
    let reads = Reads()
    let (input, panel) = composer(reads)
    type("/re", into: input, panel: panel)
    await settle()

    // Another device saved revision r2 while the panel was open; the r1 body must not go in.
    listed = ChatMentionItem(path: "review", name: "/shortcut:review", kind: "cmd", subtitle: "Review", insertText: "/shortcut:review", revision: "r2")
    reads.holding = true
    panel.update(input: input, items: [listed])
    panel.choose(listed)
    XCTAssertEqual(input.text, "Review ")
    XCTAssertEqual(input.markdown, "/shortcut:review ")
  }
}
