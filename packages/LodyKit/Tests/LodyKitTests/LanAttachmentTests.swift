import CoreGraphics
import Foundation
import ImageIO
import LodyCore
import UniformTypeIdentifiers
import XCTest
@testable import LodyKit

@MainActor
final class LanAttachmentTests: XCTestCase {
  func testStableAttachmentIdentityIncludesAccountModeLANAndWorkspace() {
    let identity = AttachmentIdentity.key(userId: "user", workspaceId: "workspace", lanId: "hub")
    XCTAssertEqual(identity, AttachmentIdentity.key(userId: "user", workspaceId: "workspace", lanId: "hub"))
    XCTAssertNotEqual(identity, AttachmentIdentity.key(userId: "other", workspaceId: "workspace", lanId: "hub"))
    XCTAssertNotEqual(identity, AttachmentIdentity.key(userId: "user", workspaceId: "other", lanId: "hub"))
    XCTAssertNotEqual(identity, AttachmentIdentity.key(userId: "user", workspaceId: "workspace", lanId: "other"))
    XCTAssertNotEqual(identity, AttachmentIdentity.key(userId: "user", workspaceId: "workspace", lanId: nil))
  }

  func testLocalImagesDecodeForBothAuthorsAndKeepTheirReadIdentity() throws {
    for role in ["user", "assistant"] {
      let json = """
      [{"id":"turn","role":"\(role)","status":"completed","finished":true,"items":[
        {"itemId":"picture","type":"file","file":{"id":"kept","fileName":"photo.jpg","transport":"local","sizeBytes":16,"mimeType":"image/jpeg","machineId":"desk","sha256":"\(String(repeating: "a", count: 64))","storageSessionId":"storage"}}
      ]}]
      """
      let entries = try JSONDecoder().decode([ChatEntry].self, from: Data(json.utf8))
      let picture = try XCTUnwrap(entries.first?.items.first?.file?.shownAsImage.image)
      XCTAssertEqual(picture.machineId, "desk")
      XCTAssertEqual(picture.storageSessionId, "storage")
      XCTAssertEqual(picture.sha256, String(repeating: "a", count: 64))
      XCTAssertEqual(picture.sizeBytes, 16)
      let rows = ChatTranscript(entries: entries).rows()
      if role == "user" {
        XCTAssertEqual(rows.first(where: { $0.kind == "attachments" })?.attachments.first?.image, picture)
      } else {
        XCTAssertEqual(rows.first(where: { $0.kind == "image" })?.image, picture)
        XCTAssertFalse(rows.contains { $0.kind == "file" })
      }
    }
    let invalid = ChatMessageAttachment(id: "large", fileName: "large.png", transport: "local",
      sizeBytes: 11 * 1024 * 1024, mimeType: "image/png", machineId: "desk", sha256: String(repeating: "b", count: 64))
    XCTAssertNil(invalid.shownAsImage.image)
  }

  func testImagePayloadKeepsCloudFormatsAndUsesImageIOJPEGForOthers() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let bitmap = try XCTUnwrap(CGContext(data: nil, width: 32, height: 16, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage())
    let png = directory.appendingPathComponent("same.png")
    let pngDestination = try XCTUnwrap(CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(pngDestination, bitmap, nil)
    XCTAssertTrue(CGImageDestinationFinalize(pngDestination))
    let bytes = try Data(contentsOf: png)
    let unchanged = try SessionAttachments.imagePayload(png, name: "same.png", size: bytes.count)
    XCTAssertEqual(unchanged.bytes, bytes)
    XCTAssertEqual(unchanged.mimeType, "image/png")

    let tiff = directory.appendingPathComponent("photo.tiff")
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(tiff as CFURL, UTType.tiff.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, bitmap, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    let size = try tiff.resourceValues(forKeys: [.fileSizeKey]).fileSize!
    let jpeg = try SessionAttachments.imagePayload(tiff, name: "photo.tiff", size: size)
    XCTAssertEqual(jpeg.fileName, "photo.jpg")
    XCTAssertEqual(jpeg.mimeType, "image/jpeg")
    XCTAssertLessThanOrEqual(jpeg.bytes.count, 5 * 1024 * 1024)
    let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg.bytes as CFData, nil))
    XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
  }

  func testLanTotalLimitRejectsBeforeOpeningAMember() async throws {
    let invite = try LanInvite.parse("lody-lan://test-token@127.0.0.1:9876/test")
    let machine = LanSessionFiles.Machine(id: "desk", name: "Desk", endpoint: nil, takesFiles: false)
    do {
      _ = try await LanSessionFiles.upload(Array(repeating: ["kind": "image"], count: 9), invite: invite, machine: machine, session: "s")
      XCTFail("Nine mixed attachments must fail before member connection")
    } catch {
      XCTAssertEqual(error.localizedDescription, String(localized: "native.attachment.error.lanLimit", bundle: .lody))
    }
  }

  func testLocalAttachmentAndLocalImageIdDecodeAndRender() throws {
    let localImageId = "11111111-2222-4333-8444-555555555555"
    let json = """
    [
      {"id":"u1","role":"user","status":"handled","finished":true,"items":[
        {"itemId":"la1","type":"local_attachment","file":{"id":"local:desk:/tmp/spec.pdf","fileName":"spec.pdf","mimeType":"application/pdf","transport":"local_attachment","machineId":"desk","path":"/tmp/spec.pdf","kind":"file","sizeBytes":2048}},
        {"itemId":"la2","type":"local_attachment","file":{"id":"local:desk:/tmp/old.png","fileName":"old.png","mimeType":"image/png","transport":"local_attachment","machineId":"desk","path":"/tmp/old.png","kind":"image","sizeBytes":1024}},
        {"itemId":"li1","type":"image","image":{"id":"\(localImageId)","fileName":"paste.png","transport":"local","machineId":"desk","localImageId":"\(localImageId)","sizeBytes":512,"mimeType":"image/png","width":100,"height":80}},
        {"itemId":"r2i","type":"image","image":{"id":"r2-img","fileName":"cloud.png","transport":"r2","machineId":"desk","localImageId":"\(localImageId)","sizeBytes":512,"mimeType":"image/png"}}
      ]},
      {"id":"a1","role":"assistant","status":"completed","finished":true,"items":[
        {"itemId":"la3","type":"local_attachment","file":{"id":"local:desk:/tmp/out.txt","fileName":"out.txt","mimeType":"text/plain","transport":"local_attachment","machineId":"desk","path":"/tmp/out.txt","kind":"file","sizeBytes":16}}
      ]}
    ]
    """
    let entries = try JSONDecoder().decode([ChatEntry].self, from: Data(json.utf8))
    let rows = ChatTranscript(entries: entries).rows()

    let userAttachments = try XCTUnwrap(rows.first(where: { $0.kind == "attachments" })?.attachments)
    XCTAssertEqual(userAttachments.count, 4)
    XCTAssertTrue(userAttachments[0].isLocalAttachment)
    XCTAssertEqual(userAttachments[0].path, "/tmp/spec.pdf")
    XCTAssertEqual(userAttachments[0].kind, "file")
    XCTAssertTrue(userAttachments[1].isLocalAttachment)
    XCTAssertEqual(userAttachments[1].kind, "image")
    let localImg = try XCTUnwrap(userAttachments[2].image)
    XCTAssertTrue(localImg.isLANKept)
    XCTAssertEqual(localImg.lanCacheKey, "local-\(localImageId)")
    let cloudImg = try XCTUnwrap(userAttachments[3].image)
    XCTAssertFalse(cloudImg.isLANKept)

    let assistantFileRow = try XCTUnwrap(rows.first(where: { $0.entryID == "a1" && $0.kind == "file" }))
    XCTAssertEqual(assistantFileRow.file?.path, "/tmp/out.txt")
    XCTAssertTrue(assistantFileRow.actionable)
  }

  func testLanImageCacheStoresLocalImageIdDisjointFromDigests() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("lody-local-img-cache-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = LanImageCache(directory: root)
    let id = "11111111-2222-4333-8444-555555555555"
    var loads = 0
    let first = try await cache.file(localImageId: id.uppercased(), scope: "u:w:lan") { scratch in
      loads += 1
      try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
      let file = scratch.appendingPathComponent("paste.png")
      try Data("png-bytes".utf8).write(to: file)
      return file
    }
    let second = try await cache.file(localImageId: id, scope: "u:w:lan") { _ in
      XCTFail("Cache hit must not invoke loader again")
      throw CancellationError()
    }
    XCTAssertEqual(first, second)
    XCTAssertEqual(first.lastPathComponent, "local-\(id)")
    XCTAssertEqual(loads, 1)
    do {
      _ = try await cache.file(localImageId: "../escape", scope: "u:w:lan") { _ in throw CancellationError() }
      XCTFail("Non-UUID localImageId must be rejected")
    } catch {}
  }

  func testLocalAttachmentDownloaderAssemblesChunksAndHandlesErrors() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lody-dl-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let attachment = ChatMessageAttachment(
      id: "local:desk:/tmp/doc.txt",
      fileName: "doc.txt",
      transport: "local_attachment",
      sizeBytes: 11,
      mimeType: "text/plain",
      machineId: "desk",
      path: "/tmp/doc.txt",
      kind: "file"
    )
    let rev = String(repeating: "f", count: 64)
    var seenParams: [RuntimeContract.DownloadFileChunkParams] = []
    let downloaded = try await LocalAttachmentDownloader.download(
      sessionId: "s1",
      attachment: attachment,
      directory: directory
    ) { params in
      seenParams.append(params)
      if params.offset == 0 {
        XCTAssertNil(params.revision)
        return .ok(.init(path: "doc.txt", revision: rev, sizeBytes: 11, offset: 0, data: Data("hello ".utf8).base64EncodedString()))
      }
      XCTAssertEqual(params.revision, rev)
      return .ok(.init(path: "doc.txt", revision: rev, sizeBytes: 11, offset: 6, data: Data("world".utf8).base64EncodedString()))
    }
    XCTAssertEqual(try Data(contentsOf: downloaded), Data("hello world".utf8))
    XCTAssertEqual(seenParams.count, 2)
    XCTAssertEqual(seenParams[0].attachment?.type, "local_attachment")
    XCTAssertEqual(seenParams[0].attachment?.path, "/tmp/doc.txt")

    // Zero-byte file succeeds in a single round-trip.
    let emptyDir = directory.appendingPathComponent("empty", isDirectory: true)
    let emptyFile = try await LocalAttachmentDownloader.download(
      sessionId: "s1",
      attachment: ChatMessageAttachment(
        id: "local:desk:/tmp/empty.txt", fileName: "empty.txt", transport: "local_attachment",
        sizeBytes: 0, mimeType: "text/plain", machineId: "desk", path: "/tmp/empty.txt", kind: "file"
      ),
      directory: emptyDir
    ) { _ in
      .ok(.init(path: "empty.txt", revision: rev, sizeBytes: 0, offset: 0, data: ""))
    }
    XCTAssertEqual(try Data(contentsOf: emptyFile), Data())

    // file_changed removes partial file and maps to stale error copy.
    let changedDir = directory.appendingPathComponent("changed", isDirectory: true)
    do {
      _ = try await LocalAttachmentDownloader.download(
        sessionId: "s1", attachment: attachment, directory: changedDir
      ) { params in
        if params.offset == 0 {
          return .ok(.init(path: "doc.txt", revision: rev, sizeBytes: 11, offset: 0, data: Data("hello ".utf8).base64EncodedString()))
        }
        return .error(.init(code: "file_changed"))
      }
      XCTFail("file_changed must throw")
    } catch {
      XCTAssertEqual(error.localizedDescription, String(localized: "native.file.error.stale", bundle: .lody))
      XCTAssertFalse(FileManager.default.fileExists(atPath: changedDir.appendingPathComponent("doc.txt").path))
    }

    // Exceeding maxBytes fails cleanly without writing a file.
    let largeDir = directory.appendingPathComponent("large", isDirectory: true)
    do {
      _ = try await LocalAttachmentDownloader.download(
        sessionId: "s1", attachment: attachment, directory: largeDir, maxBytes: 8
      ) { _ in
        XCTFail("Declared oversize attachment must fail before RPC")
        return .error(.init(code: "too_large"))
      }
      XCTFail("Oversize attachment must throw")
    } catch {
      XCTAssertEqual(error.localizedDescription, String(localized: "native.file.error.tooLarge", bundle: .lody))
    }
  }

  func testTurnLinksAndAntigravityModes() {
    let turn = "assistant:inbox:completion:12.v1_a-b"
    let link = SessionLink("lody://session/s1?workspace=ws1&turn=\(turn)")
    XCTAssertEqual(link?.sessionId, "s1")
    XCTAssertEqual(link?.workspaceId, "ws1")
    XCTAssertEqual(link?.turnId, turn)
    XCTAssertEqual(
      SessionMessageLink.resolve("lody://session/s1?workspace=ws1&turn=\(turn)", workspaceId: "ws1", sessionIds: ["s1"], machineHost: nil),
      .session("s1", turnId: turn)
    )
    XCTAssertNil(SessionLink("lody://session/s1?turn=bad%3Avalue"))
    XCTAssertNil(SessionLink("lody://session/s1?turn=a&turn=b"))
    XCTAssertNil(SessionLink("lody://session/s1?turn="))

    XCTAssertEqual(CreateLogic.normalizedModeId("auto_review"), "auto")
    XCTAssertEqual(CreateLogic.normalizedConfigValue(.string("auto_review"), optionId: "mode"), .string("auto"))
    XCTAssertEqual(CreateLogic.permissionTier(for: "accept-edits"), .edit)
    XCTAssertEqual(CreateLogic.permissionTier(for: "yolo"), .full)
    XCTAssertEqual(CreateLogic.permissionTier(for: "auto"), .auto)
    XCTAssertEqual(CreateLogic.permissionTier(for: "auto_review"), .auto)
  }
}
