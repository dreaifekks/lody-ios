import CoreGraphics
import ImageIO
import LodyCore
import UIKit
import XCTest
@testable import LodyKit

@MainActor
final class ChatShareImageTests: XCTestCase {
  func testSelectionPreservesChronologicalOrderAndHandlesOlderPages() {
    let payload = RuntimeContract.ConversationShareMessagesResultReady(
      title: "Architecture review",
      createdAt: "2026-11-26T02:00:00.000Z",
      cliType: "builtin",
      agentType: "claude",
      messages: [
        .init(id: "older-u0", role: .user, text: "Earlier prompt", estimatedTokens: 25),
        .init(id: "older-a0", role: .assistant, text: "Earlier answer", estimatedTokens: 75, modelName: "Claude Haiku"),
        .init(id: "u1", role: .user, text: "First loaded prompt", estimatedTokens: 40),
        .init(id: "a1", role: .assistant, text: "First loaded reply", estimatedTokens: 120, modelName: "Claude Sonnet 4.5", userTurnId: "u1"),
        .init(id: "u2", role: .user, text: "Second loaded prompt", estimatedTokens: 30),
        .init(id: "a2", role: .assistant, text: "Second loaded reply", estimatedTokens: 200, modelName: "Claude Opus 4", userTurnId: "u2"),
      ]
    )

    var session = ChatShareSelectionSession(
      userId: "user-1",
      workspaceId: "ws-1",
      sessionId: "sess-1",
      payload: payload
    )

    var loaded: Set<String> = ["u1", "a1", "u2", "a2", "tool-only-turn"]
    XCTAssertEqual(session.selectableEntryIDs(loadedEntryIDs: loaded), ["u1", "a1", "u2", "a2"])
    XCTAssertFalse(session.toggleEntry("older-u0", loadedEntryIDs: loaded))
    XCTAssertFalse(session.toggleEntry("tool-only-turn", loadedEntryIDs: loaded))

    // Tap in reverse/non-contiguous order; ordered output stays chronological.
    XCTAssertTrue(session.toggleEntry("a2", loadedEntryIDs: loaded))
    XCTAssertTrue(session.toggleEntry("u1", loadedEntryIDs: loaded))
    XCTAssertTrue(session.toggleEntry("a1", loadedEntryIDs: loaded))
    XCTAssertEqual(session.orderedSelectedMessages(loadedEntryIDs: loaded).map(\.id), ["u1", "a1", "a2"])
    XCTAssertFalse(session.areAllLoadedSelected(loadedEntryIDs: loaded))

    // Select all selects all currently loaded selectable turns.
    session.toggleSelectAll(loadedEntryIDs: loaded)
    XCTAssertTrue(session.areAllLoadedSelected(loadedEntryIDs: loaded))
    XCTAssertEqual(session.orderedSelectedMessages(loadedEntryIDs: loaded).map(\.id), ["u1", "a1", "u2", "a2"])

    // Older history page arrives: newly loaded turns become selectable and Select all covers them.
    loaded.formUnion(["older-u0", "older-a0"])
    XCTAssertFalse(session.areAllLoadedSelected(loadedEntryIDs: loaded))
    session.toggleSelectAll(loadedEntryIDs: loaded)
    XCTAssertTrue(session.areAllLoadedSelected(loadedEntryIDs: loaded))
    XCTAssertEqual(
      session.orderedSelectedMessages(loadedEntryIDs: loaded).map(\.id),
      ["older-u0", "older-a0", "u1", "a1", "u2", "a2"]
    )

    // Clear selection clears all loaded selectable turns.
    session.toggleSelectAll(loadedEntryIDs: loaded)
    XCTAssertTrue(session.orderedSelectedMessages(loadedEntryIDs: loaded).isEmpty)
  }

  func testVerticalGapDistinguishesReplyFromExchangeAndChecksUserTurnId() {
    let messages: [RuntimeContract.ConversationShareMessage] = [
      .init(id: "u1", role: .user, text: "Question 1", estimatedTokens: 10),
      .init(id: "a1", role: .assistant, text: "Answer 1", estimatedTokens: 20, userTurnId: "u1"),
      .init(id: "u2", role: .user, text: "Question 2", estimatedTokens: 10),
      // Selected without u3, so its userTurnId ("u3") does not match previous ("u2").
      .init(id: "a3", role: .assistant, text: "Answer 3", estimatedTokens: 20, userTurnId: "u3"),
      .init(id: "u4", role: .user, text: "Question 4", estimatedTokens: 10),
      // Legacy turn without userTurnId binds to immediately preceding user prompt.
      .init(id: "a4", role: .assistant, text: "Answer 4", estimatedTokens: 20, userTurnId: nil),
      .init(id: "a5", role: .assistant, text: "Follow-up assistant", estimatedTokens: 20, userTurnId: nil),
    ]

    XCTAssertEqual(ChatShareCardFormatting.verticalGap(at: 0, in: messages, destination: .chat), 0)
    XCTAssertEqual(ChatShareCardFormatting.verticalGap(at: 1, in: messages, destination: .chat), 12)
    XCTAssertEqual(ChatShareCardFormatting.verticalGap(at: 2, in: messages, destination: .chat), 24)
    XCTAssertEqual(ChatShareCardFormatting.verticalGap(at: 3, in: messages, destination: .chat), 24)
    XCTAssertEqual(ChatShareCardFormatting.verticalGap(at: 5, in: messages, destination: .chat), 12)
    XCTAssertEqual(ChatShareCardFormatting.verticalGap(at: 6, in: messages, destination: .chat), 24)

    XCTAssertEqual(ChatShareCardFormatting.verticalGap(at: 1, in: messages, destination: .post), 14)
    XCTAssertEqual(ChatShareCardFormatting.verticalGap(at: 3, in: messages, destination: .post), 28)
  }

  func testMetadataExtractionCompactTokensDateAndSignOffPlacement() {
    XCTAssertEqual(ChatShareCardFormatting.compactTokens(420), "420")
    XCTAssertEqual(ChatShareCardFormatting.compactTokens(1_000), "1k")
    XCTAssertEqual(ChatShareCardFormatting.compactTokens(1_240), "1.2k")
    XCTAssertEqual(ChatShareCardFormatting.compactTokens(12_300), "12k")
    XCTAssertEqual(ChatShareCardFormatting.compactTokens(1_200_000), "1.2M")
    XCTAssertEqual(ChatShareCardFormatting.compactTokens(15_400_000), "15M")

    let allMessages: [RuntimeContract.ConversationShareMessage] = [
      .init(id: "u1", role: .user, text: "Prompt", estimatedTokens: 400),
      .init(id: "a1", role: .assistant, text: "Reply 1", estimatedTokens: 800, modelName: "Claude Sonnet 4.5"),
      .init(id: "a2", role: .assistant, text: "Reply 2 without model", estimatedTokens: 50, modelName: "  "),
      .init(id: "a3", role: .assistant, text: "Unselected reply", estimatedTokens: 5_000, modelName: "GPT-5"),
    ]
    let payload = RuntimeContract.ConversationShareMessagesResultReady(
      title: "Token & model check",
      createdAt: "2026-11-26T02:05:00.000Z",
      cliType: "builtin",
      agentType: "claude",
      agentName: nil,
      messages: allMessages
    )

    let selected = ChatShareCardFormatting.orderedMessages(from: allMessages, selectedIDs: ["u1", "a1", "a2"])
    let utc = TimeZone(secondsFromGMT: 0)!
    let meta = ChatShareCardFormatting.makeMeta(from: payload, selectedMessages: selected, timeZone: utc)
    XCTAssertEqual(meta.name, "Claude Code")
    XCTAssertEqual(meta.params.first, "Claude Sonnet 4.5")
    XCTAssertEqual(meta.params.count, 2)
    XCTAssertTrue(meta.params[1].contains("1.3k"))
    XCTAssertEqual(meta.date, "2026-11-26 02:05")

    var customPayload = payload
    customPayload.cliType = "custom"
    customPayload.agentName = "Internal Runner"
    let customMeta = ChatShareCardFormatting.makeMeta(from: customPayload, selectedMessages: selected, timeZone: utc)
    XCTAssertEqual(customMeta.name, "Internal Runner")

    var fallbackPayload = payload
    fallbackPayload.cliType = nil
    fallbackPayload.agentType = nil
    let fallbackMeta = ChatShareCardFormatting.makeMeta(from: fallbackPayload, selectedMessages: selected, timeZone: utc)
    XCTAssertEqual(fallbackMeta.name, "Lody")

    XCTAssertFalse(ChatShareCardFormatting.signOffOnMat(backdrop: .none, mat: 56))
    XCTAssertFalse(ChatShareCardFormatting.signOffOnMat(backdrop: .lody, mat: 8))
    XCTAssertTrue(ChatShareCardFormatting.signOffOnMat(backdrop: .lody, mat: 12))
  }

  func testScalePlanCapsAt16384AndRejectsOversizedCards() throws {
    let normal = try ChatShareRasterizer.scalePlan(outerWidth: 392, outerHeight: 1_200)
    XCTAssertEqual(normal.scale, 2.0)
    XCTAssertEqual(normal.pixelWidth, 784)
    XCTAssertEqual(normal.pixelHeight, 2_400)
    XCTAssertEqual(normal.stripCount, 2)

    let reduced = try ChatShareRasterizer.scalePlan(outerWidth: 560, outerHeight: 10_000)
    XCTAssertEqual(reduced.scale, 1.63, accuracy: 0.001)
    XCTAssertLessThanOrEqual(reduced.pixelHeight, 16_384)
    XCTAssertGreaterThanOrEqual(reduced.scale, 1.25)

    XCTAssertThrowsError(try ChatShareRasterizer.scalePlan(outerWidth: 560, outerHeight: 13_500)) { error in
      XCTAssertEqual(error as? ChatShareExportError, .tooLarge)
    }
  }

  func testOffscreenRasterizationPaletteIsolationQuotesCodeWrappingAndMultiStrip() throws {
    let sixLineQuote = (1...6).map { "Quoted line \($0) from earlier message" }.joined(separator: "\n")
    let userText = "\(sixLineQuote)\nInspect @src/very/long/path/component.tsx please."
    let quoteRange = (userText as NSString).range(of: sixLineQuote)
    let fileRange = (userText as NSString).range(of: "@src/very/long/path/component.tsx")
    let longCodeLine = "const extremelyLongIdentifierThatMustWrapCleanlyWithoutHorizontalScrolling = '" + String(repeating: "abcdef0123456789", count: 8) + "';"

    let messages: [RuntimeContract.ConversationShareMessage] = [
      .init(
        id: "u1",
        role: .user,
        text: userText,
        references: [
          .init(start: quoteRange.location, end: NSMaxRange(quoteRange), kind: "message_quote", label: "Quote", quote: sixLineQuote),
          .init(start: fileRange.location, end: NSMaxRange(fileRange), kind: "file", label: "component.tsx", target: "src/very/long/path/component.tsx"),
        ],
        estimatedTokens: 180
      ),
      .init(
        id: "a1",
        role: .assistant,
        text: "Here is the fix:\n\n```ts\n\(longCodeLine)\n```",
        estimatedTokens: 340,
        modelName: "Claude Sonnet 4.5",
        userTurnId: "u1"
      ),
    ]
    let meta = ChatShareCardMeta(name: "Claude Code", cliType: "builtin", agentType: "claude", params: ["Claude Sonnet 4.5", "~520 tokens"], date: "2026-11-26 10:00")

    // Verify full quote expansion & zero horizontal overflow inside ChatShareCardView.
    let cardView = ChatShareCardView(frame: .zero)
    let chatSize = cardView.configure(
      ChatShareConfiguration(
        messages: messages,
        title: "Palette & wrap verification",
        destination: .chat,
        mat: 0,
        theme: .light,
        backdrop: .none,
        meta: meta
      )
    )
    XCTAssertEqual(chatSize.width, 360)
    let fragments = cardView.renderedTextFragments().joined(separator: "\n")
    XCTAssertTrue(fragments.contains("Quoted line 6 from earlier message"))
    XCTAssertFalse(fragments.contains("Quoted line 3 from earlier message…"))

    // Host window forced to DARK while card is LIGHT -> exported card background must still be light (#FFFFFF).
    let darkHost = UIWindow(frame: CGRect(x: 0, y: 0, width: 420, height: 900))
    darkHost.overrideUserInterfaceStyle = .dark
    darkHost.isHidden = false
    defer { darkHost.isHidden = true }

    let lightPNG = try ChatShareRasterizer.renderPNG(
      ChatShareConfiguration(
        messages: messages,
        title: "Light card under dark host",
        destination: .chat,
        mat: 0,
        theme: .light,
        backdrop: .none,
        meta: meta
      ),
      hostView: darkHost
    )
    let lightImage = try Self.decodePNG(lightPNG)
    XCTAssertEqual(lightImage.width, 720)
    let lightBgSample = Self.sampleLuminance(in: lightImage, x: 20, y: 20)
    XCTAssertGreaterThan(lightBgSample, 0.92, "Light card must render white even when host traits are dark")

    // Host window forced to LIGHT while card is DARK -> exported card background must be soft dark (#161618, never #000000).
    let lightHost = UIWindow(frame: CGRect(x: 0, y: 0, width: 620, height: 900))
    lightHost.overrideUserInterfaceStyle = .light
    lightHost.isHidden = false
    defer { lightHost.isHidden = true }

    let darkPostPNG = try ChatShareRasterizer.renderPNG(
      ChatShareConfiguration(
        messages: messages,
        title: "Dark post card under light host",
        destination: .post,
        mat: 0,
        theme: .dark,
        backdrop: .none,
        meta: meta
      ),
      hostView: lightHost
    )
    let darkImage = try Self.decodePNG(darkPostPNG)
    XCTAssertEqual(darkImage.width, 1_120)
    let darkBgSample = Self.sampleLuminance(in: darkImage, x: 24, y: 24)
    XCTAssertGreaterThan(darkBgSample, 0.05, "Dark card must use soft dark surface, never pure black")
    XCTAssertLessThan(darkBgSample, 0.16, "Dark card must stay dark even when host traits are light")

    // Long multi-strip card (> 2500pt height -> > 5000px across >= 3 strips).
    var tallMessages: [RuntimeContract.ConversationShareMessage] = []
    for index in 0..<24 {
      tallMessages.append(.init(
        id: "u-\(index)",
        role: .user,
        text: "Prompt \(index): explain step \(index) in detail across multiple lines so the card grows past 2500 points.",
        estimatedTokens: 40
      ))
      tallMessages.append(.init(
        id: "a-\(index)",
        role: .assistant,
        text: "Answer \(index): Detailed explanation paragraph for exchange \(index) with `inlineCode` and clear vertical rhythm across stitched strips.",
        estimatedTokens: 80,
        modelName: "Claude Sonnet 4.5",
        userTurnId: "u-\(index)"
      ))
    }
    let tallConfig = ChatShareConfiguration(
      messages: tallMessages,
      title: "Multi-strip stitched export",
      destination: .chat,
      mat: 16,
      theme: .light,
      backdrop: .lody,
      meta: meta
    )
    let measuredSize = ChatShareCardView(frame: .zero).configure(tallConfig)
    XCTAssertGreaterThan(measuredSize.height, 2_500)

    let tallPNG = try ChatShareRasterizer.renderPNG(tallConfig, hostView: lightHost)
    let tallImage = try Self.decodePNG(tallPNG)
    XCTAssertEqual(tallImage.width, Int((measuredSize.width * 2).rounded()))
    XCTAssertEqual(tallImage.height, Int(floor(measuredSize.height * 2)))
    XCTAssertGreaterThan(tallImage.height, 5_000)

    // Sample center X in top strip, middle strip, and bottom strip: inside the light card surface, luminance is bright.
    let midX = tallImage.width / 2
    XCTAssertGreaterThan(Self.sampleLuminance(in: tallImage, x: midX, y: 120), 0.5)
    XCTAssertGreaterThan(Self.sampleLuminance(in: tallImage, x: midX, y: tallImage.height / 2), 0.5)
    XCTAssertGreaterThan(Self.sampleLuminance(in: tallImage, x: midX, y: tallImage.height - 160), 0.5)
  }

  func testTempStoreSanitizesTitlesStagesAndCleansUpStaleExports() throws {
    XCTAssertEqual(ChatShareTempStore.sanitizeFileName("Fix: auth/login? *draft* <v2> | test\nline"), "Fix-auth-login-draft-v2-test-line.png")
    XCTAssertEqual(ChatShareTempStore.sanitizeFileName("   ...   "), "lody-chat.png")
    let veryLong = String(repeating: "a", count: 90)
    XCTAssertEqual(ChatShareTempStore.sanitizeFileName(veryLong), String(repeating: "a", count: 60) + ".png")

    let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("lody-chat-share-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: sandbox) }

    let staged = try ChatShareTempStore.stagePNG(Data([0x89, 0x50, 0x4E, 0x47]), title: "My Session", baseDirectory: sandbox)
    XCTAssertTrue(FileManager.default.fileExists(atPath: staged.fileURL.path))
    XCTAssertEqual(staged.fileURL.lastPathComponent, "My Session.png")

    let staleDir = sandbox.appendingPathComponent("stale-item", isDirectory: true)
    try FileManager.default.createDirectory(at: staleDir, withIntermediateDirectories: true)
    let oldDate = Date(timeIntervalSinceNow: -700)
    try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: staleDir.path)

    ChatShareTempStore.cleanupStale(in: sandbox, maxAge: 600, now: Date())
    XCTAssertFalse(FileManager.default.fileExists(atPath: staleDir.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: staged.fileURL.path))

    ChatShareTempStore.removeDirectory(staged.directory)
    XCTAssertFalse(FileManager.default.fileExists(atPath: staged.directory.path))
  }

  func testLodyChatViewSelectionModeTogglesMultiRowTurnsAndRestoresComposer() throws {
    let view = LodyChatView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    let json = """
    [
      {"id":"u1","role":"user","status":"completed","finished":true,"items":[{"itemId":"t1","type":"text","text":"Hello"}]},
      {"id":"sys1","role":"assistant","status":"completed","finished":true,"items":[{"itemId":"n1","type":"system_notice","name":"session_fork_origin","meta":{"sourceSessionId":"s0","sourceTitle":"Origin"}}]},
      {"id":"a1","role":"assistant","status":"completed","finished":true,"endedAt":1793268064000,"items":[
        {"itemId":"p1","type":"text","text":"First part"},
        {"itemId":"tool1","type":"tool_call","kind":"execute","status":"completed","title":"ls -la"},
        {"itemId":"p2","type":"text","text":"Final answer"}
      ]}
    ]
    """
    view.transcript.entries = try JSONDecoder().decode([ChatEntry].self, from: Data(json.utf8))
    view.applyRows()
    view.layoutIfNeeded()

    let payload = RuntimeContract.ConversationShareMessagesResultReady(
      title: "Chat view test",
      messages: [
        .init(id: "u1", role: .user, text: "Hello", estimatedTokens: 10),
        .init(id: "a1", role: .assistant, text: "First part\n\nFinal answer", estimatedTokens: 30, userTurnId: "u1"),
      ]
    )
    let session = ChatShareSelectionSession(userId: "u", workspaceId: "w", sessionId: "s", payload: payload)
    XCTAssertTrue(view.beginShareSelection(session))
    XCTAssertTrue(view.composer.isHidden)
    XCTAssertFalse(view.shareSelectionToolbar.isHidden)
    XCTAssertFalse(view.shareSelectionToolbar.previewButton.isEnabled)

    // Non-prose notice row is dimmed; multi-row assistant turn highlights all rows together.
    let noticeRow = try XCTUnwrap(view.rows.values.first { $0.entryID == "sys1" })
    XCTAssertEqual(view.shareCellSelectionState(for: noticeRow), .dimmed)

    view.toggleShareEntry("a1")
    XCTAssertTrue(view.shareSelectionToolbar.previewButton.isEnabled)
    let assistantRows = view.dataSource.snapshot().itemIdentifiers.compactMap { view.rows[$0] }.filter { $0.entryID == "a1" }
    XCTAssertGreaterThanOrEqual(assistantRows.count, 2)
    for (idx, row) in assistantRows.enumerated() {
      XCTAssertEqual(
        view.shareCellSelectionState(for: row),
        .selectable(selected: true, isFirstRow: idx == 0, isLastRow: idx == assistantRows.count - 1)
      )
    }

    view.endShareSelection()
    XCTAssertFalse(view.composer.isHidden)
    XCTAssertTrue(view.shareSelectionToolbar.isHidden)
  }

  private static func decodePNG(_ data: Data) throws -> CGImage {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw ChatShareExportError.renderFailed
    }
    return image
  }

  private static func sampleLuminance(in image: CGImage, x: Int, y: Int) -> Double {
    let clampedX = max(0, min(image.width - 1, x))
    let clampedY = max(0, min(image.height - 1, y))
    var pixel: [UInt8] = [0, 0, 0, 0]
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
      data: &pixel,
      width: 1,
      height: 1,
      bitsPerComponent: 8,
      bytesPerRow: 4,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    ) else { return 0 }
    ctx.draw(
      image,
      in: CGRect(x: -clampedX, y: -(image.height - 1 - clampedY), width: image.width, height: image.height)
    )
    let r = Double(pixel[0]) / 255.0
    let g = Double(pixel[1]) / 255.0
    let b = Double(pixel[2]) / 255.0
    return 0.2126 * r + 0.7152 * g + 0.0722 * b
  }
}
