import CoreGraphics
import Foundation
import LodyCore

struct ChatFileDiff: Decodable, Equatable {
  let path: String
  let add: Int?
  let del: Int?
  let status: String?
}

struct ChatEntry: Decodable {
  struct ModelInfo: Decodable {
    let modelId: String?
    let name: String?
    let thoughtLevel: String?

    var title: String {
      let name = self.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let model = name.isEmpty ? (modelId ?? "") : name
      return [model, thoughtLevel ?? ""]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }.joined(separator: " · ")
    }
  }
  struct Author: Decodable, Sendable {
    struct Role: Decodable, Sendable {
      let name: String
      let instanceLabel: String?
    }
    let kind: String
    let name: String?
    let role: Role?
    let model: String?

    var title: String? {
      guard kind == "agent", let name else { return nil }
      let roleTitle = role.map { [$0.name, $0.instanceLabel].compactMap { $0 }.joined(separator: " · ") }
      return [roleTitle, name, model].compactMap { $0 }.joined(separator: " · ")
    }
  }
  var author: Author? = nil
  let id: String
  let role: String
  let status: String
  var finished: Bool
  let timestamp: String?
  let endedAt: Double?
  let startedAt: Double?
  var permissionWaitMs: Double? = nil
  var items: [ChatItem]
  let fileDiffs: [ChatFileDiff]?
  var inputConfig: ChatTurnInput? = nil
  var tokenUsage: ChatTurnUsage? = nil
  var modelInfo: ModelInfo? = nil
  var userTurnId: String? = nil
  /// A user turn's sender, for its avatar and name.
  var userId: String? = nil
  var executionId: String? = nil
  var executionFinished: Bool? = nil
  var steerCount: Int? = nil
  var delivery: String? = nil
  /// A delivered continuation uses a compact marker; uncertain deliveries retain their prompt.
  var deliveryKind: String? = nil
  var inputState: String? = nil
  var inputRetryable: Bool? = nil
  var holdOpen: Bool? = nil
  var canSteer: Bool? = nil
  var isRunning: Bool { role == "assistant" && !finished }
  var isQueued: Bool { role == "user" && status == "queued" }
  /// A later visible process settles earlier prose, even while the turn runs.
  var textTailID: String? {
    guard let item = items.last(where: {
      !$0.hidesFromTranscript && !($0.type == "system_notice" && $0.name == nil)
    }), item.type == "text" || item.type == "thought" else { return nil }
    return item.itemId
  }
}

extension ChatEntry {
  /// Web `PlanExitBlock`: a plan-approval card (ACP `switch_mode`) that carries its plan
  /// (Claude's `rawInput.plan`, Kimi's content) shows it as the turn's plan, directly above the
  /// decision, with the same surface as a `proposed_plan`. A turn that already renders its own
  /// `proposed_plan` (Codex, web `hasSeparatePlanItem`) keeps only that one, or the plan would
  /// print twice. Idempotent: the inserted plan is itself a `proposed_plan`.
  static func showingCarriedPlans(_ entries: [ChatEntry]) -> [ChatEntry] {
    entries.map { entry in
      guard entry.role == "assistant",
            entry.items.contains(where: { $0.carriedPlan != nil }),
            !entry.items.contains(where: { $0.type == "proposed_plan" && !$0.hidesFromTranscript }) else { return entry }
      var result = entry
      result.items = entry.items.flatMap { item -> [ChatItem] in
        guard let markdown = item.carriedPlan else { return [item] }
        var plan = item
        plan.itemId = ChatItem.carriedPlanID(item.itemId)
        plan.type = "proposed_plan"
        plan.markdown = markdown
        plan.status = "completed"
        plan.isLatest = true
        plan.permission = nil
        plan.plan = nil
        return [plan, item]
      }
      return result
    }
  }
}

extension ChatItem {
  static func carriedPlanID(_ itemId: String) -> String { itemId + ":plan" }

  var carriedPlan: String? {
    guard type == "tool_call", kind == "switch_mode",
          let plan = plan?.trimmingCharacters(in: .whitespacesAndNewlines), !plan.isEmpty else { return nil }
    return plan
  }
}

struct ChatImage: Codable, Equatable, Sendable {
  let id: String
  let fileName: String
  let storageSessionId: String?
  let width: Double?
  let height: Double?
  var transport: String? = nil
  var machineId: String? = nil
  var localImageId: String? = nil
  var sha256: String? = nil
  var sizeBytes: Int? = nil
  var mimeType: String? = nil

  /// True for images served over the LAN `files` channel (either legacy kept
  /// file blocks with `sha256` or local-first `image` blocks with `localImageId`).
  var isLANKept: Bool {
    if sha256 != nil, machineId != nil { return true }
    return transport == "local" && localImageId != nil
  }

  /// Stable disk/notification key inside `LanImageCache`.
  var lanCacheKey: String? {
    if let sha256 { return sha256.lowercased() }
    if transport == "local", let localImageId { return "local-\(localImageId.lowercased())" }
    return nil
  }
}

struct ChatMessageAttachment: Decodable, Equatable, Sendable {
  let id: String
  let fileName: String
  var image: ChatImage? = nil
  var localURI: String? = nil
  var localID: String? = nil
  var storageSessionId: String? = nil
  var transport: String? = nil
  var sizeBytes: Int? = nil
  var mimeType: String? = nil
  var machineId: String? = nil
  var sha256: String? = nil
  var path: String? = nil
  var kind: String? = nil

  var isLocalAttachment: Bool {
    transport == "local_attachment" && path != nil && machineId != nil
  }

  /// A LAN keeps a message's pictures as files; one an agent reads, small
  /// enough to fetch on sight, shows as the picture.
  var shownAsImage: ChatMessageAttachment {
    guard image == nil, transport == "local", let machineId, let sha256, let sizeBytes,
          sizeBytes <= 10 * 1024 * 1024,
          ["image/png", "image/jpeg", "image/webp", "image/gif"].contains(mimeType ?? "") else { return self }
    var picture = self
    picture.image = ChatImage(id: id, fileName: fileName, storageSessionId: storageSessionId, width: nil, height: nil,
                              transport: transport, machineId: machineId, sha256: sha256, sizeBytes: sizeBytes, mimeType: mimeType)
    return picture
  }
}

struct ChatOperationCard: Decodable, Equatable {
  let id: String
  let kind: String
  let sessionId: String
  let label: String?
  let status: String
  let detail: String?
  let reply: String?
  var replyTruncated: Bool? = nil

  var statusLabel: String {
    let prefix = kind == "reply" ? "session.operation.reply." : "session.operation.status."
    return String(localized: String.LocalizationValue(prefix + status), bundle: .lody)
  }
  var opening: String {
    (detail ?? reply ?? "").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
  }
}

struct ChatOperationPresentation: Decodable {
  struct Notice: Decodable {
    let kind: String
    let detail: String?
    let count: Int?
  }
  let cards: [ChatOperationCard]
  let notices: [Notice]

  func rows(entryID: String, itemID: String) -> [ChatRow] {
    let prefix = entryID + ":" + itemID
    var rows: [ChatRow] = []
    for (index, notice) in notices.enumerated() {
      var title = String(localized: String.LocalizationValue("session.operation." + notice.kind), bundle: .lody)
      if let count = notice.count { title = String.localizedStringWithFormat(title, count) }
      rows.append(ChatRow(id: prefix + ":notice:\(index)", entryID: entryID, kind: "operationNotice", text: title,
        itemID: itemID, detail: notice.detail ?? ""))
    }
    let created = cards.filter { $0.kind == "created" }
    if !created.isEmpty {
      rows.append(ChatRow(id: prefix + ":created", entryID: entryID, kind: "operationHeader",
        text: String.localizedStringWithFormat(String(localized: "session.operation.createdCount", bundle: .lody), created.count),
        itemID: itemID, actionable: created.count > 5))
    }
    for card in cards {
      rows.append(ChatRow(id: prefix + ":card:" + card.id, entryID: entryID, kind: "operationCard",
        text: card.label ?? "", itemID: itemID, actionable: true, operation: card, detail: card.opening))
    }
    return rows
  }

  /// Keep large creation groups compact without losing their rows from history.
  static func visible(_ rows: [ChatRow], expanded: Set<String>, titles: [String: String]) -> [ChatRow] {
    var grouped: [ChatRow] = []
    var pending: [ChatRow] = []
    var groupForRow: [String: String] = [:]
    func flush() {
      guard var header = pending.first else { return }
      let cards = pending.filter { $0.operation != nil }
      let group = header.entryID + ":" + header.itemID
      header.text = String.localizedStringWithFormat(String(localized: "session.operation.createdCount", bundle: .lody), cards.count)
      header.actionable = cards.count > 5
      grouped.append(header)
      for card in cards { groupForRow[card.id] = group; grouped.append(card) }
      pending.removeAll()
    }
    for row in rows {
      if row.kind == "operationHeader" || row.operation?.kind == "created" { pending.append(row) }
      else { flush(); grouped.append(row) }
    }
    flush()
    var counts: [String: Int] = [:]
    return grouped.compactMap { source in
      var row = source
      let group = groupForRow[row.id] ?? (row.entryID + ":" + row.itemID)
      if row.kind == "operationHeader" { row.disclosed = expanded.contains(group) }
      if let card = row.operation {
        if card.kind == "created" {
          counts[group, default: 0] += 1
          if counts[group, default: 0] > 5 && !expanded.contains(group) { return nil }
        }
        row.text = titles[card.sessionId]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if row.text.isEmpty { row.text = card.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        if row.text.isEmpty { row.text = String(localized: "session.operation.untitled", bundle: .lody) }
        row.actionable = titles[card.sessionId] != nil
      }
      return row
    }
  }
}

struct ChatItem: Decodable {
  var references: [ChatTextReference]? = nil
  struct Permission: Decodable {
    /// Lenient: a malformed option must not fail the whole transcript decode.
    struct Option: Decodable { let optionId: String?; let name: String? }
    let requestId: String
    let pending: Bool
    var options: [Option]? = nil
    /// The option a settled request was answered with (runtime `chosenOptionId`).
    var chosenOptionId: String? = nil
    var withdrawn: Bool? = nil
  }
  struct Plan: Decodable { let content: String; let status: String }
  struct ProposalFields: Decodable, Equatable, Sendable {
    let name: String?
    let description: String?
    let promptPrefix: String?
  }
  struct ProposalCommand: Decodable, Equatable, Sendable {
    let action: String
    let name: String?
    let description: String?
    let promptPrefix: String?
    let patch: ProposalFields?
  }
  struct NoticeMeta: Decodable, Equatable, Sendable {
    let reason: String?
    let code: String?
    let message: String?
    var trigger: String? = nil
    var status: String? = nil
    var kind: String? = nil
    var generation: Int? = nil
    var nodeId: String? = nil
    var usedBefore: Double? = nil
    var usedAfter: Double? = nil
    var foldedCount: Int? = nil
    var foldId: String? = nil
    var command: ProposalCommand? = nil
    var before: ProposalFields? = nil
    var outcome: String? = nil
    var source: String? = nil
    var sourceSessionId: String? = nil
    var sourceTitle: String? = nil
    var truncated: Bool? = nil
  }
  struct OperationMember: Decodable, Sendable {
    let title: String
    let status: String
  }
  /// One command of a `worktree_script` with the tail of its output.
  struct ScriptStep: Decodable, Equatable { let command: String; let status: String; let output: String }
  var memberCount: Int? = nil
  var members: [OperationMember]? = nil
  var deliveryStatus: String? = nil
  var operation: ChatOperationPresentation? = nil
  var meta: NoticeMeta? = nil
  /// An Agent's Role or schedule proposal carried by a `system_notice` (web proposal notices).
  var proposal: ChatProposal? = nil
  var isOrchestration: Bool {
    type == "operation_completion_batch" || type == "operation_completion"
      || (type == "system_notice" && ["board_context_maintenance", "board_chain_limit", "agent_role_proposal", "session_context_rollover"].contains(name ?? ""))
  }
  /// Matches Lody `isSilentBoardMaintenance` and `isSilentSessionRollover`.
  var isSilentNotice: Bool {
    guard type == "system_notice" else { return false }
    if name == "board_context_maintenance" {
      return meta?.trigger == "idle" && meta?.status == "interrupted"
    }
    if name == "session_context_rollover" {
      return (meta?.trigger == "auto" || meta?.trigger == "recovery") && meta?.status == "interrupted"
    }
    return false
  }
  var isChatFailure: Bool { type == "system_notice" && name == "chat_failed" }
  /// Web system rows (notices and worktree scripts) stand on their own; they never fold into work.
  var isNotice: Bool { (type == "system_notice" && name != nil) || type == "worktree_script" }
  var phase: String? = nil
  var steps: [ScriptStep]? = nil
  var itemId: String
  var type: String
  let name: String?
  var text: String?
  let kind: String?
  let title: String?
  var status: String?
  let path: String?
  let hasDetail: Bool?
  var permission: Permission?
  /// Plan text a plan-approval card (`switch_mode`) carries (runtime `planExitMarkdown`).
  var plan: String? = nil
  let entries: [Plan]?
  let description: String?
  let actor: String?
  var markdown: String? = nil
  var isLatest: Bool? = nil
  var lastToolName: String? = nil
  var summary: String? = nil
  var error: String? = nil
  var isBackgrounded: Bool? = nil
  var skipTranscript: Bool? = nil
  var processDurationMs: Int? = nil
  var run: ChatSubagentRun? = nil
  /// Web `isProcessStatusToolCall`: `context_compaction` reads as a one-line status, not a tool.
  var activityKind: String? = nil
  var isContextCompaction: Bool { type == "tool_call" && activityKind == "context_compaction" }
  var isProcess: Bool { !isOrchestration && operation == nil && proposal == nil && type != "text" && type != "proposed_plan" && !isAttachment && !isNotice && type != "subagent_task" }
  var hidesFromTranscript: Bool {
    if let operation { return operation.cards.isEmpty && operation.notices.isEmpty }
    if type == "proposed_plan" {
      return !["delta", "completed"].contains(status ?? "") || (markdown ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    return type == "subagent_task" && skipTranscript == true
  }
  var isLiveSubagent: Bool {
    type == "subagent_task" && skipTranscript != true && ["in_progress", "pending"].contains(ChatSubagentCard.status(self))
  }
  let image: ChatImage?
  var file: ChatMessageAttachment? = nil
  var images: [ChatImage]? = nil
  var isImage: Bool { type == "image" || type == "image_group" }
  var isAttachment: Bool { isImage || type == "file" || type == "local_attachment" }
}

struct ChatSubagentRun: Decodable {
  var state: String
  var outputIncomplete: Bool? = nil
  var items: [ChatItem]? = nil
}

struct ChatRow: Equatable {
  let id: String
  let entryID: String
  var kind: String
  var text: String
  var references: [ChatTextReference] = []
  var errorMeta: ChatItem.NoticeMeta? = nil
  var errorRetry: ChatErrorRetryState? = nil
  /// The failure asks for agent sign-in and this session's agent can start it from here.
  var errorSignIn = false
  var planIsLatest = true
  var planPermissionItemID = ""
  var planDecision: ChatPlanDecisionState? = nil
  var symbol = ""
  var itemID = ""
  var processStartID = ""
  var actionable = false
  var running = false
  var attention = false
  var streaming = false
  var localImageURI: String? = nil
  var image: ChatImage? = nil
  /// An `imageStack` row: the consecutive images it fans together, each keeping its own
  /// single-image row id so the preview, sharing and zoom sources address it individually.
  var stack: [ChatImagePreviewItem] = []
  var file: ChatMessageAttachment? = nil
  var fileDiff: ChatFileDiff? = nil
  var fileDiffs: [ChatFileDiff] = []
  var attachments: [ChatMessageAttachment] = []
  var uploadProgress: [String: ChatAttachmentUploadProgress] = [:]
  var workDurationMs: Int? = nil
  var imageAsset = ""
  var subagent: ChatSubagentCard? = nil
  var operation: ChatOperationCard? = nil
  var proposal: ChatProposal? = nil
  /// The signed-in user may decide this proposal (a Role proposal binds its requester).
  var proposalDecidable = false
  var proposalState: ChatProposalState? = nil
  /// A `schedule_edit` proposal's live schedule (runtime `inspectProposal`); nil until read.
  var proposalInspection: RuntimeContract.InspectProposalResult? = nil
  var operationCurrent = false
  var operationPeers: [ChatOperationPeer] = []
  var operationCLIType: String? = nil
  var operationAgentType: String? = nil
  var detail = ""
  var treeChild = false
  var treeLast = false
  var treeDown = false
  var shines: Bool { running && kind != "duration" }
  /// `only` / `first` / `middle` / `last` for consecutive file rows in one group.
  var group = ""
  /// A "Worked for …" row whose folded work is open in place (its chevron points down).
  var disclosed = false
  /// A user turn's first row: its sender's user id (`ChatAuthors.unknownSender` when the turn
  /// predates the field or is a local send), when, and whether the agent picked it up
  /// (`seen` / `sent` / `queued` / `sending`), drawn above the bubble with the avatar beside it.
  var author = ""
  var authorImage = ""
  var authorName = ""
  var authorTime = ""
  var readState = ""
  /// Delegated agent/role author label rendered inside a user bubble (e.g., Board orchestration).
  var delegatedAuthor: String? = nil
}

/// Formatting shared by user-turn headers and local sends.
enum ChatAuthors {
  /// Turns without a recorded sender: older history, and this device's own sends.
  static let unknownSender = "-"

  static func time(_ timestamp: String?) -> String {
    guard let timestamp,
      let date = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(timestamp)) ?? (try? Date.ISO8601FormatStyle().parse(timestamp))
    else { return "" }
    if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
    return date.formatted(.dateTime.month(.defaultDigits).day().hour().minute())
  }

  static func readState(_ status: String) -> String {
    switch status {
    // Execution outcomes acknowledge receipt even if the run failed or was canceled.
    case "seen", "processing", "handled", "failed", "canceled", "completed", "done": "seen"
    case "queued": "queued"
    default: "sent"
    }
  }
}

enum ChatMetaTime {
  static let relativeDayLimit = 7

  static func label(_ endedAt: Double?, now: Double, calendar: Calendar = .current) -> String {
    guard let endedAt, endedAt.isFinite, endedAt > 0, now.isFinite else { return "" }
    let ended = Date(timeIntervalSince1970: endedAt / 1000)
    let current = Date(timeIntervalSince1970: now / 1000)
    if calendar.isDate(ended, inSameDayAs: current) {
      return ended.formatted(date: .omitted, time: .shortened)
    }
    let days = calendar.dateComponents(
      [.day], from: calendar.startOfDay(for: ended), to: calendar.startOfDay(for: current)
    ).day
    guard let days, days >= 1, days < relativeDayLimit else {
      return ended.formatted(date: .abbreviated, time: .omitted)
    }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter.localizedString(from: DateComponents(day: -days))
  }
}

enum ChatWorkDuration {
  private static let fractionalTimestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
  private static let timestamp = Date.ISO8601FormatStyle()

  static func startMilliseconds(for entry: ChatEntry) -> Double? {
    let parsedTimestamp = entry.timestamp.flatMap {
      (try? fractionalTimestamp.parse($0)) ?? (try? timestamp.parse($0))
    }
    return parsedTimestamp.map { $0.timeIntervalSince1970 * 1000 } ?? entry.startedAt
  }

  static func milliseconds(for entry: ChatEntry, now: Double, startOverride: Double? = nil) -> Int? {
    let start = startOverride ?? startMilliseconds(for: entry)
    let end = entry.finished ? entry.endedAt : now
    guard let start, let end, start.isFinite, end.isFinite, end >= start,
          end - start <= Double(Int.max) else { return nil }
    var wait = 0.0
    if let written = entry.permissionWaitMs, written.isFinite, written > 0,
       written <= Double(Int.max)
    {
      wait = written
    }
    return Int(max(0, end - start - wait))
  }

  static func needsTimer(_ rows: [ChatRow]) -> Bool {
    rows.contains { $0.kind == "duration" && $0.running && $0.workDurationMs != nil }
  }

  static func format(
    _ milliseconds: Int,
    hour: String,
    minute: String,
    second: String
  ) -> String {
    guard milliseconds >= 0 else { return "" }
    let totalSeconds = milliseconds / 1000
    let hours = totalSeconds / 3600
    let minutes = totalSeconds % 3600 / 60
    let seconds = totalSeconds % 60
    if hours > 0 {
      return "\(hours)\(hour) \(pad2(minutes))\(minute) \(pad2(seconds))\(second)"
    }
    if minutes > 0 {
      return "\(minutes)\(minute) \(pad2(seconds))\(second)"
    }
    return "\(seconds)\(second)"
  }

  private static func pad2(_ value: Int) -> String {
    value < 10 ? "0\(value)" : String(value)
  }

  static func label(_ milliseconds: Int) -> String {
    format(
      milliseconds,
      hour: String(localized: "native.chat.duration.hour", bundle: .lody),
      minute: String(localized: "native.chat.duration.minute", bundle: .lody),
      second: String(localized: "native.chat.duration.second", bundle: .lody)
    )
  }

  static func title(_ milliseconds: Int, running: Bool) -> String {
    let key = running ? "native.chat.transcript.status.workingFor" : "native.chat.transcript.status.workedFor"
    return String.localizedStringWithFormat(String(localized: String.LocalizationValue(key), bundle: .lody), label(milliseconds))
  }
}

/// Conversation stays readable on wide hosts; the scroll view itself stays full-bleed
/// so the vertical indicator remains on the screen edge.
enum ChatReadingColumn {
  static let maximumWidth: CGFloat = 800
  /// Web's mobile conversation inset.
  static let cellMargin: CGFloat = 16
  static let sectionTop: CGFloat = 4
  static let sectionBottom: CGFloat = 4

  static func columnWidth(in collectionWidth: CGFloat) -> CGFloat {
    min(max(1, collectionWidth), maximumWidth)
  }

  static func horizontalInset(in collectionWidth: CGFloat) -> CGFloat {
    (max(0, collectionWidth - columnWidth(in: collectionWidth)) / 2) + cellMargin
  }

  static func itemWidth(in collectionWidth: CGFloat) -> CGFloat {
    max(1, collectionWidth - horizontalInset(in: collectionWidth) * 2)
  }
}

enum ChatTranscriptPreviewMetrics {
  static let width: CGFloat = 320
  static let sectionInset: CGFloat = 16
  static let symbolGutter: CGFloat = 36

  static func itemWidth(collectionWidth: CGFloat) -> CGFloat {
    let width = collectionWidth > 1 ? collectionWidth : Self.width
    return max(1, width - sectionInset * 2)
  }

  static func textWidth(itemWidth: CGFloat, hasSymbol: Bool) -> CGFloat {
    if !hasSymbol { return itemWidth }
    return max(1, itemWidth - symbolGutter)
  }
}

/// The text a finished assistant turn keeps beside its folded work, following
/// Lody's `shouldCollapseAssistantMessageItem`.
enum ChatAnswerText {
  static let substantiveLength = 300

  /// Agents narrate while they work; those short lines fold with it. A long or
  /// structured block (list, table, heading) is a report, typically a complete
  /// answer that a background task's followup appended a short note after.
  /// Length counts UTF-16 units, as Lody's does.
  static func isSubstantive(_ text: String) -> Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count >= substantiveLength
      || text.range(of: #"(?:^|\n)[ \t]*(?:[-*+] |[0-9]+[.)] |\||#{1,6} )"#, options: .regularExpression) != nil
  }

  /// Ascending indices of the visible text. The closing run is the last
  /// contiguous text before the never-folded tail. When it is thin it reads as a
  /// postscript, so the one text run before the work it follows stays with it,
  /// whatever its length. Earlier substantive text stays too. A turn that ends
  /// in work keeps only its last text.
  static func visibleIndices(_ items: [ChatItem]) -> [Int] {
    let texts = items.indices.filter {
      items[$0].type == "text" && !(items[$0].text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var end = items.count
    while end > 0, trailsAnswer(items[end - 1]) { end -= 1 }
    var start = end
    while start > 0, items[start - 1].type == "text" { start -= 1 }
    guard start < end else { return texts.last.map { [$0] } ?? [] }
    if !isSubstantive(items[start..<end].compactMap(\.text).joined(separator: "\n\n")),
       var earlier = items[..<start].lastIndex(where: { $0.type == "text" }) {
      while earlier > 0, items[earlier - 1].type == "text" { earlier -= 1 }
      start = earlier
    }
    return texts.filter { $0 >= start || isSubstantive(items[$0].text ?? "") }
  }

  /// Never folded, so a turn ending in one still closes in its text.
  private static func trailsAnswer(_ item: ChatItem) -> Bool {
    ["image", "image_group", "file", "plan", "goal", "proposed_plan", "system_notice", "subagent_task"].contains(item.type)
      || (item.type == "tool_call" && item.kind == "switch_mode")
  }
}

/// Stable identities belong to the protocol, never to the streamed text.
struct ChatTranscript {
  var entries: [ChatEntry] = []
  /// Finished turns whose folded work the reader opened in place, by entry id.
  var expandedWork: Set<String> = []
  var expandedThoughts: Set<String> = []

  func liveSubagentItems() -> [ChatItem] {
    entries.flatMap(\.items).filter(\.isLiveSubagent)
  }

  private struct CachedEnvelope: Decodable {
    let entries: [ChatEntry]?
  }

  static func previewRows(from cache: String) -> [ChatRow] {
    guard let data = cache.data(using: .utf8) else { return [] }
    if let envelope = try? JSONDecoder().decode(CachedEnvelope.self, from: data),
       let entries = envelope.entries {
      return ChatTranscript(entries: ChatEntry.showingCarriedPlans(entries)).rows().filter { $0.kind != "meta" }
    }
    if let entries = try? JSONDecoder().decode([ChatEntry].self, from: data) {
      return ChatTranscript(entries: ChatEntry.showingCarriedPlans(entries)).rows().filter { $0.kind != "meta" }
    }
    return []
  }

  /// Provider-proven continuation groups retain original row identities. Only
  /// the finished presentation moves user bubbles above the combined process.
  func rows(
    processEntryID: String = "",
    processStartID: String = "",
    now: Double = Date().timeIntervalSince1970 * 1000,
    turnStartedAt: [String: Double] = [:]
  ) -> [ChatRow] {
    if processStartID == "__tasks__" {
      return entries.flatMap { entry in
        entry.items.compactMap { item -> ChatRow? in
          guard item.type == "subagent_task", item.skipTranscript != true else { return nil }
          return ChatTranscript.subagentRow(entry: entry, item: item)
        }
      }.groupedSubagents()
    }
    let groups = Dictionary(grouping: entries.filter { $0.executionId != nil }, by: { $0.executionId! })
    if processStartID == "__execution__",
       let groupID = entries.first(where: { $0.id == processEntryID })?.executionId,
       let members = groups[groupID] {
      return executionProcess(members).groupedSubagents()
    }
    if !processEntryID.isEmpty {
      return entryRows(processEntryID: processEntryID, processStartID: processStartID, now: now, turnStartedAt: turnStartedAt,
        flatItems: processStartID == "__subagent__").groupedSubagents()
    }
    let ordinary = Dictionary(grouping: entryRows(now: now, turnStartedAt: turnStartedAt), by: \.entryID)
    var emitted = Set<String>()
    return entries.flatMap { entry -> [ChatRow] in
      if let groupID = entry.executionId, let members = groups[groupID],
         let tail = members.last(where: { $0.role == "assistant" }),
         tail.executionFinished == true, members.filter({ $0.role == "assistant" }).allSatisfy(\.finished), !executionResultIDs(tail).isEmpty {
        guard emitted.insert(groupID).inserted else { return [] }
        let users = members.filter { $0.role == "user" && $0.id == groupID }.flatMap {
          ChatTranscript(entries: [$0]).entryRows(now: now)
        }
        let process = executionProcess(members)
        var result = users
        if !process.isEmpty {
          result.append(ChatRow(id: groupID + ":execution", entryID: tail.id, kind: "summary",
            text: String.localizedStringWithFormat(String(localized: "native.chat.transcript.execution", bundle: .lody), String(describing: String(tail.steerCount ?? 0))),
            symbol: "", processStartID: "__execution__", actionable: true))
        }
        result += members.filter { $0.role == "assistant" }.flatMap {
          ChatTranscript(entries: [$0]).entryRows(processEntryID: $0.id, flatItems: true).filter { $0.kind == "proposed_plan" }
        }
        let ids = executionResultIDs(tail)
        result += ChatTranscript(entries: [tail]).entryRows(processEntryID: tail.id, flatItems: true).filter { ids.contains($0.itemID) }
        result += ChatTranscript(entries: [tail]).entryRows(now: now).filter { ["meta", "changesHeader", "changes"].contains($0.kind) }
        return result
      }
      var visible = entry
      if entry.holdOpen == true || entry.executionId != nil { visible.finished = false }
      var result = ChatTranscript(entries: [visible], expandedThoughts: expandedThoughts).entryRows(now: now, turnStartedAt: turnStartedAt)
      if entry.finished && !visible.finished {
        result.removeAll { $0.kind == "duration" }
        for index in result.indices {
          result[index].streaming = false
          result[index].running = false
        }
      }
      // Preserve existing duration attribution for ordinary conversation rows.
      if entry.executionId == nil && entry.holdOpen != true {
        return ChatTranscript.hangSubagents(ordinary[entry.id] ?? [])
      }
      return ChatTranscript.hangSubagents(result)
    }.groupedSubagents()
  }

  private static func compactTokenRange(before: Double?, after: Double?) -> String? {
    guard let before, let after, before.isFinite, after.isFinite, before >= 0, after >= 0 else { return nil }
    let style = FloatingPointFormatStyle<Double>.number.notation(.compactName).precision(.fractionLength(0...1))
    return "\(before.formatted(style)) → \(after.formatted(style))"
  }

  private static func rolloverDivider(_ meta: ChatItem.NoticeMeta?) -> String? {
    guard let meta, let status = meta.status else { return nil }
    let gen = max(1, meta.generation ?? 1)
    switch status {
    case "sealing":
      return String(localized: "native.chat.rollover.sealing", bundle: .lody)
    case "sealed":
      return String.localizedStringWithFormat(
        String(localized: "native.chat.rollover.sealed", bundle: .lody), gen)
    case "switching":
      return String.localizedStringWithFormat(
        String(localized: "native.chat.rollover.switching", bundle: .lody), gen)
    case "done":
      if let tokens = compactTokenRange(before: meta.usedBefore, after: meta.usedAfter) {
        return String.localizedStringWithFormat(
          String(localized: "native.chat.rollover.doneTokens", bundle: .lody), gen, tokens)
      }
      return String.localizedStringWithFormat(
        String(localized: "native.chat.rollover.done", bundle: .lody), gen)
    case "failed":
      return String(localized: "native.chat.rollover.failed", bundle: .lody)
    case "interrupted":
      return String(localized: "native.chat.rollover.interrupted", bundle: .lody)
    default:
      return nil
    }
  }

  private static func roleProposal(_ meta: ChatItem.NoticeMeta?) -> String {
    guard let command = meta?.command else { return String(localized: "native.chat.board.roleProposal", bundle: .lody) }
    let fields = command.patch ?? ChatItem.ProposalFields(name: command.name, description: command.description, promptPrefix: command.promptPrefix)
    let name = fields.name ?? meta?.before?.name ?? ""
    var lines = [String.localizedStringWithFormat(String(localized: String.LocalizationValue("native.chat.board.role." + command.action), bundle: .lody), name)]
    for (key, value) in [("name", fields.name), ("description", fields.description), ("promptPrefix", fields.promptPrefix)] {
      if let value {
        lines.append(String(localized: String.LocalizationValue("native.chat.board.field." + key), bundle: .lody) + ": " + value)
      }
    }
    if let outcome = meta?.outcome { lines.append(String(localized: String.LocalizationValue("native.chat.board.role." + outcome), bundle: .lody)) }
    return lines.joined(separator: "\n")
  }

  private func executionResultIDs(_ entry: ChatEntry) -> Set<String> {
    var result = Set<String>()
    for item in entry.items.reversed() {
      if item.isAttachment || (item.type == "text" && !(item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
        result.insert(item.itemId)
      } else { break }
    }
    return result
  }

  private func executionProcess(_ members: [ChatEntry]) -> [ChatRow] {
    let assistants = members.filter { $0.role == "assistant" }
    guard let tail = assistants.last else { return [] }
    let resultIDs = executionResultIDs(tail)
    return members.flatMap { entry -> [ChatRow] in
      if entry.role == "user" {
        // The execution ID identifies the initial prompt. Later user messages
        // are guides and belong at their original position in the process.
        guard entry.id != entry.executionId else { return [] }
        return ChatTranscript(entries: [entry]).entryRows()
      }
      return ChatTranscript(entries: [entry]).entryRows(processEntryID: entry.id, flatItems: true).filter {
        $0.kind != "proposed_plan" && (entry.id != tail.id || !resultIDs.contains($0.itemID))
      }
    }
  }

  private func entryRows(
    processEntryID: String = "",
    processStartID: String = "",
    now: Double = Date().timeIntervalSince1970 * 1000,
    turnStartedAt: [String: Double] = [:],
    flatItems: Bool = false
  ) -> [ChatRow] {
    entries.enumerated().flatMap { entryIndex, source -> [ChatRow] in
      var entry = source
      if entry.role == "system", !entry.items.isEmpty,
         entry.items.allSatisfy(\.isSilentNotice) { return [] }
      // Older cached projections omitted notice names; these placeholders are not part of the conversation.
      entry.items.removeAll { $0.hidesFromTranscript || ($0.type == "system_notice" && $0.name == nil) }
      let processOnly = !processEntryID.isEmpty
      if processOnly && entry.id != processEntryID { return [] }
      if entry.role == "user" {
        if processOnly || entry.isQueued { return [] }
        if entry.deliveryKind == "continue", entry.delivery == nil, entry.status != "delivery_unknown" {
          return [ChatRow(id: entry.id + ":user", entryID: entry.id, kind: "continued",
            text: String(localized: "native.chat.message.continued", bundle: .lody), symbol: "play.circle")]
        }
        var result: [ChatRow] = []
        let attachments = entry.items.compactMap { item -> ChatMessageAttachment? in
          if let image = item.image, item.type == "image" {
            return ChatMessageAttachment(
              id: image.id, fileName: image.fileName, image: image,
              storageSessionId: image.storageSessionId, transport: image.transport,
              sizeBytes: image.sizeBytes, mimeType: image.mimeType,
              machineId: image.machineId, sha256: image.sha256
            )
          }
          if item.type == "file" { return item.file?.shownAsImage }
          if item.type == "local_attachment" { return item.file }
          return nil
        }
        if !attachments.isEmpty {
          result.append(ChatRow(id: entry.id + ":user", entryID: entry.id, kind: "attachments", text: "", attachments: attachments))
        }
        var text = ""
        var references: [ChatTextReference] = []
        for item in entry.items where item.type == "text" {
          guard let value = item.text else { continue }
          if !text.isEmpty { text += "\n\n" }
          let offset = (text as NSString).length
          references += (item.references ?? []).map { reference in
            var shifted = reference
            shifted.start += offset; shifted.end += offset
            return shifted
          }
          text += value
        }
        if !text.isEmpty {
          result.append(ChatRow(id: entry.id + (result.isEmpty ? ":user" : ":user-text"), entryID: entry.id, kind: "user", text: text, references: references, delegatedAuthor: entry.author?.title))
        }
        // The turn's first row (its attachments, else its bubble) carries its sender, time and
        // read state (web's header), so attachments read as part of the message.
        if !result.isEmpty {
          result[0].author = entry.userId ?? ChatAuthors.unknownSender
          result[0].authorTime = ChatAuthors.time(entry.timestamp)
          result[0].readState = entry.inputState == nil || entry.inputState == "confirmed" ? ChatAuthors.readState(entry.status) : "sending"
        }
        if entry.inputState == "unknown" {
          let label = String(localized: "send.status.unknown", bundle: .lody) + " · " + String(localized: "send.forget.hint", bundle: .lody)
          result.append(ChatRow(id: entry.id + ":delivery", entryID: entry.id, kind: "delivery", text: label, actionable: true, attention: true))
        }
        if entry.inputRetryable == true {
          result.append(ChatRow(id: entry.id + ":retryPending", entryID: entry.id, kind: "delivery",
            text: String(localized: "native.chat.error.retry", bundle: .lody), actionable: true, attention: true))
        }
        if let delivery = entry.delivery, delivery != "accepted" {
          let key = "native.chat.message.guide." + delivery
          result.append(ChatRow(id: entry.id + ":delivery", entryID: entry.id, kind: "delivery",
            text: String(localized: String.LocalizationValue(key), bundle: .lody), attention: delivery == "rejected" || delivery == "unknown"))
        }
        return result
      }
      let answer = ChatAnswerText.visibleIndices(entry.items)
      // Web folds a finished turn only when something answers it below the fold; a cancelled or
      // tool-only turn stays expanded.
      let folds = entry.finished && entry.items.indices.contains { index in
        answer.contains(index) || entry.items[index].type == "proposed_plan" || entry.items[index].isAttachment || entry.items[index].isChatFailure
      }
      var visible: [Int] = []
      var groups: [Int: [Int]] = [:]
      if entry.role != "assistant" {
        if processOnly { return [] }
        visible = Array(entry.items.indices)
      } else if processOnly {
        if flatItems {
          visible = entry.items.indices.filter { !entry.items[$0].hidesFromTranscript }
        } else if !processStartID.isEmpty, let start = entry.items.firstIndex(where: { $0.itemId == processStartID }) {
          let toolGroup = entry.items[start].type == "tool_call"
          let end = entry.items.indices.dropFirst(start + 1).first {
            let item = entry.items[$0]
            if toolGroup { return item.type != "tool_call" || item.kind == "switch_mode" || item.isContextCompaction }
            return item.type == "text" || item.type == "proposed_plan" || item.isAttachment
          } ?? entry.items.endIndex
          visible = Array(start..<end).filter { entry.items[$0].type != "proposed_plan" && !entry.items[$0].isAttachment && !entry.items[$0].isNotice && !entry.items[$0].hidesFromTranscript }
        } else {
          visible = entry.items.indices.filter { !answer.contains($0) && entry.items[$0].type != "proposed_plan" && !entry.items[$0].isAttachment && !entry.items[$0].isNotice && !entry.items[$0].hidesFromTranscript }
        }
      } else if folds && !expandedWork.contains(entry.id) {
        let process = entry.items.indices.filter {
          !answer.contains($0) && !entry.items[$0].isOrchestration && entry.items[$0].type != "proposed_plan" && !entry.items[$0].isAttachment && !entry.items[$0].isNotice && entry.items[$0].type != "subagent_task" && entry.items[$0].operation == nil && entry.items[$0].proposal == nil
        }
        if let first = process.first { groups[first] = process }
        visible = process.first.map { [$0] } ?? []
        visible.append(contentsOf: answer)
        visible.append(contentsOf: entry.items.indices.filter {
          entry.items[$0].type == "proposed_plan" || entry.items[$0].isAttachment || entry.items[$0].isNotice
            || entry.items[$0].isOrchestration || entry.items[$0].operation != nil || entry.items[$0].proposal != nil
            || (entry.items[$0].type == "subagent_task" && !entry.items[$0].hidesFromTranscript)
        })
        visible.sort()
      } else {
        // Keep prose in place, folding consecutive runs of thoughts and tools separately.
        var toolStart: Int?
        var thoughtStart: Int?
        for index in entry.items.indices {
          let item = entry.items[index]
          if item.hidesFromTranscript || (item.type == "tool_call" && item.kind == "think") { continue }
          if item.type == "thought" {
            toolStart = nil
            if let start = thoughtStart {
              groups[start, default: []].append(index)
            } else {
              thoughtStart = index
              groups[index] = [index]
              visible.append(index)
            }
          } else if item.type == "tool_call", item.kind != "switch_mode", !item.isContextCompaction {
            thoughtStart = nil
            if let start = toolStart {
              groups[start, default: []].append(index)
            } else {
              toolStart = index
              groups[index] = [index]
              visible.append(index)
            }
          } else {
            toolStart = nil
            thoughtStart = nil
            visible.append(index)
          }
        }
      }
      var result: [ChatRow] = []
      var absorbed: Int?
      if entry.role == "assistant", !processOnly {
        let turn: ChatEntry?
        if let userTurnID = entry.userTurnId {
          // A reply may arrive before its input; never borrow a neighboring turn's clock.
          turn = entries.first { ($0.role == "user" || $0.role == "system") && $0.id == userTurnID }
        } else {
          turn = entries[..<entryIndex].last { $0.role == "user" }
        }
        let turnID = entry.userTurnId ?? turn?.id ?? entry.id
        let start = turnStartedAt[turnID] ?? turn.flatMap(ChatWorkDuration.startMilliseconds)
        if let duration = ChatWorkDuration.milliseconds(for: entry, now: now, startOverride: start) {
          var row = ChatRow(
            id: turnID + ":duration",
            entryID: entry.id,
            kind: "duration",
            text: ChatWorkDuration.title(duration, running: entry.isRunning),
            running: entry.isRunning,
            workDurationMs: duration
          )
          if folds {
            // "Worked for …" opens its folded work in place, below itself.
            row.actionable = true
            row.processStartID = "__work__"
            row.disclosed = expandedWork.contains(entry.id)
            // Only the collapsed whole-turn placeholder belongs to the duration row.
            // Expanded tool groups stay after their preceding prose and open their own calls.
            if !row.disclosed { absorbed = groups.keys.min() }
          } else if !entry.finished, entry.holdOpen != true, entry.executionId == nil,
                    let first = visible.first(where: { entry.items[$0].type != "subagent_task" }),
                    let indices = groups[first], entry.items[first].type != "thought" {
            let process = indices.map { entry.items[$0] }
            let tail = entry.items.indices.last {
              let item = entry.items[$0]
              return !item.hidesFromTranscript && !(item.type == "tool_call" && item.kind == "think")
            }
            let live = entry.isRunning && indices.last == tail
            row.detail = ChatProcessSummary.title(items: process, running: live)
            row.actionable = true
            row.processStartID = entry.items[first].itemId
            absorbed = first
          }
          result.append(row)
        }
      }
      for index in visible {
        if let indices = groups[index] {
          if index == absorbed { continue }
          let process = indices.map { entry.items[$0] }
          let needsPermission = process.contains { $0.permission?.pending == true }
          let tail = entry.items.indices.last {
            let item = entry.items[$0]
            return !item.hidesFromTranscript && !(item.type == "tool_call" && item.kind == "think")
          }
          let running = entry.isRunning && indices.last == tail
          let firstGroup = index == groups.keys.min()
          // Only a step waiting on the person flags the summary; a failed command needs no special
          // treatment (its own row says it failed).
          let attention = needsPermission
          var title = ChatProcessSummary.title(items: process, running: running)
          if !running, !folds, let duration = process.first?.processDurationMs {
            let summary = ChatProcessSummary.title(items: process, running: false, includesThought: false)
            title = ChatWorkDuration.title(duration, running: false)
            if !summary.isEmpty { title += " · " + summary }
          }
          let isThoughtGroup = process.allSatisfy { $0.type == "thought" } && !(folds && !expandedWork.contains(entry.id))
          var groupRow = ChatRow(id: entry.id + ":process" + (firstGroup ? "" : ":" + entry.items[index].itemId), entryID: entry.id, kind: "summary",
            text: title,
            symbol: ChatProcessSummary.mark(attention: attention),
            processStartID: isThoughtGroup ? "__thought__" : (folds && !expandedWork.contains(entry.id) ? "" : entry.items[index].itemId),
            actionable: true, running: running, attention: attention)
          groupRow.disclosed = isThoughtGroup && expandedThoughts.contains(groupRow.id)
          result.append(groupRow)
          if groupRow.disclosed {
            for item in process {
              result.append(ChatRow(id: entry.id + ":" + item.itemId, entryID: entry.id, kind: "thought",
                text: item.text ?? "", symbol: "brain", itemID: item.itemId,
                streaming: entry.isRunning && item.itemId == entry.textTailID))
            }
          }
          continue
        }
        let item = entry.items[index]
        if let operation = item.operation {
          result += operation.rows(entryID: entry.id, itemID: item.itemId)
          continue
        }
        if item.isImage {
          let images = item.type == "image" ? item.image.map { [$0] } ?? [] : item.images ?? []
          for (imageIndex, image) in images.enumerated() {
            result.append(ChatRow(id: entry.id + ":" + item.itemId + ":image:\(imageIndex)",
              entryID: entry.id, kind: "image", text: "", itemID: item.itemId, image: image))
          }
          continue
        }
        let attention = item.permission?.pending == true
        var row = ChatRow(id: entry.id + ":" + item.itemId, entryID: entry.id,
          kind: item.type, text: item.text ?? "", itemID: item.itemId,
          running: entry.isRunning && item.status == "in_progress", attention: attention,
          streaming: entry.isRunning && item.itemId == entry.textTailID)
        switch item.type {
        case "system_notice" where item.proposal != nil:
          row.kind = "proposal"
          row.proposal = item.proposal
          row.text = item.proposal?.headline ?? ""
          row.actionable = false
        case "system_notice" where item.isChatFailure:
          row.kind = "chat_failed"
          row.text = ChatFailure.title(item.meta)
          row.symbol = "exclamationmark.circle"
          row.attention = true
          row.errorMeta = item.meta
          row.actionable = false
        case "operation_completion_batch", "operation_completion":
          row.kind = "orchestration"
          let key = item.deliveryStatus == "unknown" ? "native.chat.board.resultsUnknown" : "native.chat.board.results"
          row.text = String.localizedStringWithFormat(String(localized: String.LocalizationValue(key), bundle: .lody), item.memberCount ?? 0)
          let members = (item.members ?? []).map {
            $0.title + " · " + String(localized: String.LocalizationValue("native.chat.board.status." + $0.status), bundle: .lody)
          }
          if !members.isEmpty { row.text += "\n" + members.joined(separator: "\n") }
          row.symbol = "checklist"
        case "system_notice" where item.name == "board_context_maintenance":
          if item.isSilentNotice { continue }
          row.kind = "noticeDivider"
          let allowedKinds = ["compact", "new_conversation", "fold_rollover"]
          let allowedStatuses = ["requested", "running", "done", "unsupported", "failed", "interrupted"]
          let kindKey = item.meta?.kind.flatMap { allowedKinds.contains($0) ? $0 : nil } ?? "compact"
          let statusKey = item.meta?.status.flatMap { allowedStatuses.contains($0) ? $0 : nil } ?? "running"
          let kind = String(localized: String.LocalizationValue("native.chat.board.kind." + kindKey), bundle: .lody)
          let status = String(localized: String.LocalizationValue("native.chat.board.status." + statusKey), bundle: .lody)
          var parts = [String.localizedStringWithFormat(String(localized: "native.chat.board.maintenance", bundle: .lody), kind, status)]
          if statusKey == "done" {
            if let tokens = Self.compactTokenRange(before: item.meta?.usedBefore, after: item.meta?.usedAfter) {
              parts.append(tokens)
            }
            if kindKey == "fold_rollover" {
              if let nodeId = item.meta?.nodeId?.trimmingCharacters(in: .whitespacesAndNewlines), !nodeId.isEmpty {
                parts.append(nodeId)
              }
              if let foldedCount = item.meta?.foldedCount,
                 let foldId = item.meta?.foldId?.trimmingCharacters(in: .whitespacesAndNewlines), !foldId.isEmpty {
                parts.append(String.localizedStringWithFormat(
                  String(localized: "native.chat.board.foldedMerge", bundle: .lody), foldedCount, foldId))
              }
            }
          }
          row.text = parts.joined(separator: " · ")
        case "system_notice" where item.name == "session_context_rollover":
          if item.isSilentNotice { continue }
          guard let text = Self.rolloverDivider(item.meta) else { continue }
          row.kind = "noticeDivider"
          row.text = text
        case "system_notice" where item.name == "board_chain_limit":
          row.kind = "noticeDivider"
          row.text = String(localized: "native.chat.board.chainLimit", bundle: .lody)
        case "system_notice" where item.name == "agent_role_proposal":
          row.kind = "orchestration"
          row.symbol = "person.crop.rectangle"
          row.text = Self.roleProposal(item.meta)
        case "system_notice" where item.name == "agent_warning":
          // Web `AgentWarningNoticeView`: nothing without a message; the label names the Lody path.
          guard let warning = ChatNotice.warning(item.meta) else { continue }
          row.kind = "agent_warning"
          row.text = warning.label
          row.detail = warning.summary
          row.errorMeta = item.meta
          row.actionable = false
        case "system_notice" where item.name == "session_fork_origin":
          guard let title = item.meta?.sourceTitle, let source = item.meta?.sourceSessionId, !source.isEmpty else { continue }
          row.kind = "notice"
          row.symbol = "arrow.triangle.branch"
          row.text = String.localizedStringWithFormat(String(localized: "native.chat.notice.forkOrigin", bundle: .lody), title)
          row.actionable = true
        case "system_notice" where item.name == "resume_from_external_chat_history":
          row.kind = "notice"
          row.symbol = "clock.arrow.circlepath"
          row.text = String(localized: "native.chat.notice.resumeHistory", bundle: .lody)
          if item.meta?.truncated == true { row.text += " " + String(localized: "native.chat.notice.resumeHistoryTruncated", bundle: .lody) }
          row.actionable = false
        case "system_notice":
          // Web renders no other notice (unknown names, `task_proposal`, malformed proposals).
          continue
        case "worktree_script":
          // Web `WorktreeScriptNoticeView`: the phase, live or failed; its commands open on tap.
          row.symbol = item.phase == "cleanup" ? "paintbrush" : "wrench.and.screwdriver"
          let phase = String(localized: String.LocalizationValue(item.phase == "cleanup" ? "native.chat.worktree.cleanup" : "native.chat.worktree.setup"), bundle: .lody)
          row.text = item.status == "failed"
            ? String.localizedStringWithFormat(String(localized: "native.chat.transcript.failed", bundle: .lody), phase)
            : phase
          row.running = item.status == "in_progress"
          row.attention = item.status == "failed"
          row.actionable = !(item.steps ?? []).isEmpty
        case "file", "local_attachment":
          guard let file = item.file else { continue }
          if item.type == "file", let image = file.shownAsImage.image {
            result.append(ChatRow(id: entry.id + ":" + item.itemId + ":image:0",
              entryID: entry.id, kind: "image", text: "", itemID: item.itemId, image: image))
            continue
          }
          row.kind = "file"
          row.file = file
          row.text = file.fileName
          row.symbol = file.kind == "image" ? "photo" : "doc"
          row.actionable = true
        case "proposed_plan":
          row.text = item.markdown ?? ""
          row.streaming = item.status == "delta"
          row.planIsLatest = item.isLatest == true
          if row.planIsLatest {
            row.planPermissionItemID = entry.items.first {
              $0.type == "tool_call" && $0.kind == "switch_mode" && $0.permission?.pending == true
            }?.itemId ?? ""
          }
        case "text": break
        case "thought": row.symbol = "brain"
        case "tool_call" where item.isContextCompaction:
          // Web `ToolCallBlock` compaction status: live while pending, then its outcome.
          let compacting = item.status == "pending" || item.status == "in_progress"
          let key: String
          if compacting { key = "native.chat.transcript.compacting" }
          else if item.status == "failed" { key = "native.chat.transcript.compactionFailed" }
          else { key = "native.chat.transcript.compacted" }
          row.text = String(localized: String.LocalizationValue(key), bundle: .lody)
          row.symbol = "arrow.down.right.and.arrow.up.left"
          row.running = entry.isRunning && compacting
          row.actionable = false
        case "tool_call":
          row.symbol = ["read": "doc.text.magnifyingglass", "search": "magnifyingglass", "edit": "square.and.pencil",
            "write": "square.and.pencil", "execute": "terminal", "bash": "terminal", "fetch": "globe"][item.kind ?? ""] ?? "wrench.and.screwdriver"
          row.text = ChatTranscript.compactParentHops(item.title.flatMap { $0.isEmpty ? nil : $0 } ?? item.path ?? String(localized: "native.chat.transcript.tool", bundle: .lody))
          if item.permission?.pending == true { row.text = String.localizedStringWithFormat(String(localized: "native.chat.transcript.pending", bundle: .lody), String(describing: row.text)) }
          else if item.status == "failed" { row.text = String.localizedStringWithFormat(String(localized: "native.chat.transcript.failed", bundle: .lody), String(describing: row.text)) }
          // Web `PermissionRequestBlock`: an answered plan approval reads as the chosen option.
          if item.kind == "switch_mode", let permission = item.permission, !permission.pending, permission.withdrawn != true,
             let chosen = permission.chosenOptionId,
             let name = permission.options?.first(where: { $0.optionId == chosen })?.name?.trimmingCharacters(in: .whitespacesAndNewlines),
             !name.isEmpty {
            row.text = name
          }
          row.actionable = item.hasDetail == true || item.permission?.pending == true
        case "plan":
          row.text = (item.entries ?? []).map { planPrefix($0.status) + $0.content }.joined(separator: "\n")
        case "subagent_task":
          row = ChatTranscript.subagentRow(entry: entry, item: item)
        default:
          row.text = item.title ?? String(localized: "native.chat.transcript.event", bundle: .lody)
          row.symbol = "info.circle"
        }
        if !row.text.isEmpty { result.append(row) }
      }
      if entry.role == "assistant", entry.finished, !processOnly {
        // The turn's output card: one row for its changed files (the task row joins it in
        // `hangSubagents`); the view folds its bounded file list beneath this row.
        let files = (entry.fileDiffs ?? []).filter { !$0.path.isEmpty }
        if !files.isEmpty {
          let add = files.reduce(0) { $0 + ($1.add ?? 0) }
          let del = files.reduce(0) { $0 + ($1.del ?? 0) }
          var header = ChatRow(
            id: entry.id + ":changes", entryID: entry.id, kind: "changesHeader",
            text: String.localizedStringWithFormat(String(localized: "native.chat.transcript.fileCount", bundle: .lody), files.count),
            actionable: true,
            fileDiff: ChatFileDiff(path: "", add: add, del: del, status: nil)
          )
          header.group = "only"
          result.append(header)
        }
        // Time follows the actions; model and reasoning remain in turn information.
        let finishedAt = ChatMetaTime.label(entry.endedAt, now: now)
        if !finishedAt.isEmpty || entry.items.contains(where: { $0.type == "text" || $0.isImage || $0.file?.shownAsImage.image != nil }) {
          result.append(ChatRow(id: entry.id + ":meta", entryID: entry.id, kind: "meta", text: finishedAt))
        }
      }
      return Self.stackImages(result)
    }
  }
}

extension ChatTranscript {
  static func compactParentHops(_ text: String) -> String {
    text.replacingOccurrences(of: #"(?:\.\./){2,}"#, with: "…/", options: .regularExpression)
  }

  /// Images of one turn that only tool work separates (an agent uploading several images, one
  /// image group, or repeated upload calls) become ONE fanned `imageStack` row instead of a long
  /// column of photos. The stack sits where its first image was; the process rows between its
  /// images follow it. Prose or any other row ends the stack. The stack's id derives from its
  /// first image, so it stays stable while later images join; a lone image keeps its `image` row.
  static func stackImages(_ rows: [ChatRow]) -> [ChatRow] {
    let transparent: Set<String> = ["summary", "tool_call", "thought"]
    var result: [ChatRow] = []
    var run: [ChatRow] = []
    var between: [ChatRow] = []
    func flush() {
      defer { run = []; between = [] }
      guard let first = run.first else { result += between; return }
      if run.count == 1 {
        result.append(first)
      } else {
        var row = ChatRow(id: first.id + ":stack", entryID: first.entryID, kind: "imageStack", text: "", itemID: first.itemID)
        row.stack = run.compactMap { image in
          image.image.map { ChatImagePreviewItem(id: image.id, image: $0, localURI: image.localImageURI) }
        }
        result.append(row)
      }
      result += between
    }
    for row in rows {
      let isImage = row.kind == "image" && row.image != nil
      if isImage, let first = run.first, first.entryID == row.entryID {
        run.append(row)
      } else if isImage {
        flush()
        run.append(row)
      } else if !run.isEmpty, transparent.contains(row.kind), row.entryID == run[0].entryID {
        between.append(row)
      } else {
        flush()
        result.append(row)
      }
    }
    flush()
    return result
  }

  /// Web `getFinalTextRunStart`: the answer is the final contiguous run of text before the
  /// never-folded tail (plans, attachments, failures, sub-tasks, plan approvals), not just the
  /// last text item. Empty when the turn ends in work.
  static func answerRun(_ items: [ChatItem]) -> [Int] {
    func neverFolded(_ item: ChatItem) -> Bool {
      item.type == "proposed_plan" || item.type == "plan" || item.isAttachment || item.isNotice
        || item.type == "subagent_task" || (item.type == "tool_call" && item.kind == "switch_mode")
    }
    func prose(_ item: ChatItem) -> Bool { item.type == "text" && !(item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var index = items.count - 1
    while index >= 0 && neverFolded(items[index]) { index -= 1 }
    guard index >= 0, prose(items[index]) else { return [] }
    var start = index
    while start > 0 && items[start - 1].type == "text" { start -= 1 }
    return (start...index).filter { prose(items[$0]) }
  }

  /// Web's task panel, compact: ONE inset card row after the turn's answer ("Waiting on N tasks"
  /// while any runs, "N tasks" once settled; the newest running task's latest step as its detail).
  /// The tasks themselves live in the task sheet it opens (`TasksController`), never inline.
  /// Neutral: no attention mark on the card.
  static func hangSubagents(_ rows: [ChatRow]) -> [ChatRow] {
    let tasks = rows.filter { $0.kind == "subagent_task" }
    var result = rows.filter { $0.kind != "subagent_task" }
    guard let first = tasks.first else { return rows }
    let running = tasks.filter(\.running).count
    let background = tasks.allSatisfy { $0.subagent?.background == true }
    let key: String
    switch (running > 0, background) {
    case (true, true): key = "native.chat.tasks.waitingBackground"
    case (true, false): key = "native.chat.tasks.waiting"
    case (false, true): key = "native.chat.tasks.countBackground"
    case (false, false): key = "native.chat.tasks.count"
    }
    var header = ChatRow(
      id: first.entryID + ":tasks", entryID: first.entryID, kind: "tasksHeader",
      text: String.localizedStringWithFormat(String(localized: String.LocalizationValue(key), bundle: .lody), running > 0 ? running : tasks.count),
      actionable: true, running: running > 0
    )
    header.detail = tasks.last { $0.running && !($0.subagent?.detail ?? "").isEmpty }?.subagent?.detail ?? ""
    // The output card: tasks first, then the changed files row when the turn has one; the meta
    // line stays last.
    let files = result.firstIndex { $0.kind == "changesHeader" }
    header.group = files == nil ? "only" : "first"
    if let files { result[files].group = "last" }
    let anchor = files ?? result.firstIndex { $0.kind == "meta" } ?? result.endIndex
    result.insert(header, at: anchor)
    return result
  }

  fileprivate static func subagentRow(entry: ChatEntry, item: ChatItem) -> ChatRow {
    let actor = item.actor?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let description = item.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let tool = item.lastToolName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let summary = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let error = item.error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let status = ChatSubagentCard.status(item)
    let running = status == "in_progress" || status == "pending"
    var detail = ""
    if running, let step = ChatSubagentCard.latestStep(item.run) {
      detail = step
    } else if item.status == "in_progress", !tool.isEmpty {
      detail = String.localizedStringWithFormat(String(localized: "native.chat.subagent.runningTool", bundle: .lody), String(describing: tool))
    } else if status == "unknown" {
      detail = String(localized: "native.chat.subagent.unknownDetail", bundle: .lody)
    } else if item.status == "completed" {
      detail = summary
    } else if item.status == "failed" {
      detail = error
    }
    let card = ChatSubagentCard(
      actor: actor.isEmpty ? String(localized: "native.chat.transcript.subtask", bundle: .lody) : actor,
      description: description == actor ? "" : description,
      status: status,
      detail: detail,
      background: item.isBackgrounded == true
    )
    var row = ChatRow(
      id: entry.id + ":" + item.itemId,
      entryID: entry.id,
      kind: "subagent_task",
      text: [card.actor, card.description, detail].filter { !$0.isEmpty }.joined(separator: " · "),
      itemID: item.itemId,
      running: running,
      attention: status == "failed"
    )
    row.symbol = "point.3.connected.trianglepath.dotted"
    row.actionable = true
    row.subagent = card
    return row
  }
}

struct ChatSubagentCard: Equatable {
  var actor: String
  var description: String
  var status: String
  var detail: String
  var background: Bool
  var groupTitle = ""

  static let runStatuses = ["running": "in_progress", "pending": "pending", "completed": "completed",
    "failed": "failed", "cancelled": "cancelled", "unknown": "unknown"]

  static func status(_ item: ChatItem) -> String {
    if let state = item.run?.state, let mapped = runStatuses[state] { return mapped }
    return item.status ?? "pending"
  }

  static func latestStep(_ run: ChatSubagentRun?) -> String? {
    guard let last = run?.items?.last else { return nil }
    switch last.type {
    case "tool_call": return [last.title, last.path].compactMap { $0 }.first { !$0.isEmpty }
    case "thought": return String(localized: "native.chat.transcript.activity.thinking", bundle: .lody)
    case "text": return last.text?.split(separator: "\n").last.map(String.init)
    default: return nil
    }
  }

  static func groupTitle(_ cards: [ChatSubagentCard]) -> String {
    var parts = [String.localizedStringWithFormat(String(localized: "native.chat.subagent.group", bundle: .lody), cards.count)]
    for (status, key) in [("in_progress", "groupRunning"), ("completed", "groupDone"), ("failed", "groupFailed")] {
      let count = cards.filter { $0.status == status || (status == "in_progress" && $0.status == "pending") }.count
      if count > 0 {
        parts.append(String.localizedStringWithFormat(String(localized: String.LocalizationValue("native.chat.subagent." + key), bundle: .lody), count))
      }
    }
    return parts.joined(separator: " · ")
  }
}

extension Array where Element == ChatRow {
  fileprivate func groupedSubagents() -> [ChatRow] {
    var rows = self
    var start = 0
    while start < rows.count {
      var end = start
      while end < rows.count, rows[end].kind == "subagent_task", rows[end].entryID == rows[start].entryID { end += 1 }
      if end - start >= 2 {
        let title = ChatSubagentCard.groupTitle(rows[start..<end].compactMap(\.subagent))
        rows[start].subagent?.groupTitle = title
      }
      start = Swift.max(end, start + 1)
    }
    return rows
  }
}

enum ChatProcessSummary {
  /// No pip for a process (the row's shine shows it is live); a mark only while a step waits on the
  /// person's permission.
  static func mark(attention: Bool) -> String {
    attention ? "exclamationmark.triangle.fill" : ""
  }

  static func title(items: [ChatItem], running: Bool, includesThought: Bool = true) -> String {
    var readPaths = Set<String>()
    var editPaths = Set<String>()
    var readWithout = 0
    var editWithout = 0
    var commands = 0
    var searches = 0
    var fetches = 0
    var others = 0
    var hasThought = false
    for item in items {
      if item.type == "thought" || item.kind == "think" {
        hasThought = true
        continue
      }
      guard item.type == "tool_call", !item.isContextCompaction else { continue }
      switch item.kind {
      case "execute", "bash":
        commands += 1
      case "read":
        if let path = item.path, !path.isEmpty { readPaths.insert(path) }
        else { readWithout += 1 }
      case "edit", "write", "delete", "move":
        if let path = item.path, !path.isEmpty { editPaths.insert(path) }
        else { editWithout += 1 }
      case "search":
        searches += 1
      case "fetch":
        fetches += 1
      default:
        others += 1
      }
    }
    var parts: [String] = []
    if hasThought && includesThought {
      parts.append(String(localized: String.LocalizationValue(running
          ? "native.chat.transcript.activity.thinking"
          : "native.chat.transcript.activity.thought"), bundle: .lody))
    }
    add(&parts, "native.chat.transcript.activity.commands", commands)
    add(&parts, "native.chat.transcript.activity.readFiles", readPaths.count + readWithout)
    add(&parts, "native.chat.transcript.activity.editedFiles", editPaths.count + editWithout)
    add(&parts, "native.chat.transcript.activity.searches", searches)
    add(&parts, "native.chat.transcript.activity.fetches", fetches)
    add(&parts, "native.chat.transcript.activity.tools", others)
    if parts.isEmpty && includesThought {
      return String(localized: "native.chat.transcript.status.done", bundle: .lody)
    }
    return parts.joined(separator: " · ")
  }

  private static func add(_ parts: inout [String], _ key: String, _ count: Int) {
    guard count > 0 else { return }
    parts.append(String.localizedStringWithFormat(String(localized: String.LocalizationValue(key), bundle: .lody), count))
  }
}


private func planPrefix(_ status: String?) -> String {
  switch status {
  case "completed": return "✓ "
  case "in_progress": return "› "
  default: return "○ "
  }
}

extension ChatPendingSend {
  static func hidingStatus(_ rows: [ChatRow], inFlight: Set<String>) -> [ChatRow] {
    guard !inFlight.isEmpty else { return rows }
    return rows.filter { row in
      switch row.kind {
      case "duration", "pending":
        return !inFlight.contains(row.entryID)
      default:
        return true
      }
    }
  }

  func rows(entries: [ChatEntry]) -> [ChatRow] {
    guard (queue != true || failed == true), !entries.contains(where: { $0.id == id && $0.isQueued }) else { return [] }
    var result: [ChatRow] = []
    if !entries.contains(where: { $0.id == id }) {
      let media = attachments.compactMap { attachment -> ChatMessageAttachment? in
        guard URL(string: attachment.uri)?.isFileURL == true else { return nil }
        let image = attachment.kind == "image"
          ? ChatImage(id: attachment.id, fileName: attachment.name, storageSessionId: nil, width: nil, height: nil)
          : nil
        return ChatMessageAttachment(id: attachment.id, fileName: attachment.name, image: image, localURI: attachment.uri)
      }
      if !media.isEmpty {
        result.append(ChatRow(id: id + ":user", entryID: id, kind: "attachments", text: status,
          running: failed != true && reconnect != true && !["accepted", "uploaded", "unknown"].contains(phase ?? ""),
          attachments: media, uploadProgress: uploadProgress ?? [:]))
      }
      var body = displayText ?? text
      var shown: [ChatTextReference] = displayText == nil ? [] : references ?? []
      // Quote cards follow the text as the runtime will send them, drawn as history draws them.
      for quote in quotes ?? [] {
        if !body.isEmpty { body += "\n\n" }
        let start = (body as NSString).length
        body += quote.text
        shown.append(ChatTextReference(start: start, end: (body as NSString).length, kind: "message_quote", target: quote.id, quote: quote.text))
        if !quote.comment.isEmpty { body += "\n\n" + quote.comment }
      }
      if !body.isEmpty {
        result.append(ChatRow(id: id + (result.isEmpty ? ":user" : ":user-text"), entryID: id, kind: "user", text: body,
          references: shown))
      }
      // A local send in flight is the signed-in user's own turn; its first row carries the header.
      if !result.isEmpty {
        result[0].author = ChatAuthors.unknownSender
        result[0].authorTime = ChatAuthors.time(Date().ISO8601Format())
        result[0].readState = "sending"
      }
    }
    if failed == true {
      result.append(ChatRow(id: id + ":pending", entryID: id, kind: "pending", text: status,
        actionable: true, attention: true))
      return result
    }
    var precedingUserID: String?
    let hasReply = entries.contains { entry in
      if entry.role == "user" { precedingUserID = entry.id }
      return entry.role == "assistant" && (entry.userTurnId ?? precedingUserID) == id
    }
    let hasDelivery = entries.contains { $0.id == id && $0.delivery != nil }
    let acknowledged = phase == "accepted"
    if !hasReply && !acknowledged && !hasDelivery {
      let delivery = status.isEmpty ? String(localized: "send.status.awaitingConnection", bundle: .lody) : status
      let recoverable = ["unknown", "uploaded"].contains(phase ?? "") && queue != true && guide != true
      let label = phase == "unknown" && !recoverable
        ? delivery + " · " + String(localized: "send.forget.hint", bundle: .lody)
        : delivery
      result.append(ChatRow(id: id + ":delivery", entryID: id, kind: "delivery", text: label,
        actionable: phase == "unknown" || recoverable, attention: phase == "unknown"))
    }
    if !hasReply && acknowledged && !hasDelivery {
      let now = Date().timeIntervalSince1970 * 1000
      let start = startedAt.flatMap { $0.isFinite && $0 <= now ? $0 : nil } ?? now
      let duration = Int(now - start)
      result.append(ChatRow(
        id: id + ":duration",
        entryID: id,
        kind: "duration",
        text: ChatWorkDuration.title(duration, running: true),
        running: true,
        workDurationMs: duration
      ))
    }
    return result
  }
}

// Unknown reasons retain their payload in the detail page and use a localized fallback.
/// Web `AgentWarningNoticeBody` copy for an `agent_warning`.
enum ChatNotice {
  private static let sources = [
    "sessionCancelFailed": "stopRequestFailed", "sessionStopTimedOut": "stopTimedOut",
    "sessionTerminationFailed": "stopTerminationFailed", "nativeWorkInterrupted": "nativeWorkInterrupted",
  ]

  static func warning(_ meta: ChatItem.NoticeMeta?) -> (label: String, summary: String, detail: String)? {
    let message = (meta?.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty else { return nil }
    let key = sources[meta?.source ?? ""]
    let label = String(localized: String.LocalizationValue("native.chat.warning." + (key ?? "title")), bundle: .lody)
    let guidance = key.map { String(localized: String.LocalizationValue("native.chat.warning." + $0 + "Guidance"), bundle: .lody) }
    let summary = guidance ?? message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? message
    return (label, summary, guidance.map { $0 + "\n\n" + message } ?? message)
  }

  /// A worktree script's commands, each followed by the tail of its output.
  static func script(_ steps: [ChatItem.ScriptStep]) -> String {
    steps.map { step in
      let output = step.output.trimmingCharacters(in: .whitespacesAndNewlines)
      let waiting = step.status == "in_progress" ? String(localized: "native.chat.worktree.waiting", bundle: .lody) : ""
      return "$ " + step.command + "\n" + (output.isEmpty ? waiting : output)
    }.joined(separator: "\n\n")
  }
}

enum ChatFailure {
  static func title(_ meta: ChatItem.NoticeMeta?) -> String {
    if meta?.code == "git_executable_not_found" {
      return String(localized: "native.chat.error.git_executable_not_found", bundle: .lody)
    }
    let known: Set<String> = ["unknown", "session_archived", "agent_type_mismatch", "session_init_failed", "session_restore_failed", "session_not_found", "memory_pressure", "acp_not_ready", "agent_disconnected", "agent_no_output", "turn_pre_prompt_failed", "message_delivery_failed", "machine_access_denied", "acp_auth_required", "acp_internal_error", "acp_upstream_api_error", "acp_provider_overloaded", "acp_session_storage_incompatible", "acp_resource_not_found", "acp_request_cancelled", "acp_method_not_found", "acp_invalid_params", "acp_invalid_request", "acp_parse_error", "acp_unknown_error", "daemon_restart"]
    let reason = meta?.reason ?? "unknown"
    return String(localized: String.LocalizationValue("native.chat.error." + (known.contains(reason) ? reason : "unknown")), bundle: .lody)
  }
}


struct ChatErrorRetryState: Decodable, Equatable {
  let entryId: String
  let itemId: String
  let enabled: Bool
  let pending: Bool
  let visible: Bool
  let message: String
}

extension ChatFailure {
  static func hasDetail(_ meta: ChatItem.NoticeMeta?) -> Bool {
    [meta?.message, meta?.code].contains { !($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }
  static func summary(_ meta: ChatItem.NoticeMeta?) -> String {
    if meta?.code == "git_executable_not_found" { return String(localized: "native.chat.error.gitSummary", bundle: .lody) }
    let descriptions = ["acp_provider_overloaded": "capacitySummary", "acp_auth_required": "authSummary", "machine_access_denied": "accessSummary"]
    if let key = descriptions[meta?.reason ?? ""] { return String(localized: String.LocalizationValue("native.chat.error." + key), bundle: .lody) }
    let message = (meta?.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if message.isEmpty || message.hasPrefix("{") || message.hasPrefix("[") { return String(localized: "native.chat.error.summary", bundle: .lody) }
    return String(message.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ").prefix(260))
  }
}

struct ChatPlanDecisionState: Decodable, Equatable {
  let entryId: String
  let itemId: String
  let enabled: Bool
  let pending: Bool
  let message: String
}

struct ChatOperationPeer: Equatable {
  var card: ChatOperationCard
  var text: String
  var detail: String
  var actionable: Bool
  var cliType: String?
  var agentType: String?
  var current = false
}

enum ChatOperationGrouping {
  /// Group only adjacent receipts in the same turn; never cross a notice or reorder history.
  static func rows(_ rows: [ChatRow], roots: [String: String], opened: Set<String>) -> [ChatRow] {
    var result: [ChatRow] = []
    var index = 0
    while index < rows.count {
      var row = rows[index]
      guard let card = row.operation else { result.append(row); index += 1; continue }
      let root = roots[card.sessionId] ?? card.sessionId
      var group = [row]
      index += 1
      while index < rows.count, let next = rows[index].operation,
        rows[index].entryID == row.entryID, (roots[next.sessionId] ?? next.sessionId) == root {
        group.append(rows[index]); index += 1
      }
      row.treeChild = group.contains { $0.operation?.sessionId == root } && opened.contains(root)
      if group.count > 1 {
        row.operationPeers = group.compactMap { member in
          guard let card = member.operation else { return nil }
          return ChatOperationPeer(card: card, text: member.text, detail: member.detail, actionable: member.actionable,
            cliType: member.operationCLIType, agentType: member.operationAgentType, current: member.operationCurrent)
        }
      }
      result.append(row)
    }
    for index in result.indices where result[index].operation != nil {
      result[index].treeLast = index + 1 == result.count || !result[index + 1].treeChild || result[index + 1].entryID != result[index].entryID
    }
    return result
  }
}

/// web `AgentRoleProposalMeta` / `ScheduleProposalMeta` / `ScheduleEditProposalMeta` as the runtime presents them.
struct ChatProposal: Decodable, Equatable {
  struct Fields: Decodable, Equatable {
    var name: String? = nil
    var description: String? = nil
    var promptPrefix: String? = nil
  }
  /// `schedule_edit`: only these fields change.
  struct Patch: Decodable, Equatable {
    var title: String? = nil
    var prompt: String? = nil
    var rule: RuntimeContract.ScheduleRule? = nil
  }
  let kind: String
  var action: String? = nil
  var roleId: String? = nil
  var requesterUserId: String? = nil
  var fields: Fields? = nil
  var before: Fields? = nil
  var outcome: String? = nil
  var proposalId: String? = nil
  var title: String? = nil
  var prompt: String? = nil
  var rule: RuntimeContract.ScheduleRule? = nil
  var destination: String? = nil
  var scheduleId: String? = nil
  var patch: Patch? = nil
  var baseActivityId: String? = nil

  var isRole: Bool { kind == "agent_role" }
  var isEdit: Bool { kind == "schedule_edit" }
  var decided: Bool { outcome != nil }

  /// The card's heading: the question while open, the receipt once decided.
  var headline: String {
    let key: String
    switch (kind, outcome, action) {
    case (_, "dismissed"?, _): key = "native.chat.proposal.dismissed"
    case ("agent_role", "saved"?, _): key = "native.chat.proposal.role.saved"
    case ("agent_role", _, "update"?): key = "native.chat.proposal.role.update"
    case ("agent_role", _, _): key = "native.chat.proposal.role.create"
    case ("schedule_edit", "applied"?, _): key = "native.chat.proposal.edit.applied"
    case ("schedule_edit", _, _): key = "native.chat.proposal.edit.title"
    case (_, "created"?, _): key = "native.chat.proposal.schedule.created"
    default: key = "native.chat.proposal.schedule.title"
    }
    return String(localized: String.LocalizationValue(key), bundle: .lody)
  }
}

/// A decision in flight or its failure, kept by the chat view per proposal row.
struct ChatProposalState: Equatable {
  var pending = false
  var message = ""
}
