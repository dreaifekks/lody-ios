import SwiftUI
import UIKit

// The Apple Watch Smart Stack draws the Live Activity's small family on a card of
// 152x69.5 to 191x81.5 pt (HIG, 40 to 49 mm), and a tap opens the same view full
// screen. Each state must fit every card without spilling past its bottom edge,
// and the full screen must show more than a card. iOS text styles run at or above
// watchOS footnote and headline sizes, so a fit here also fits on the watch.

typealias State = LodyActivityAttributes.ContentState
typealias Item = State.Item

let now = Date().timeIntervalSince1970 * 1000

func item(
  _ id: String,
  _ status: Item.Status,
  _ title: String,
  command: String? = nil,
  activity: String? = nil,
  thought: String? = nil,
  done: Bool = false
) -> Item {
  var item = Item(
    id: id,
    status: status,
    statusLabel: status.rawValue,
    permissionRequestId: command == nil ? nil : "request",
    permissionCommand: command,
    agentLogoKind: "claude",
    agentLogoText: "CC",
    title: title,
    updatedAt: now - 1000,
    updatedAtLabel: "now",
    startedAt: now - 761_000,
    completedAt: done ? now - 1000 : nil
  )
  item.machineName = "homenuc"
  item.activity = activity
  item.thought = thought
  if command != nil {
    item.permissionOptions = [
      .init(id: "allow", label: "Allow", kind: "allow_once"),
      .init(id: "deny", label: "Deny", kind: "reject_once"),
    ]
  }
  return item
}

func state(_ items: [Item]) -> State {
  var counts = State.Counts()
  counts.running = items.count { $0.status == .running }
  counts.permission = items.count { $0.status == .permission }
  counts.question = items.count { $0.status == .question }
  counts.unread = items.count { $0.status == .unread }
  return State(totalCount: items.count, statusCounts: counts, items: items, permissionAlert: nil, copy: nil)
}

let longTitle = "Refactor the session list paging so cursors survive a catalog reload"
let longThought = String(repeating: "I need to check how the session list pages its results before changing the cursor handling. ", count: 3)
let longCommand = "git push origin main --force-with-lease && pnpm --filter @lody-ios/mobile run verify:build -- --configuration Release"
let longStep = "Read apps/mobile/modules/lody-kit/data-runtime/session.ts"

let cases: [(name: String, state: State, stale: Bool, grows: Bool)] = [
  ("running", state([item("1", .running, longTitle, activity: longStep, thought: longThought)]), false, true),
  ("running-no-thought", state([item("1", .running, longTitle, activity: longStep)]), false, false),
  ("overview", state([
    item("1", .running, longTitle, activity: longStep, thought: longThought),
    item("2", .running, "Poll GitHub PR status", activity: "Run gh pr checks"),
    item("3", .running, "Write the watchdog check"),
  ]), false, true),
  ("permission", state([item("1", .running, "Poll GitHub PR status"), item("2", .permission, longTitle, command: longCommand)]), false, true),
  ("question", state([item("1", .question, longTitle)]), false, false),
  ("done", state([item("1", .unread, longTitle, done: true)]), false, false),
  ("stale", state([item("1", .running, longTitle, thought: longThought)]), true, false),
]

// HIG card sizes less the 8 pt content margin on each side, then the full screen.
let cards: [(name: String, size: CGSize)] = [
  ("40mm", CGSize(width: 136, height: 53.5)),
  ("41mm", CGSize(width: 149, height: 56.5)),
  ("44mm", CGSize(width: 157, height: 60.5)),
  ("45mm", CGSize(width: 168, height: 64.5)),
  ("49mm", CGSize(width: 175, height: 65.5)),
]
let fullScreen = CGSize(width: 168, height: 170)
let scale: CGFloat = 2

/// The lowest drawn row, in points, of the view laid out in `size` on a canvas with
/// room below it for anything that spills.
@MainActor
func inkBottom(_ entry: (name: String, state: State, stale: Bool, grows: Bool), in size: CGSize) -> CGFloat {
  let canvas = LodyCompactActivityView(state: entry.state, isStale: entry.stale)
    .frame(width: size.width, height: size.height, alignment: .topLeading)
    .frame(width: size.width, height: size.height + 120, alignment: .top)
    .environment(\.colorScheme, .dark)
  let renderer = ImageRenderer(content: canvas)
  renderer.scale = scale
  guard let image = renderer.cgImage else { fatalError("\(entry.name) did not render") }
  if let directory = ProcessInfo.processInfo.environment["LODY_WATCH_CARD_OUTPUT"] {
    let url = URL(fileURLWithPath: directory).appendingPathComponent("\(entry.name)-\(Int(size.width))x\(Int(size.height)).png")
    try? UIImage(cgImage: image).pngData()?.write(to: url)
  }
  let width = image.width
  let height = image.height
  var pixels = [UInt8](repeating: 0, count: width * height * 4)
  guard let context = CGContext(
    data: &pixels,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: width * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  ) else { fatalError("no bitmap context") }
  context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
  var last = -1
  for row in 0..<height {
    for column in 0..<width where pixels[(row * width + column) * 4 + 3] > 24 {
      last = row
      break
    }
  }
  return CGFloat(last + 1) / scale
}

for entry in cases {
  var tallestCard: CGFloat = 0
  for card in cards {
    let bottom = inkBottom(entry, in: card.size)
    precondition(bottom > 0, "\(entry.name) drew nothing on a \(card.name) card")
    precondition(bottom <= card.size.height + 0.5, "\(entry.name) spills \(bottom - card.size.height) pt past a \(card.name) card")
    tallestCard = max(tallestCard, bottom)
  }
  let full = inkBottom(entry, in: fullScreen)
  precondition(full <= fullScreen.height + 0.5, "\(entry.name) spills past the full screen")
  if entry.grows {
    precondition(full > tallestCard + 10, "\(entry.name) shows no more full screen (\(full) pt) than on a card (\(tallestCard) pt)")
  }
}
print("PASS: watch Live Activity fits every Smart Stack card and grows full screen")
