import SwiftUI
import WidgetKit

typealias LodyItem = LodyActivityAttributes.ContentState.Item
typealias LodyState = LodyActivityAttributes.ContentState

enum LodyTone {
  static let blue = Color(red: 0.24, green: 0.36, blue: 0.86)
  static let teal = Color(red: 0.16, green: 0.73, blue: 0.61)
  static let glow = LinearGradient(colors: [blue, teal], startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct AgentGlyph: View {
  let kind: String
  let text: String
  let size: CGFloat

  static let kinds: Set<String> = [
    "claude", "codex", "kimi", "grok", "deepseek", "minimax", "glm", "mimo", "opencode", "gemini", "openai",
  ]
  private static let aliases = ["claude-p": "claude", "kimi-code": "kimi"]

  var body: some View {
    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
      .fill(image == nil ? Color.secondary.opacity(0.2) : Color.white)
      .frame(width: size, height: size)
      .overlay(mark)
  }

  private var image: String? {
    let key = kind.lowercased()
    let canonical = Self.aliases[key] ?? key
    return Self.kinds.contains(canonical) ? "lody-agent-\(canonical)" : nil
  }

  @ViewBuilder
  private var mark: some View {
    if let image {
      Image(image)
        .resizable()
        .renderingMode(.template)
        .foregroundStyle(.black)
        .padding(size * 0.2)
    } else {
      Text(text)
        .font(.caption.weight(.semibold))
        .minimumScaleFactor(0.5)
        .lineLimit(1)
        .padding(.horizontal, 2)
    }
  }
}

struct DoneGlyph: View {
  let size: CGFloat
  var failed = false

  var body: some View {
    Circle()
      .fill(failed ? Color.red : Color.blue)
      .frame(width: size, height: size)
      .overlay(
        Image(systemName: failed ? "xmark" : "checkmark")
          .font(.system(size: size * 0.48, weight: .bold))
          .foregroundStyle(.white)
      )
  }
}

struct LeadGlyph: View {
  let item: LodyItem
  let size: CGFloat

  var body: some View {
    if item.isDone {
      DoneGlyph(size: size, failed: item.status == .failed)
    } else {
      AgentGlyph(kind: item.agentLogoKind, text: item.agentLogoText, size: size)
    }
  }
}

struct GlyphStack: View {
  let items: [LodyItem]
  let size: CGFloat

  var body: some View {
    ZStack(alignment: .topLeading) {
      ForEach(Array(items.prefix(2).enumerated()), id: \.offset) { index, item in
        AgentGlyph(kind: item.agentLogoKind, text: item.agentLogoText, size: size * 0.72)
          .offset(x: CGFloat(index) * size * 0.28, y: CGFloat(index) * size * 0.28)
      }
    }
    .frame(width: size, height: size, alignment: .topLeading)
  }
}

// The jellyfish dissolves into the system glass through a radial mask, so no
// edge of the artwork ever reads as a badge or a card on top of the container.
// ActivityKit replaces an image whose pixels exceed its frame with a grey box, so
// the asset ships at exactly this point size in 1x/2x/3x and is never drawn larger.
struct JellyGlow: View {
  @AppStorage(LodyActivityIcon.key, store: LodyActivityIcon.defaults) private var appIcon = "default"
  static let pointSize: CGFloat = 120
  var opacity: Double = 0.55
  private var size: CGFloat { Self.pointSize }

  var body: some View {
    Image(LodyActivityIcon.asset(name: appIcon, mark: false))
      .resizable()
      .scaledToFit()
      .frame(width: size, height: size)
      .mask(
        RadialGradient(
          colors: [.black, .black.opacity(0.45), .clear],
          center: UnitPoint(x: 0.45, y: 0.4),
          startRadius: 0,
          endRadius: size * 0.5
        )
      )
      .opacity(opacity)
      .accessibilityHidden(true)
      .allowsHitTesting(false)
  }
}

struct JellyMark: View {
  @AppStorage(LodyActivityIcon.key, store: LodyActivityIcon.defaults) private var appIcon = "default"
  static let pointSize: CGFloat = 22

  var body: some View {
    Image(LodyActivityIcon.asset(name: appIcon, mark: true))
      .resizable()
      .frame(width: Self.pointSize, height: Self.pointSize)
      .accessibilityHidden(true)
  }
}

struct StatusSymbol: View {
  let status: LodyItem.Status
  var isStale = false

  var body: some View {
    // WidgetKit has no indeterminate spinner: a circular ProgressView ignores
    // controlSize and draws an oversized empty ring, so running is a pulsing dot.
    switch (isStale, status) {
    case (true, _):
      Image(systemName: "wifi.slash")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    case (_, .running):
      Image(systemName: "circle.fill")
        .font(.system(size: 9))
        .foregroundStyle(LodyTone.glow)
        .symbolEffect(.pulse)
    case (_, .permission):
      Image(systemName: "exclamationmark.circle.fill")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.orange)
    case (_, .question):
      Image(systemName: "questionmark.circle.fill")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.orange)
    case (_, .unread):
      Image(systemName: "checkmark.circle.fill")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.blue)
    case (_, .failed):
      Image(systemName: "xmark.circle.fill")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.red)
    }
  }
}

struct MinimalSymbol: View {
  let status: LodyItem.Status
  let isStale: Bool

  var body: some View {
    if isStale || status != .running {
      StatusSymbol(status: status, isStale: isStale)
    } else {
      Circle()
        .strokeBorder(LodyTone.glow, lineWidth: 3)
        .frame(width: 14, height: 14)
    }
  }
}

struct WorkTimer: View {
  let item: LodyItem
  var font: Font = .subheadline.monospacedDigit()
  var width: CGFloat = 56

  var body: some View {
    // A timer Text sizes itself to its whole interval, so an unbounded one running to
    // distantFuture blows the layout out and leaves the entire container unrendered.
    Group {
      if let end = item.completedDate {
        Text(timerInterval: item.startDate...max(end, item.startDate), pauseTime: end, countsDown: false)
      } else {
        Text(timerInterval: item.startDate...Date.distantFuture, countsDown: false)
      }
    }
    .font(font)
    .lineLimit(1)
    .minimumScaleFactor(0.7)
    .multilineTextAlignment(.trailing)
    .frame(width: width, alignment: .trailing)
  }
}

struct HeroTimer: View {
  let item: LodyItem
  let caption: String

  var body: some View {
    VStack(alignment: .trailing, spacing: 2) {
      WorkTimer(item: item, font: .system(.title2, design: .rounded).weight(.semibold).monospacedDigit(), width: 78)
      Text(caption)
        .font(.caption2.weight(.medium))
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }
  }
}

struct StatusPill: View {
  let status: LodyItem.Status
  let label: String

  var body: some View {
    HStack(spacing: 4) {
      StatusSymbol(status: status)
      Text(label)
        .font(.footnote.weight(.medium))
        .lineLimit(1)
    }
    .foregroundStyle(tint)
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(Capsule().fill(tint.opacity(0.18)))
  }

  private var tint: Color {
    switch status {
    case .permission, .question: .orange
    case .running, .unread: .blue
    case .failed: .red
    }
  }
}

struct FocusText: View {
  let focus: LodyItem
  let othersCount: Int
  let isStale: Bool
  let copy: LodyState
  /// Lines the current reasoning may take in place of the running label.
  var thoughtLines = 2

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      FocusTitle(item: focus)
        .font(.headline)
      statusLine
    }
  }

  @ViewBuilder
  private var statusLine: some View {
    if isStale {
      HStack(spacing: 5) {
        StatusSymbol(status: focus.status, isStale: true)
        Text(copy.staleLabel)
        Text("·")
        Text(copy.lastSyncLabel) + Text(" ") + Text(focus.updatedDate, style: .relative)
      }
      .font(.subheadline)
      .foregroundStyle(.secondary)
      .lineLimit(1)
    } else if focus.status == .running, let thought = focus.thought, !thought.isEmpty {
      // The current stretch of reasoning says more than "Working".
      HStack(alignment: .firstTextBaseline, spacing: 5) {
        StatusSymbol(status: .running)
        Text(thought)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(thoughtLines)
          // The newest words are at the end; drop the start when it overflows.
          .truncationMode(.head)
      }
    } else if focus.status == .running {
      HStack(spacing: 5) {
        StatusSymbol(status: .running)
        Text(runningText)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    } else if focus.isDone {
      HStack(spacing: 5) {
        StatusPill(status: focus.status, label: focus.statusLabel)
        Text(focus.updatedDate, style: .relative)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    } else {
      HStack(spacing: 5) {
        StatusPill(status: focus.status, label: focus.statusLabel)
        if copy.statusCounts.running > 0 {
          Text(copy.runningSummary)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
    }
  }

  private var runningText: String {
    if othersCount > 0 {
      return "\(focus.statusLabel) · \(copy.othersLabel(othersCount))"
    }
    return focus.statusLabel
  }
}

struct FocusRow: View {
  let state: LodyState
  let focus: LodyItem
  let isStale: Bool
  let glyphSize: CGFloat

  var body: some View {
    HStack(spacing: 12) {
      LeadGlyph(item: focus, size: glyphSize)
      FocusText(focus: focus, othersCount: state.othersCount, isStale: isStale, copy: state)
      Spacer(minLength: 4)
      if state.showsTimer(for: focus, isStale: isStale) {
        HeroTimer(item: focus, caption: state.timerCaption(for: focus))
      }
    }
  }
}

struct OverviewHeader: View {
  let state: LodyState
  let items: [LodyItem]
  let isStale: Bool

  var body: some View {
    HStack(spacing: 12) {
      if state.isCompleted {
        DoneGlyph(size: 36, failed: state.allFailed)
      } else {
        GlyphStack(items: items, size: 36)
      }
      VStack(alignment: .leading, spacing: 3) {
        Text(headline)
          .font(.headline)
          .lineLimit(1)
        HStack(spacing: 5) {
          StatusSymbol(status: headerStatus, isStale: isStale)
          Text(subline)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 0)
    }
  }

  private var headerStatus: LodyItem.Status {
    if !state.isCompleted { return .running }
    return state.allFailed ? .failed : .unread
  }

  private var headline: String {
    if isStale { return state.staleLabel }
    if state.allFailed { return state.failedSummary(state.completedItems.count) }
    return state.isCompleted ? state.completedSummary(state.completedItems.count) : state.runningSummary
  }

  private var subline: String {
    if isStale { return state.lastSyncLabel }
    let hidden = (state.isCompleted ? state.completedItems.count : state.activeCount) - items.count
    if hidden > 0 { return state.othersLabel(hidden) }
    return state.isCompleted ? state.emptyLabel : items.first?.statusLabel ?? ""
  }
}

struct IslandRow: View {
  let item: LodyItem
  let state: LodyState

  var body: some View {
    HStack(spacing: 8) {
      LeadGlyph(item: item, size: 18)
      VStack(alignment: .leading, spacing: 1) {
        FocusTitle(item: item)
          .font(.footnote)
          .foregroundStyle(.secondary)
        if !item.isDone, let step = OthersList.step(of: item) {
          Text(step)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      Spacer(minLength: 4)
      if state.showsTimer(for: item, isStale: false) {
        WorkTimer(item: item)
          .foregroundStyle(.secondary)
      }
    }
  }
}

struct OthersList: View {
  let state: LodyState
  let items: [LodyItem]
  let workspaceSlug: String
  let isStale: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(items, id: \.id) { item in
        Link(destination: LodyActivityAttributes.route(workspaceSlug: workspaceSlug, sessionId: item.id)) {
          HStack(spacing: 8) {
            LeadGlyph(item: item, size: 20)
            VStack(alignment: .leading, spacing: 1) {
              FocusTitle(item: item)
                .font(.footnote)
                .foregroundStyle(.secondary)
              // Several sessions at once: one line each of what it is doing.
              if !isStale, !item.isDone, let step = Self.step(of: item) {
                Text(step)
                  .font(.caption2)
                  .foregroundStyle(.tertiary)
                  .lineLimit(1)
                  .truncationMode(.middle)
              }
            }
            Spacer(minLength: 4)
            if state.showsTimer(for: item, isStale: isStale) {
              WorkTimer(item: item)
                .foregroundStyle(.secondary)
            }
          }
          .frame(minHeight: 34)
          .contentShape(Rectangle())
        }
      }
    }
    .padding(.top, 4)
    .overlay(alignment: .top) { Divider().opacity(0.6) }
  }

  /// The current step, or else the latest reasoning, as a LAN host reported it.
  static func step(of item: LodyItem) -> String? {
    if let activity = item.activity, !activity.isEmpty { return activity }
    if let thought = item.thought, !thought.isEmpty { return thought }
    return nil
  }
}

struct CommandStrip: View {
  let command: String

  var body: some View {
    Text(command)
      .font(.caption.monospaced())
      .lineLimit(1)
      .truncationMode(.middle)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(Color.orange.opacity(0.16))
      )
  }
}

/// `machine / title` once a LAN host names the member running the session.
struct FocusTitle: View {
  let item: LodyItem

  var body: some View {
    Group {
      if let machine = item.machineName, !machine.isEmpty {
        Text(machine).foregroundStyle(.secondary) + Text(" / ").foregroundStyle(.tertiary) + Text(item.title)
      } else {
        Text(item.title)
      }
    }
    .lineLimit(1)
  }
}

/// The step the agent is on, as a LAN host last reported it. Its reasoning
/// is in the status line above.
struct WorkDetail: View {
  let item: LodyItem

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let activity = item.activity, !activity.isEmpty {
        Label {
          Text(activity).lineLimit(1).truncationMode(.middle)
        } icon: {
          Image(systemName: "chevron.forward.2")
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  static func shows(_ item: LodyItem) -> Bool {
    !(item.activity ?? "").isEmpty
  }
}

/// Answers a permission request in place; the app forwards the choice once
/// the device is unlocked.
struct PermissionButtons: View {
  let focus: LodyItem
  let copy: LodyState
  /// The expanded island has a fixed height; its buttons are smaller.
  var compact = false

  var body: some View {
    if let requestId = focus.permissionRequestId, let allow = focus.allowOption {
      HStack(spacing: 8) {
        if let deny = focus.denyOption {
          Button(intent: LodyPermissionIntent(sessionId: focus.id, requestId: requestId, optionId: deny.id)) {
            Text(copy.denyLabel).frame(maxWidth: .infinity, minHeight: compact ? 24 : 32)
          }
          .buttonStyle(.bordered)
        }
        Button(intent: LodyPermissionIntent(sessionId: focus.id, requestId: requestId, optionId: allow.id)) {
          Text(copy.allowLabel).frame(maxWidth: .infinity, minHeight: compact ? 24 : 32)
        }
        .buttonStyle(.borderedProminent)
      }
      .font((compact ? Font.footnote : Font.subheadline).weight(.semibold))
      .controlSize(compact ? .small : .regular)
      .frame(minHeight: compact ? 32 : 44)
    }
  }

  static func shows(_ item: LodyItem) -> Bool {
    item.status == .permission && item.permissionRequestId != nil && item.allowOption != nil
  }
}

struct AttentionBlock: View {
  let focus: LodyItem
  let copy: LodyState

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let command = focus.permissionCommand, focus.status == .permission {
        CommandStrip(command: command)
      }
      if PermissionButtons.shows(focus) {
        PermissionButtons(focus: focus, copy: copy)
      } else {
        Text(copy.openHintLabel)
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
  }
}

/// Apple Watch Smart Stack and CarPlay: the expanded island's content in the
/// card's few lines. A tap on the watch shows this same view full screen, and its
/// buttons run their intents on the paired iPhone.
struct LodyCompactActivityView: View {
  let state: LodyState
  let isStale: Bool

  /// How much of a state to draw, fullest first: `full` is for the full screen a
  /// tap opens, the rest for the card's sizes.
  private enum Detail: CaseIterable {
    case full, roomy, compact, minimal
  }

  var body: some View {
    Group {
      if let focus = state.focus {
        // The card is 152x69.5 to 191x81.5 pt by watch size, and watchOS text runs
        // larger than iOS, so each state offers fuller and tighter layouts and the
        // first that fits the height on offer is drawn. The full screen a tap opens
        // gets the fullest one.
        ViewThatFits(in: .vertical) {
          ForEach(Detail.allCases, id: \.self) { detail in
            VStack(alignment: .leading, spacing: 2) {
              content(focus: focus, detail: detail)
            }
          }
        }
      } else {
        Text(state.emptyLabel)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .lodyStale(isStale)
  }

  @ViewBuilder
  private func content(focus: LodyItem, detail: Detail) -> some View {
    if isStale {
      header(focus: focus, detail: detail)
      HStack(spacing: 4) {
        StatusSymbol(status: focus.status, isStale: true)
        Text(state.lastSyncLabel) + Text(" ") + Text(focus.updatedDate, style: .relative)
      }
      .font(.footnote)
      .foregroundStyle(.secondary)
      .lineLimit(1)
    } else if state.showsOverview {
      header(focus: focus, detail: detail)
      // One line per session with its step under it as room allows; the header
      // already counts the rest.
      let rows = detail == .minimal ? Array(state.visibleItems.prefix(1)) : state.visibleItems
      ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
        overviewRow(item: item, showsStep: detail == .full || (detail == .roomy && index == 0))
      }
    } else if PermissionButtons.shows(focus) {
      // The decision needs the command and both answers; the title gives way first.
      // Fuller layouts wrap the command so it can be read before answering, and
      // keep the title to one line to leave it the room.
      switch detail {
      case .full, .roomy: header(focus: focus, detail: .roomy)
      case .compact:
        Text(focus.title)
          .font(.footnote.weight(.semibold))
          .lineLimit(1)
      case .minimal: EmptyView()
      }
      withTimer(focus) {
        Text(focus.permissionCommand ?? focus.statusLabel)
          .font(.footnote.monospaced())
          .foregroundStyle(.orange)
          .lineLimit(Self.commandLines[detail] ?? 1)
          .truncationMode(.middle)
      }
      WatchPermissionButtons(focus: focus, copy: state)
    } else if focus.status == .running {
      header(focus: focus, detail: detail)
      runningDetail(focus: focus, detail: detail)
    } else {
      header(focus: focus, detail: detail)
      statusLine(focus: focus)
      if detail != .minimal {
        if focus.status == .permission, let command = focus.permissionCommand {
          Text(command)
            .font(.footnote.monospaced())
            .foregroundStyle(.orange)
            .lineLimit(1)
            .truncationMode(.middle)
        } else if !focus.isDone {
          Text(state.openHintLabel)
            .font(.footnote)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
      }
    }
  }

  private static let thoughtLines: [Detail: Int] = [.full: 5, .roomy: 2, .compact: 1]
  private static let commandLines: [Detail: Int] = [.full: 6, .roomy: 3]

  private func header(focus: LodyItem, detail: Detail) -> some View {
    HStack(spacing: 6) {
      if state.showsOverview {
        JellyMark()
        Text(isStale ? state.staleLabel : state.runningSummary)
          .font(.headline)
          .lineLimit(1)
      } else {
        LeadGlyph(item: focus, size: 18)
        // The card is too narrow for the machine prefix or a timer beside the
        // title, so the title has the row to itself and the timer goes below.
        Text(focus.title)
          .font(.headline)
          .lineLimit(detail == .full ? 2 : 1)
      }
      Spacer(minLength: 0)
    }
  }

  /// A line of detail with the focus's timer at its trailing edge.
  private func withTimer(_ focus: LodyItem, @ViewBuilder _ content: () -> some View) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 4) {
      content()
      Spacer(minLength: 2)
      if state.showsTimer(for: focus, isStale: isStale) {
        WorkTimer(item: focus, font: .footnote.weight(.semibold).monospacedDigit(), width: 44)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func overviewRow(item: LodyItem, showsStep: Bool) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 5) {
        LeadGlyph(item: item, size: 14)
        Text(item.title)
          .font(.footnote)
          .lineLimit(1)
        Spacer(minLength: 2)
        if state.showsTimer(for: item, isStale: false) {
          WorkTimer(item: item, font: .footnote.monospacedDigit(), width: 44)
            .foregroundStyle(.secondary)
        }
      }
      if showsStep, let step = OthersList.step(of: item) {
        Text(step)
          .font(.footnote)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .truncationMode(.middle)
          .padding(.leading, 19)
      }
    }
  }

  /// The reasoning in place of "Working", then the step or who else runs, with
  /// the timer on whichever line ends the card.
  @ViewBuilder
  private func runningDetail(focus: LodyItem, detail: Detail) -> some View {
    if let thought = focus.thought, !thought.isEmpty, detail != .minimal {
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        StatusSymbol(status: .running)
        Text(thought)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .lineLimit(Self.thoughtLines[detail] ?? 1)
          .truncationMode(.head)
      }
      withTimer(focus) { runningFooter(focus: focus) }
    } else if focus.thought?.isEmpty == false {
      // Tightest: the step alone, or else the newest words of the reasoning.
      withTimer(focus) {
        if WorkDetail.shows(focus) {
          runningFooter(focus: focus)
        } else {
          Text(focus.thought ?? "")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.head)
        }
      }
    } else {
      statusLine(focus: focus)
      if detail != .minimal {
        runningFooter(focus: focus)
      }
    }
  }

  @ViewBuilder
  private func runningFooter(focus: LodyItem) -> some View {
    if let activity = focus.activity, !activity.isEmpty {
      Label {
        Text(activity).lineLimit(1).truncationMode(.middle)
      } icon: {
        Image(systemName: "chevron.forward.2")
      }
      .font(.footnote)
      .foregroundStyle(.tertiary)
    } else if state.othersCount > 0 {
      Text(state.othersLabel(state.othersCount))
        .font(.footnote)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }
  }

  private func statusLine(focus: LodyItem) -> some View {
    withTimer(focus) {
      StatusSymbol(status: focus.status)
      Text(focus.statusLabel)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
  }
}

/// The watch card's answers: short capsules instead of watchOS's full-height
/// buttons, which alone would fill the card.
private struct WatchPermissionButtons: View {
  let focus: LodyItem
  let copy: LodyState

  var body: some View {
    if let requestId = focus.permissionRequestId, let allow = focus.allowOption {
      HStack(spacing: 6) {
        if let deny = focus.denyOption {
          Button(intent: LodyPermissionIntent(sessionId: focus.id, requestId: requestId, optionId: deny.id)) {
            pill(copy.denyLabel, prominent: false)
          }
          .buttonStyle(.plain)
        }
        Button(intent: LodyPermissionIntent(sessionId: focus.id, requestId: requestId, optionId: allow.id)) {
          pill(copy.allowLabel, prominent: true)
        }
        .buttonStyle(.plain)
      }
    }
  }

  private func pill(_ label: String, prominent: Bool) -> some View {
    Text(label)
      .font(.footnote.weight(.semibold))
      .lineLimit(1)
      .foregroundStyle(prominent ? Color.white : Color.primary)
      .frame(maxWidth: .infinity, minHeight: 28)
      .background(Capsule().fill(prominent ? Color.blue : Color.gray.opacity(0.3)))
      .contentShape(Capsule())
  }
}

struct LodyLockScreenView: View {
  let state: LodyState
  let workspaceSlug: String
  var overviewRoute: URL = URL(string: "lody:///activity")!
  let isStale: Bool

  var body: some View {
    content
      .padding(.horizontal, 16)
      .padding(.vertical, 14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background {
        ZStack {
          LinearGradient(
            colors: [.black.opacity(0.58), .black.opacity(0.24), .clear],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
          wash
          JellyGlow(opacity: isStale ? 0.15 : 0.42)
        }
        .mask {
          LinearGradient(
            stops: [
              .init(color: .clear, location: 0),
              .init(color: .white, location: 0.2),
              .init(color: .white, location: 0.8),
              .init(color: .clear, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
          )
        }
        .mask {
          LinearGradient(
            stops: [
              .init(color: .clear, location: 0),
              .init(color: .white, location: 0.3),
              .init(color: .white, location: 0.7),
              .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
          )
        }
        .padding(6)
      }
      .lodyStale(isStale)
  }

  @ViewBuilder
  private var content: some View {
    if let focus = state.focus {
      VStack(alignment: .leading, spacing: 10) {
        if state.showsOverview || (state.isCompleted && state.completedItems.count > 1) {
          OverviewHeader(state: state, items: state.visibleItems, isStale: isStale)
          OthersList(state: state, items: state.visibleItems, workspaceSlug: workspaceSlug, isStale: isStale)
        } else {
          Link(destination: LodyActivityAttributes.route(workspaceSlug: workspaceSlug, sessionId: focus.id)) {
            FocusRow(state: state, focus: focus, isStale: isStale, glyphSize: 36)
              .frame(minHeight: 44)
          }
          if !isStale, state.needsAttention {
            AttentionBlock(focus: focus, copy: state)
          } else if !isStale, !focus.isDone, WorkDetail.shows(focus) {
            WorkDetail(item: focus)
          }
        }
      }
      .widgetURL(state.showsOverview ? overviewRoute : LodyActivityAttributes.route(workspaceSlug: workspaceSlug, sessionId: focus.id))
    } else {
      Text(state.emptyLabel)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  @ViewBuilder
  private var wash: some View {
    if isStale {
      Color.clear
    } else if state.needsAttention {
      LinearGradient(colors: [Color.orange.opacity(0.2), .clear], startPoint: .topLeading, endPoint: UnitPoint(x: 0.6, y: 1))
    } else if state.isCompleted {
      LinearGradient(colors: [LodyTone.blue.opacity(0.16), LodyTone.teal.opacity(0.08), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
    } else {
      Color.clear
    }
  }
}

extension View {
  @ViewBuilder
  func lodyStale(_ isStale: Bool) -> some View {
    if isStale {
      opacity(0.7)
    } else {
      self
    }
  }
}
