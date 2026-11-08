import XCTest
@testable import LodyCore

final class SessionMessageLinkTests: XCTestCase {
  private func resolve(_ raw: String, host: String? = nil) -> SessionMessageLink {
    SessionMessageLink.resolve(raw, workspaceId: "workspace", sessionIds: ["base", "tab"], machineHost: host)
  }

  func testPublicGrammarAndLegacyTabPrecedence() {
    for scheme in ["lody", "LODY", "lody-oss", "ai.lody.stable", "ai.lody.nightly"] {
      XCTAssertEqual(resolve("\(scheme)://session/base?workspace=workspace&tab=tab"), .session("tab"))
    }
    XCTAssertEqual(resolve("session://base/"), .session("base"))
    XCTAssertEqual(resolve("lody://session/base?&workspace=workspace&&"), .session("base"))
    XCTAssertEqual(resolve("lody://session/base?workspace=other"), .missingSession)
    XCTAssertEqual(resolve("lody://session/base?tab=missing"), .missingSession)
    XCTAssertEqual(resolve("session://missing"), .missingSession)
  }

  func testMalformedSessionLinksNeverOpenOrGuessAnID() {
    for raw in ["SESSION://base", "session://base?workspace=workspace", "lody://session/base/", "lody://session/base#x",
      "lody://session/a/../base", "lody://session/%62ase", "lody://session/base?workspace=a&workspace=b",
      "lody://session/base?tab=", "lody://session/base?unknown=x", "lody://session/base?tab=tab+",
      "lody://session:80/base", "lody://user@session/base", " lody://session/base", "lody://session/base\n",
      "lody://session/" + String(repeating: "a", count: 8193)] {
      XCTAssertNil(SessionLink(raw), raw)
      XCTAssertEqual(resolve(raw), .none, raw)
    }
  }

  func testLoopbackReplacesOnlyTheCurrentMachineHost() {
    for host in ["localhost", "127.0.0.1", "0.0.0.0", "[::1]", "LOCALHOST"] {
      let raw = "http://\(host):5173/a%20b?x=1&x=2#fragment"
      XCTAssertEqual(resolve(raw, host: "192.0.2.42"), .url(URL(string: "http://192.0.2.42:5173/a%20b?x=1&x=2#fragment")!))
      XCTAssertEqual(resolve(raw), .loopback)
    }
    XCTAssertEqual(resolve("https://localhost/path?q=a%2Fb#L2", host: "2001:db8::42"),
      .url(URL(string: "https://[2001:db8::42]/path?q=a%2Fb#L2")!))
    XCTAssertEqual(resolve("https://localhost:443", host: " \n"), .loopback)
  }

  func testSystemSchemesIncludeFileURI() {
    for raw in ["https://example.invalid/a?b=c#d", "http://example.invalid", "file:///tmp/report%20one.md#L12",
      "tg://resolve?domain=lody", "mailto:reader@example.invalid", "tel:+15550100"] {
      XCTAssertEqual(resolve(raw), .url(URL(string: raw)!))
    }
    for raw in ["javascript:alert(1)", "data:text/plain,hello", "src/a.swift", "myapp://session/base"] {
      XCTAssertEqual(resolve(raw), .none)
    }
  }

  func testMessageGrammarDoesNotChangeNotificationLinks() {
    XCTAssertEqual(AppLink.parse("lody://workspace/sessions/base"), .session(workspace: "workspace", session: "base"))
    XCTAssertNil(SessionLink("lody://workspace/sessions/base"))
  }
}
