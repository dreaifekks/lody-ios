import Foundation

assert(ChatFileLink("docs/report%20one.md#L12-L20")?.path == "docs/report one.md")
assert(ChatFileLink("docs/report%20one.md#L12-L20")?.line == 12)
assert(ChatFileLink("C:\\repo\\sample.swift:2")?.path == "C:/repo/sample.swift")
assert(ChatFileLink("C:\\repo\\sample.swift:2")?.line == 2)
assert(ChatFileLink("../photo.png")?.path == "../photo.png")
for href in ["https://example.com/report.md", "javascript:alert(1)", "file:///etc/passwd", "//example.com/a.md", "#heading", "report.md?download", "a%00.md"] {
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
assert(ChatBareLinks.wholeFile("foo.ts") == "foo.ts")
assert(ChatBareLinks.wholeFile("cat src/a.ts") == nil)
assert(ChatBareLinks.split("见notes/准备.md。 ignored").map(\.text).joined() == "见notes/准备.md。 ignored")
