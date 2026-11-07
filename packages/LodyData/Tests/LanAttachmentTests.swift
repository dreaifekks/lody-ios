import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LodyData

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
    let bytes = Data([0, 1, 2, 3])
    let png = directory.appendingPathComponent("same.png")
    try bytes.write(to: png)
    let unchanged = try SessionAttachments.imagePayload(png, name: "same.png", size: bytes.count)
    XCTAssertEqual(unchanged.bytes, bytes)
    XCTAssertEqual(unchanged.mimeType, "image/png")

    let bitmap = try XCTUnwrap(CGContext(data: nil, width: 32, height: 16, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage())
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
      XCTAssertEqual(error.localizedDescription, String(localized: "native.attachment.error.lanLimit", bundle: .lodyData))
    }
  }
}
