/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import Lexical
@testable import LexicalListPlugin
import UIKit
import XCTest

final class ListItemNodeTests: XCTestCase {
  var view: LexicalView?

  var editor: Editor? {
    get {
      return view?.editor
    }
  }

  override func setUp() {
    view = LexicalView(editorConfig: EditorConfig(theme: Theme(), plugins: []), featureFlags: FeatureFlags())
  }

  override func tearDown() {
    view = nil
  }

  func testItemCharacterWithNestedNumberedList() throws {
    guard let editor else {
      XCTFail("Editor unexpectedly nil")
      return
    }

    try editor.update {
      guard
        let editorState = getActiveEditorState(),
        let rootNode = editorState.getRootNode()
      else {
        XCTFail("should have editor state")
        return
      }

      /*
       1. Item 1
       1. Nested item 1
       2. Nested item 2
       2. Item 2
       */

      // Root level
      let list = ListNode(listType: .number, start: 1)

      let item1 = ListItemNode()
      try item1.append([TextNode(text: "Item 1")])

      let item2 = ListItemNode()
      try item2.append([TextNode(text: "Item 2")])

      // Nested level
      let nestedList = ListNode(listType: .number, start: 1)

      let nestedListItem = ListItemNode()
      try nestedListItem.append([nestedList])

      let nestedItem1 = ListItemNode()
      try nestedItem1.append([TextNode(text: "Nested item 1")])

      let nestedItem2 = ListItemNode()
      try nestedItem2.append([TextNode(text: "Nested item 2")])

      try nestedList.append([nestedItem1, nestedItem2])

      // Putting it together
      try list.append([item1, nestedListItem, item2])
      try rootNode.append([list])

      // Assertions
      let theme = editor.getTheme()

      let item1Attrs = item1.getAttributedStringAttributes(theme: theme)[.listItem] as? ListItemAttribute
      XCTAssertEqual(item1Attrs?.listItemCharacter, "1.")

      let item2Attrs = item2.getAttributedStringAttributes(theme: theme)[.listItem] as? ListItemAttribute
      XCTAssertEqual(item2Attrs?.listItemCharacter, "2.")

      let nestedItem1Attrs = nestedItem1.getAttributedStringAttributes(theme: theme)[.listItem] as? ListItemAttribute
      XCTAssertEqual(nestedItem1Attrs?.listItemCharacter, "1.")

      let nestedItem2Attrs = nestedItem2.getAttributedStringAttributes(theme: theme)[.listItem] as? ListItemAttribute
      XCTAssertEqual(nestedItem2Attrs?.listItemCharacter, "2.")
    }
  }

  private func makeRenderedListView(indentSize: Double = 22.0) -> (LexicalView, UIWindow) {
    let theme = Theme()
    theme.indentSize = indentSize
    theme.root = [.font: UIFont.systemFont(ofSize: 17), .foregroundColor: UIColor.black]
    let view = LexicalView(editorConfig: EditorConfig(theme: theme, plugins: [ListPlugin()]), featureFlags: FeatureFlags())
    view.textView.backgroundColor = .white
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
    view.frame = window.bounds
    window.addSubview(view)
    window.isHidden = false
    view.layoutIfNeeded()
    return (view, window)
  }

  private func hasDarkInk(in textView: TextView, rect: CGRect) -> Bool {
    let image = UIGraphicsImageRenderer(bounds: textView.bounds).image { context in
      textView.layer.render(in: context.cgContext)
    }
    guard let cgImage = image.cgImage else { return false }
    let scale = image.scale
    let pixelRect = CGRect(
      x: max(0, floor(rect.minX * scale)),
      y: max(0, floor(rect.minY * scale)),
      width: max(1, ceil(rect.width * scale)),
      height: max(1, ceil(rect.height * scale))
    ).intersection(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
    guard !pixelRect.isEmpty, let cropped = cgImage.cropping(to: pixelRect) else { return false }
    let width = cropped.width
    let height = cropped.height
    var data = [UInt8](repeating: 255, count: width * height * 4)
    let context = CGContext(
      data: &data,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
    context?.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
    for i in stride(from: 0, to: data.count, by: 4) {
      let avg = (Int(data[i]) + Int(data[i + 1]) + Int(data[i + 2])) / 3
      if avg < 200 {
        return true
      }
    }
    return false
  }

  func testEmptyTrailingListItemAndMarkedTextDrawBullet() throws {
    let (view, _) = makeRenderedListView(indentSize: 22.0)
    let textView = view.textView

    // Paragraph followed by an empty bullet list item at end of document.
    try view.editor.update {
      guard let root = getRoot() else { return }
      let intro = createParagraphNode()
      try intro.append([createTextNode(text: "Intro")])
      let list = createListNode(listType: .bullet)
      let emptyItem = ListItemNode()
      try list.append([emptyItem])
      try root.getChildren().forEach { try $0.remove() }
      try root.append([intro, list])
      _ = try emptyItem.selectStart()
    }
    view.layoutIfNeeded()

    guard let tlm = textView.textLayoutManager else {
      return XCTFail("Expected TextKit 2 layout manager")
    }
    var lastFrame: CGRect = .zero
    tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { fragment in
      lastFrame = fragment.layoutFragmentFrame
      return true
    }
    let inset = textView.textContainerInset
    let padding = textView.textContainer.lineFragmentPadding
    // Bullet sits at indent 8pt (22 - 14), inside the gutter before text at 22pt.
    let bulletProbe = CGRect(
      x: inset.left + padding + 4,
      y: inset.top + lastFrame.minY,
      width: 12,
      height: max(lastFrame.height, 20)
    )
    XCTAssertTrue(
      hasDarkInk(in: textView, rect: bulletProbe),
      "Empty trailing ListItemNode must draw its bullet marker immediately"
    )

    // Typing with CJK IME (markedText) must keep the bullet visible before commit.
    textView.becomeFirstResponder()
    textView.setMarkedText("diyi", selectedRange: NSRange(location: 4, length: 0))
    view.layoutIfNeeded()
    XCTAssertTrue(
      hasDarkInk(in: textView, rect: bulletProbe),
      "ListItemNode bullet must stay visible during IME markedText composition"
    )

    // Non-final ListItemNode with active markedText (followed by "\n" and an empty trailing
    // ListItemNode on an extraLineFragment) must draw bullets on BOTH lines.
    var middleItem: ListItemNode!
    try view.editor.update {
      guard let root = getRoot() else { return }
      let list = createListNode(listType: .bullet)
      let first = ListItemNode()
      try first.append([createTextNode(text: "First")])
      let mid = ListItemNode()
      middleItem = mid
      let trailingEmpty = ListItemNode()
      try list.append([first, mid, trailingEmpty])
      try root.getChildren().forEach { try $0.remove() }
      try root.append([list])
      _ = try middleItem.selectStart()
    }
    textView.setMarkedText("dier", selectedRange: NSRange(location: 4, length: 0))
    view.layoutIfNeeded()

    var fragments: [NSTextLayoutFragment] = []
    tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { fragment in
      fragments.append(fragment)
      return true
    }
    guard let lastFragment = fragments.last, lastFragment.textLineFragments.count >= 2 else {
      return XCTFail("Expected markedText line plus trailing extraLineFragment")
    }
    let markedLineBounds = lastFragment.textLineFragments[0].typographicBounds
    let extraLineBounds = lastFragment.textLineFragments[lastFragment.textLineFragments.count - 1].typographicBounds
    let markedProbe = CGRect(
      x: inset.left + padding + 4,
      y: inset.top + lastFragment.layoutFragmentFrame.minY + markedLineBounds.minY,
      width: 12,
      height: max(markedLineBounds.height, 20)
    )
    let extraProbe = CGRect(
      x: inset.left + padding + 4,
      y: inset.top + lastFragment.layoutFragmentFrame.minY + extraLineBounds.minY,
      width: 12,
      height: max(extraLineBounds.height, 20)
    )
    XCTAssertTrue(
      hasDarkInk(in: textView, rect: markedProbe),
      "Non-final ListItemNode must draw bullet during IME markedText even when followed by newline"
    )
    XCTAssertTrue(
      hasDarkInk(in: textView, rect: extraProbe),
      "Empty trailing ListItemNode on TextKit 2 extraLineFragment must draw its bullet"
    )
  }

  func testReturnOnEmptyListItemExitsList() throws {
    let (view, _) = makeRenderedListView()
    let textView = view.textView

    try view.editor.update {
      guard let root = getRoot() else { return }
      let list = createListNode(listType: .bullet)
      let item1 = ListItemNode()
      try item1.append([createTextNode(text: "First")])
      try list.append([item1])
      try root.getChildren().forEach { try $0.remove() }
      try root.append([list])
      _ = try item1.selectEnd()
    }

    // First Return creates an empty second ListItemNode.
    textView.insertText("\n")
    try view.editor.read {
      let list = getRoot()?.getFirstChild() as? ListNode
      XCTAssertEqual(list?.getChildrenSize(), 2)
    }

    // Second Return on the empty ListItemNode exits the list into a ParagraphNode.
    textView.insertText("\n")
    try view.editor.read {
      let blocks = getRoot()?.getChildren() ?? []
      XCTAssertEqual(blocks.count, 2)
      XCTAssertTrue(blocks[0] is ListNode)
      XCTAssertEqual((blocks[0] as? ListNode)?.getChildrenSize(), 1)
      XCTAssertTrue(blocks[1] is ParagraphNode)
    }
  }

  func testBackspaceAtStartOfFirstListItemConvertsToParagraph() throws {
    let (view, _) = makeRenderedListView()
    let textView = view.textView

    try view.editor.update {
      guard let root = getRoot() else { return }
      let list = createListNode(listType: .bullet)
      let item1 = ListItemNode()
      try item1.append([createTextNode(text: "First")])
      let item2 = ListItemNode()
      try item2.append([createTextNode(text: "Second")])
      try list.append([item1, item2])
      try root.getChildren().forEach { try $0.remove() }
      try root.append([list])
      _ = try item1.selectStart()
    }

    textView.deleteBackward()
    try view.editor.read {
      let blocks = getRoot()?.getChildren() ?? []
      XCTAssertEqual(blocks.count, 2)
      XCTAssertTrue(blocks[0] is ParagraphNode)
      XCTAssertEqual(blocks[0].getTextContent().trimmingCharacters(in: .newlines), "First")
      XCTAssertTrue(blocks[1] is ListNode)
      XCTAssertEqual(blocks[1].getTextContent().trimmingCharacters(in: .newlines), "Second")
    }
  }

  func testBulletIndentUsesCompactGutter() throws {
    let (view, _) = makeRenderedListView(indentSize: 22.0)
    try view.editor.update {
      guard let root = getRoot() else { return }
      let list = createListNode(listType: .bullet)
      let item = ListItemNode()
      try item.append([createTextNode(text: "Item")])
      try list.append([item])
      try root.getChildren().forEach { try $0.remove() }
      try root.append([list])

      let attrs = item.getAttributedStringAttributes(theme: view.editor.getTheme())
      let listAttr = attrs[.listItem] as? ListItemAttribute
      XCTAssertEqual(listAttr?.characterIndentationPixels, 8.0)
    }
  }
}
