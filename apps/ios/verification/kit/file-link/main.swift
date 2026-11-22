import UIKit

@MainActor func checkLinks() {

  assert(ChatFileLink("docs/report%20one.md#L12-L20")?.path == "docs/report one.md")
  assert(ChatFileLink("docs/report%20one.md#L12-L20")?.line == 12)
  assert(ChatFileLink("C:\\repo\\sample.swift:2")?.path == "C:/repo/sample.swift")
  assert(ChatFileLink("C:\\repo\\sample.swift:2")?.line == 2)
  assert(ChatFileLink("../photo.png")?.path == "../photo.png")
  assert(ChatFileLink("file:///Users/a/report.html")?.path == "/Users/a/report.html")
  assert(ChatFileLink("file:///C:/a/report.html")?.path == "C:/a/report.html")
  for href in ["https://example.com/report.md", "javascript:alert(1)", "file://remote/etc/passwd", "//example.com/a.md", "#heading", "report.md?download", "a%00.md"] {
    assert(ChatFileLink(href) == nil, href)
  }
  print("PASS: file links preserve paths and line anchors while rejecting external schemes and malformed targets")

  func paths(_ text: String) -> [String] { ChatBareLinks.split(text).compactMap(\.href) }
  assert(paths("见notes/准备.md和src/你好.swift。 ~/out/报告.md:12") == ["notes/准备.md", "src/你好.swift", "~/out/报告.md:12"])
  assert(paths("foo.ts app.ts:32 Node.js and/or example.com/page.html user@example.com/x.md ~user/x.md") == ["app.ts:32"])
  assert(paths("😀src/a.ts/以及其他") == ["src/a.ts"])
  assert(paths("lody://session/abc?workspace=lw_test。 session://old") == ["lody://session/abc?workspace=lw_test", "session://old"])
  assert(paths("https://example.com/src/foo.ts") == [])
  assert(paths("lody://session/abc?workspace=a&workspace=b") == [])
  assert(ChatBareLinks.split("见notes/准备.md。 ignored").map(\.text).joined() == "见notes/准备.md。 ignored")
  assert(paths("见“lody://session/abc?workspace=ws”。src/a.ts") == ["lody://session/abc?workspace=ws", "src/a.ts"])
  assert(paths("session://review…src/报告.md") == ["session://review", "src/报告.md"])
  assert(paths("LODY://session/abc。src/a.swift") == ["LODY://session/abc", "src/a.swift"])
  assert(paths("https://example.com/x。src/file.swift") == ["src/file.swift"])
  assert(paths("SESSION://review") == [])
  assert(paths("session://" + String(repeating: "a", count: 8193)) == [])
  assert(paths("file:///tmp/report.md tg://resolve?domain=x mailto:reader@example.com tel:+15550100") == [
    "file:///tmp/report.md", "tg://resolve?domain=x", "mailto:reader@example.com", "tel:+15550100"])
  assert(paths("ai.lody.stable://session/abc?workspace=ws lody-oss://session/def") == ["ai.lody.stable://session/abc?workspace=ws", "lody-oss://session/def"])
  print("PASS: bare paths and session resources retain settled punctuation and Unicode boundaries")
}

// Offline presentation/service boundaries; route and page lifecycle are production.
@MainActor final class DataRuntime { static var current: DataRuntime? }
@MainActor enum FilePreview {
  static func open(sessionId: String, path: String, line: Int, runtime: DataRuntime, from: UIViewController) async -> Bool { false }
}
@MainActor final class SessionController: UIViewController {
  let sessionId = "synthetic-session"
  var openingFiles: Set<String> = []
  var sheets: [LodyPageController] = []
  func open(_ page: String, _ params: [String: Any], present: Bool, from: UIViewController?, onClose: (() -> Void)?) {
    let spec = ShellPageSpec(title: params["path"] as! String, style: "formSheet", animation: "none",
      dismissible: true, headerShown: true, headerVariant: "transparent")
    let sheet = LodyPageController(spec: spec, inSheet: true, content: UIViewController())
    sheet.onClose = onClose
    sheets.append(sheet)
  }
}
extension Notification.Name { static let lodyAppearanceDidChange = Notification.Name("testAppearance") }
@MainActor final class LodyPageStackHost: UIViewController { func closePages() {} }
@MainActor enum LodyScrollEdges { static let ownerChanged = Notification.Name("testScrollOwner") }
extension UIColor { static var lodyGroupedBackground: UIColor { .systemGroupedBackground } }

@MainActor final class DismissalNavigation: UINavigationController {
  var dismissing = false
  override var isBeingDismissed: Bool { dismissing }
}

@main struct FileLinkChecks {
  @MainActor static func main() async {
    checkLinks()
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    let session = SessionController()
    window.addSubview(session.view)
    let first = session.openFile("docs/one.md", line: 1)!
    precondition(session.openFile("docs/one.md", line: 9) == nil)
    await first.value
    let page = session.sheets[0]
    let navigation = DismissalNavigation(rootViewController: page)
    precondition(page.title == "docs/one.md" && page.inSheet && !page.closed)
    precondition(session.openFile("docs/one.md", line: 1) == nil)
    precondition(session.sheets.count == 1, "Visible preview retains ownership after open returns")
    // Disappearing under another sheet or a cancelled dismissal is not closure.
    page.viewDidDisappear(false)
    precondition(!page.closed && session.openFile("docs/one.md", line: 1) == nil)
    await session.openFile("docs/two.md", line: 0)!.value
    precondition(session.sheets.count == 2 && session.sheets[1].title == "docs/two.md")
    // Deliver the existing shell's confirmed close boundary, not a timer.
    session.sheets[1].markClosed()
    precondition(session.openingFiles == ["docs/one.md"])
    // UIKit reports this flag only for completed sheet dismissal (including swipe).
    navigation.dismissing = true
    page.viewDidDisappear(false)
    precondition(page.closed && session.openingFiles.isEmpty)
    await session.openFile("docs/one.md", line: 2)!.value
    precondition(session.sheets.count == 3 && !session.sheets[2].closed)
    page.markClosed()
    precondition(session.openFile("docs/one.md", line: 2) == nil, "An old page cannot release a new preview")
    session.sheets[2].markClosed()
    let detached = SessionController()
    await detached.openFile("docs/one.md", line: 0)!.value
    precondition(detached.openingFiles.isEmpty && detached.sheets.isEmpty)
    print("PASS: duplicate in-flight/visible file routes, nested files, confirmed close, reopen and detached source")
  }
}
