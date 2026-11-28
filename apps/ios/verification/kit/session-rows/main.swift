import Foundation

let badgeCurrent = SessionItem(id: "current", lastMessageAt: 2, lastReadAt: 1)
var badgeOther = SessionItem(id: "other")
for status in ["running", "waiting", "error", "completed"] {
  badgeOther.status = status
  badgeOther.lastMessageAt = nil
  precondition(!DirectoryTabs.hasBackgroundUnread([badgeCurrent, badgeOther], currentId: "current"), "Activity and the current Tab never light the header dot")
  badgeOther.lastMessageAt = 2
  badgeOther.lastReadAt = 1
  precondition(DirectoryTabs.hasBackgroundUnread([badgeCurrent, badgeOther], currentId: "current"), "Unread output lights the dot regardless of activity")
}
badgeOther.lastViewedMessageAt = 2
precondition(!DirectoryTabs.hasBackgroundUnread([badgeCurrent, badgeOther], currentId: "current"), "A local visit clears the dot before its read receipt arrives")
badgeOther.lastMessageAt = 3
precondition(DirectoryTabs.hasBackgroundUnread([badgeCurrent, badgeOther], currentId: "current"), "Later background output restores the dot")
precondition(!DirectoryTabs.hasBackgroundUnread([badgeOther], currentId: "other"), "Selecting the unread Tab excludes it")
badgeOther.isTabClosed = true
precondition(!DirectoryTabs.hasBackgroundUnread([badgeCurrent, badgeOther], currentId: "current"), "Closed Tabs do not light the header dot")
print("PASS: header dot reflects only unseen output in other open Tabs")

let hour = 3_600_000.0
let now = Date().timeIntervalSince1970 * 1000

// A family belongs exclusively to its parent's bucket, even across projects and dates. Tabs
// (`parentSessionId`) belong to their conversation and never list (web `sessionListAtom`).
var bucketParent = SessionItem(id: "bucket-parent", projectId: "p")
bucketParent.createdAt = Date(timeIntervalSince1970: (now - 3 * 86_400_000) / 1000).ISO8601Format()
var bucketChild = SessionItem(id: "bucket-child", projectId: "other", openedBySessionId: "bucket-parent")
bucketChild.status = "running"
bucketChild.createdAt = Date().ISO8601Format()
var bucketTab = SessionItem(id: "bucket-tab", projectId: "other")
bucketTab.parentSessionId = "bucket-parent"
bucketTab.status = "waiting"
bucketTab.createdAt = Date().ISO8601Format()
let bucketCatalog = SessionCatalog(sessions: [bucketChild, bucketTab, bucketParent])
for grouping in [HomeGrouping.time, .status, .project] {
  let sections = InboxSections.home(bucketCatalog, grouping: grouping, now: now)
  precondition(sections.count == 1, "Children must never create their own bucket")
  precondition(sections[0].rows.map(\.id) == ["bucket-parent", "bucket-child"], "Tabs never list")
  precondition(sections[0].rows.map(\.parentId) == ["", "bucket-parent"])
}
precondition(InboxSections.home(bucketCatalog, grouping: .time, now: now)[0].id == "week")
// Without the runtime's layout (an older runtime or cache) Status lists time buckets: Swift never classifies tiers.
precondition(InboxSections.home(bucketCatalog, grouping: .status, now: now)[0].id == "week")

var pinnedParent = bucketParent
pinnedParent.pinned = true
let pinnedCatalog = SessionCatalog(sessions: [bucketChild, bucketTab, pinnedParent, SessionItem(id: "ordinary", projectId: "p")])
for grouping in [HomeGrouping.time, .status, .project] {
  let sections = InboxSections.home(pinnedCatalog, grouping: grouping, now: now)
  precondition(sections.first?.id == "pinned", "Pin group leads every view")
  precondition(sections[0].rows.map(\.id) == ["bucket-parent", "bucket-child"], "Pinned families stay together")
  precondition(sections.flatMap(\.rows).filter { $0.id == "bucket-parent" }.count == 1)
}

var archivedPin = pinnedParent
archivedPin.id = "archived-pin"
archivedPin.archived = true
var hiddenPin = bucketTab
hiddenPin.pinned = true
precondition(InboxSections.home(SessionCatalog(sessions: [archivedPin, hiddenPin, bucketParent]), grouping: .time).allSatisfy { $0.id != "pinned" })
var ownedPin = pinnedParent
ownedPin.userId = "other"
var mine = SessionItem(id: "mine", projectId: "p")
mine.userId = "me"
precondition(InboxSections.home(SessionCatalog(sessions: [ownedPin, mine]), grouping: .time, owner: "me").flatMap(\.rows).map(\.id) == ["mine"])

let saved = """
{"catalog":{"projects":[{"id":"p","name":"Lody","rootPath":"/Users/me/lody","machineId":"m"},{"broken":true}],
"machineIds":["m"],"sessions":[
{"id":"root","title":"Root","status":"completed","archived":true,"pinned":false,"projectId":"p","createdAt":"2026-01-02T03:04:05.678Z","lastMessageAt":\(now - 120_000),"lastReadAt":\(now - hour),"branchName":"main","lastModel":{"name":"","modelId":"gpt-5"},"diff":{"add":3,"del":1}},
{"id":"child","title":"Child","status":"error","archived":true,"pinned":false,"projectId":"p","createdAt":"2026-01-02T03:04:05Z","openedBySessionId":"root","lastModel":null},
{"id":"tab","title":"Tab","status":"running","archived":true,"pinned":false,"projectId":"p","createdAt":"2026-01-02T03:04:05Z","parentSessionId":"root"},
{"id":"chat","title":"Chat","status":"waiting","archived":false,"pinned":true,"projectId":"w:unassigned","createdAt":"2026-01-02T03:04:05Z","awaitingUserSince":1,"branchName":""},
{"title":"missing id"}
]}}
"""
guard let catalog = SessionCatalog.decode(saved: Data(saved.utf8)) else { fatalError("Catalog must decode") }
precondition(catalog.projects.map(\.id) == ["p"], "Malformed projects are dropped")
precondition(catalog.machineIds == ["m"] && catalog.machineNames.isEmpty)
precondition(catalog.sessions.map(\.id) == ["root", "child", "tab", "chat"], "Malformed sessions are dropped")
precondition(SessionCatalog.decode(saved: Data(#"{"catalog":{"projects":[],"sessions":[]}}"#.utf8)) == nil, "Incomplete catalogs are rejected")

let root = catalog.sessions[0], child = catalog.sessions[1], tab = catalog.sessions[2], chat = catalog.sessions[3]
precondition(child.modelNeverRan && !root.modelNeverRan && root.modelName == "gpt-5")
precondition(chat.branchName == nil, "Empty branch names behave like JS falsy values")
precondition(child.activityAt == 1_767_323_045_000 && root.lastMessageAt == root.activityAt)

precondition(SessionState(root) == .archived && SessionState(chat) == .attention)
var live = chat
live.status = "running"
precondition(SessionState(live) == .live, "Awaiting input never hides a live run")

let row = SessionRows.row(root, projectName: "Lody", now: now)
precondition(row.subtitle == "Lody · main" && row.subtitleMono && row.modelName == "gpt-5")
precondition(row.value == "time.compact.minutes" && row.accessibilityValue == "time.minutesAgo", "Rows draw a compact time and speak the full one")
precondition(row.unread && row.badge == "inbox.badge.archived" && row.imageTint.isEmpty)
precondition(row.actions.map(\.id) == ["archive"] && row.actions[0].title == "session.action.unarchive", "Archived rows swipe only to unarchive")
precondition(row.leadingActions.isEmpty && row.menuActions.map(\.id) == ["archive", "share", "delete"] && row.menuActions[2].destructive)
let openRow = SessionRows.row(chat, now: now)
precondition(openRow.leadingActions.map(\.id) == ["pin"] && openRow.leadingActions[0].tint == "yellow")
precondition(openRow.menuActions.map(\.id) == ["rename", "pin", "archive", "share", "delete"] && openRow.menuActions[4].destructive)
precondition(row.preview == "session" && row.navigates && row.action && row.diff == ["add": 3, "del": 1])
precondition(SessionRows.row(child).modelName == "session.notRun")
var viewed = root
viewed.archived = false
viewed.lastViewedMessageAt = root.lastMessageAt
precondition(!SessionRows.row(viewed).unread && SessionRows.isUnread(viewed), "A local view clears emphasis without changing the server watermark")
precondition(SessionRows.row(viewed).actions.map(\.id) == ["archive"], "Viewed output must not offer Mark Read")
var laterOutput = viewed
laterOutput.lastMessageAt = (viewed.lastMessageAt ?? 0) + 1
precondition(SessionRows.row(laterOutput).unread)
precondition(SessionRows.row(laterOutput).actions.map(\.id) == ["read", "archive"], "New output restores Mark Read")
laterOutput.lastReadAt = laterOutput.lastMessageAt
precondition(!SessionRows.row(laterOutput).unread)
precondition(SessionRows.row(laterOutput).actions.map(\.id) == ["archive"], "Remote read removes Mark Read")
let chatRow = SessionRows.row(chat)
precondition(chatRow.badge == "inbox.badge.attention" && chatRow.imageTint == "warning" && chatRow.subtitle.isEmpty)

let archived = catalog.sessions.filter(\.archived).sorted(by: SessionRows.byActivity)
precondition(archived.map(\.id) == ["root", "child", "tab"])
let rows = SessionRows.treeRows(archived, all: catalog.sessions) { SessionRows.row($0, now: now) }
precondition(rows.map(\.id) == ["root", "child"], "Opened sessions nest under their opener; contained tabs never list")
// Parent and hidden children retain separate states.
var failedParent = SessionItem(id: "family-parent", projectId: "p")
failedParent.status = "error"
var runningChild = SessionItem(id: "family-child", projectId: "p", openedBySessionId: "family-parent")
runningChild.status = "running"
let family = [failedParent, runningChild]
let familyRows = SessionRows.treeRows(family, all: family) { SessionRows.row($0, now: now) }
precondition(familyRows[0].imageTint == "danger", "Parent keeps its own state")
precondition(familyRows[0].collapsedImageTint == "blue", "Collapsed summary uses children only")
var foldedRow = rows[0]
foldedRow.value = "1h"
foldedRow.collapsedBadge = "attention"
let shownFolded = foldedRow.displayingCollapsed(true, keepingTime: true)
precondition(shownFolded.value == "1h" && shownFolded.badge == "attention", "A folded parent keeps its time and takes its children's state")
precondition(foldedRow.displayingCollapsed(true).value == "inbox.session.children", "Compact hosts still show the count in the time column")
precondition(rows[0].collapsedValue == "inbox.session.children" && rows[1].parentId == "root")
precondition(rows[0].collapsedBadge == "inbox.badge.archived")
precondition(rows.map(\.lastChild) == [false, true], "Only the final opened session closes the rail")
var second = SessionItem(id: "second", projectId: "p", openedBySessionId: "root")
second.lastMessageAt = 1
second.archived = true
let pair = SessionRows.treeRows([root, child, second], all: [root, child, second]) { SessionRows.row($0, now: now) }
precondition(pair.map(\.id) == ["root", "child", "second"] && pair.map(\.lastChild) == [false, false, true],
             "Earlier siblings keep the trunk running to the last child")
precondition(SessionRows.treeRows(archived, all: catalog.sessions, maxRoots: 1) { SessionRows.row($0) }.count == 2)

var cycleA = SessionItem(id: "a", projectId: "p", openedBySessionId: "b")
var cycleB = SessionItem(id: "b", projectId: "p", openedBySessionId: "a")
cycleA.lastMessageAt = 2
cycleB.lastMessageAt = 1
precondition(SessionRows.tree([cycleA, cycleB], all: [cycleA, cycleB]).count == 2, "Opener cycles terminate as separate entries")
precondition(SessionRows.tree([cycleA], all: [cycleA, cycleB]).count == 1, "Hidden openers do not group")

var pinned = SessionItem(id: "pinned", pinned: true, lastMessageAt: 1)
let recent = SessionItem(id: "recent", lastMessageAt: 5)
precondition([recent, pinned].sorted(by: SessionRows.byActivity).map(\.id) == ["pinned", "recent"])
pinned.pinned = false
precondition([pinned, recent].sorted(by: SessionRows.byActivity).map(\.id) == ["recent", "pinned"])

precondition(SessionRows.deletionTargets(catalog.sessions, id: "root").map(\.id) == ["root", "tab"])
precondition(!SessionRows.deletionBlocked([root, child]) && SessionRows.deletionBlocked([live]))
precondition(SessionRows.projectId(ofRow: "toggle:p") == "p" && SessionRows.projectId(ofRow: "project:p") == "p")
precondition(["chat", "toggle:pinned", "view:x", "root"].allSatisfy { SessionRows.projectId(ofRow: $0) == nil })
precondition(SessionRows.projectMenu(SessionProject(id: "p", rootPath: "/x")).map(\.id) == ["newSession", "open", "copyPath"])
precondition(SessionRows.projectMenu(SessionProject(id: "w:unassigned")).map(\.id) == ["open"])

let views = catalog.viewed(["root": root.lastMessageAt!])
precondition(views.sessions[0].lastViewedMessageAt == root.lastMessageAt && views.sessions[1].lastViewedMessageAt == nil)

let day = 86_400_000.0
let midday = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: now / 1000)).timeIntervalSince1970 * 1000 + 12 * hour
func item(_ id: String, _ status: String = "completed", project: String = "p", at: Double = midday, _ change: (inout SessionItem) -> Void = { _ in }) -> SessionItem {
  var session = SessionItem(id: id, title: id, status: status, projectId: project, lastMessageAt: at, lastReadAt: at)
  change(&session)
  return session
}
let inboxCatalog = SessionCatalog(projects: [SessionProject(id: "p", name: "lody-ios")], sessions: [
  item("waiting", "waiting"), item("failed", "error"), item("running", "running"),
  item("unread") { $0.lastReadAt = midday - hour }, item("pinned") { $0.pinned = true },
  item("today"), item("yesterday", at: midday - day), item("week", at: midday - 3 * day), item("month", at: midday - 20 * day),
  item("older", at: midday - 60 * day), item("archived") { $0.archived = true },
])
let inbox = InboxSections.inbox(inboxCatalog, now: midday)
precondition(inbox.map(\.id) == ["pinned", "attention", "live", "unread", "today", "yesterday", "week", "month", "older"], "\(inbox.map(\.id))")
precondition(inbox[1].rows.map(\.id) == ["waiting", "failed"] && inbox[1].header == "inbox.section.attention")
precondition(!inbox.flatMap(\.rows).contains { $0.id == "archived" }, "Archived sessions stay out until searched")
precondition(InboxSections.inbox(inboxCatalog, keyword: "archived", now: midday).flatMap(\.rows).map(\.id) == ["archived"])
precondition(inbox[2].rows[0].imageTint == "blue" && inbox[4].rows[0].imageTint.isEmpty && inbox[1].rows[1].imageTint == "danger")
precondition(inbox[1].rows[0].subtitle == "lody-ios" && inbox.flatMap(\.rows).allSatisfy { $0.diff.isEmpty })

let many = SessionCatalog(projects: [SessionProject(id: "p", name: "lody-ios", rootPath: "/Users/me/git/lody-ios"), SessionProject(id: "empty", name: "Empty")],
  sessions: (0..<6).map { item("s\($0)", at: midday - Double($0) * hour) } + [item("c1", project: "m:unassigned"), item("pin") { $0.pinned = true }])

let hits = InboxSections.match(many, keyword: "LODY")
precondition(hits.projectIds == ["p"] && hits.sessions.count == 7)
let found = InboxSections.search(many, hits: InboxSearchHits(projectIds: ["p"], sessions: [("s1", "matched line"), ("s2", nil)]), now: midday)
precondition(found.map(\.id) == ["projects", "sessions"] && found[0].rows[0].id == "project:p" && found[0].rows[0].menuActions.count == 3)
precondition(found[1].rows.map(\.id) == ["s1", "s2"] && found[1].rows[0].subtitle == "matched line" && found[1].rows[1].subtitle == "lody-ios")
let highlighted = InboxSections.search(many, hits: InboxSearchHits(projectIds: ["p"], sessions: [("s1", "matched line"), ("s2", nil)]), query: "matched", now: midday)
precondition(highlighted[1].rows.allSatisfy { $0.highlight == "matched" }, "Search rows carry the query to highlight")
precondition(highlighted[1].rows[0].wrapSubtitle && !highlighted[1].rows[1].wrapSubtitle, "Only message snippets take a second line")
precondition(highlighted[0].rows[0].highlight == "matched", "Project hits highlight too")
precondition(InboxSections.search(many, hits: InboxSearchHits()).isEmpty)
precondition(InboxSections.activityBucket(.nan, now: midday) == "today" && InboxSections.activityBucket(midday - 8 * day, now: midday) == "month")
let entry: [String: Any] = [
  "fileDiffs": [["path": "a.swift", "add": 2, "del": 1]],
  "items": [
    ["type": "tool_call", "kind": "edit", "path": "a.swift", "added": 9, "removed": 9],
    ["type": "tool_call", "kind": "read", "path": "r.swift", "added": 1],
    ["type": "tool_call", "kind": "write", "path": "n.swift", "added": 4],
    ["type": "tool_call", "kind": "edit", "path": "n.swift", "added": 1, "removed": 2],
    ["type": "tool_call", "kind": "delete", "path": "n.swift"],
    ["type": "tool_call", "kind": "edit", "path": ""],
    ["type": "text", "path": "t.swift"],
  ],
]
let files = SessionEnvelope.changedFiles(entry)
precondition(files.map { $0["path"] as? String } == ["a.swift", "n.swift"], "Recorded diffs win; reads, empty paths and non-tools are skipped")
precondition(files[0]["add"] as? Int == 2 && files[0]["status"] as? String == "M")
precondition(files[1]["add"] as? Int == 5 && files[1]["del"] as? Int == 2 && files[1]["status"] as? String == "D")
let envelope = SessionEnvelope.prepare(#"{"v":1,"status":"live","revision":4,"preview":{"label":"localhost:5173","active":true},"entries":[{"id":"e","items":[]}]}"#)!
precondition(envelope.revision == 4 && envelope.entriesJSON.contains(#""fileDiffs":[]"#))
let pendingEnvelope = SessionEnvelope.prepare(#"{"v":1,"status":"live","revision":5,"entries":[{"id":"server","role":"user","status":"pending","items":[]}],"pendingRoostInputs":[{"id":"server","role":"user","status":"pending","items":[],"inputState":"unknown"},{"id":"local","role":"user","status":"pending","items":[],"inputState":"unknown"}]}"#)!
let pendingEntries = try JSONSerialization.jsonObject(with: Data(pendingEnvelope.entriesJSON.utf8)) as! [[String: Any]]
precondition(pendingEntries.compactMap { $0["id"] as? String } == ["server", "local"])
precondition(pendingEnvelope.transcript.entryIds == ["server"], "A local input must not be treated as owner history")
precondition(SessionEnvelope.prepare("not json") == nil && SessionEnvelope.prepare(#"{"v":1,"overflow":true}"#)!.overflow)
precondition(envelope.accepted(generation: 0, after: (-1, -1)), "A newer runtime generation resets the cursor")
precondition(!envelope.accepted(generation: 0, after: (1, -1)), "Older generations drop")
precondition(!envelope.accepted(generation: 1, after: (1, 4)) && envelope.accepted(generation: 1, after: (1, 3)), "Same generation needs a newer revision")
precondition(!SessionEnvelope(version: 2, revision: 9).accepted(generation: 5, after: (1, 1)), "Unknown envelope versions drop")
print("PASS: session rows, inbox sections and session envelopes match the catalog projections")

let toolsCatalog = SessionCatalog.decode(saved: Data(#"{"catalog":{"projects":[],"machineIds":["mac"],"machineSimulators":{"mac":"available"},"machineEmulators":{"mac":"available","linux":"available"},"sessions":[{"id":"with-tools","pullRequests":[{"repository":"Innei/lody-ios","number":31,"status":"open","ci":"f"}],"iosSimulatorPreviewRequestId":"preview-request","androidEmulatorPreviewRequestId":"emulator-request"}]}}"#.utf8))!
precondition(toolsCatalog.machineSimulators["mac"] == "available")
precondition(toolsCatalog.machineEmulators["linux"] == "available" && toolsCatalog.machineSimulators["linux"] == nil)
precondition(toolsCatalog.session("with-tools")?.androidEmulatorPreviewRequestId == "emulator-request")
precondition(toolsCatalog.session("with-tools")?.pullRequests.first?.number == 31)
precondition(toolsCatalog.session("with-tools")?.iosSimulatorPreviewRequestId == "preview-request")

precondition(envelope.preview == SessionBrowserPreview(label: "localhost:5173", active: true))

var tabRoot = root
tabRoot.archived = false
var directoryTab = tab
directoryTab.archived = false
var openedChat = child
openedChat.archived = false
var sidePanel = directoryTab
sidePanel.id = "side"
sidePanel.childSessionPlacement = "side-panel"
let directoryFamily = DirectoryTabs.sessions(current: directoryTab, all: [openedChat, sidePanel, directoryTab, tabRoot])
precondition(directoryFamily.map(\.id) == ["root", "tab"])
precondition(DirectoryTabs.sessions(current: tabRoot, all: [tabRoot, openedChat]).count == 1)
print("PASS: directory Tabs exclude opened chats and side panels")

var closedRoot = tabRoot
closedRoot.isTabClosed = true
precondition(DirectoryTabs.sessions(current: directoryTab, all: [closedRoot, directoryTab]).map(\.id) == ["tab"])
precondition(DirectoryTabs.closed(current: directoryTab, all: [closedRoot, directoryTab]).map(\.id) == ["root"])
precondition(!SessionRows.isUnread(closedRoot))
let decodedClosed = try! JSONDecoder().decode(SessionItem.self, from: Data(#"{"id":"saved","isTabClosed":true}"#.utf8))
precondition(decodedClosed.isTabClosed)
print("PASS: closed Tabs remain recoverable without hiding open children")

let preferenceSuite = "tab-selection-test-" + UUID().uuidString
let preferences = UserDefaults(suiteName: preferenceSuite)!
let selection = SessionTabSelection(defaults: preferences)
selection.remember(directoryTab, all: [tabRoot, directoryTab], user: "u", workspace: "w")
let restarted = SessionTabSelection(defaults: UserDefaults(suiteName: preferenceSuite)!)
precondition(restarted.resolve(tabRoot, all: [tabRoot, directoryTab], user: "u", workspace: "w") == directoryTab.id)
precondition(restarted.resolve(tabRoot, all: [tabRoot, directoryTab], user: "other", workspace: "w") == tabRoot.id)
precondition(restarted.resolve(tabRoot, all: [tabRoot, directoryTab], user: "u", workspace: "other") == tabRoot.id)
var closedTab = directoryTab
closedTab.isTabClosed = true
precondition(restarted.resolve(tabRoot, all: [tabRoot, closedTab], user: "u", workspace: "w") == tabRoot.id)
precondition(restarted.resolve(tabRoot, all: [tabRoot], user: "u", workspace: "w") == tabRoot.id)
precondition(restarted.resolve(directoryTab, all: [tabRoot, directoryTab], user: "u", workspace: "w") == directoryTab.id)
var readTab = directoryTab
readTab.status = "idle"
readTab.lastMessageAt = 100
readTab.lastReadAt = nil
let viewedCatalog = SessionCatalog(sessions: [readTab]).viewed([readTab.id: 100])
precondition(!SessionRows.needsEmphasis(viewedCatalog.sessions[0]))
readTab.lastMessageAt = 101
precondition(SessionRows.needsEmphasis(SessionCatalog(sessions: [readTab]).viewed([readTab.id: 100]).sessions[0]))
preferences.removePersistentDomain(forName: preferenceSuite)
print("PASS: remembered Tabs survive reload, respect scope and fall back from closed/deleted Tabs; viewed watermarks preserve new unread output")

precondition(PullRequestCI("x")?.rawValue == "expected", "Expected checks must differ from running CI, as Web SessionPrIcon")

// Internal Tabs contribute attention to their listed conversation, even under My tasks.
let tabOwner = SessionItem(id: "tab-owner", userId: "me", projectId: "p", machineId: "m")
let runningTab = SessionItem(id: "running-tab", status: "running", userId: "other", projectId: "p", parentSessionId: tabOwner.id, machineId: "m")
func tabRows(_ tabs: [SessionItem], owner: String? = nil) -> [LodyListRow] {
  InboxSections.home(SessionCatalog(sessions: [tabOwner] + tabs), grouping: .status, owner: owner, now: now).flatMap(\.rows)
}
precondition(tabRows([runningTab]).map(\.id) == [tabOwner.id])
precondition(tabRows([runningTab]).first?.imageTint == "blue", "Running Tab must reach its conversation row")
precondition(tabRows([runningTab], owner: "me").first?.imageTint == "blue")
var stoppedTab = runningTab
stoppedTab.status = "idle"
precondition(tabRows([stoppedTab]).first?.imageTint == "")
stoppedTab.status = "error"
precondition(tabRows([stoppedTab]).first?.imageTint == "danger")
var waitingTab = runningTab
waitingTab.id = "nested-tab"
waitingTab.parentSessionId = runningTab.id
waitingTab.status = "requestPermission"
precondition(tabRows([runningTab, waitingTab]).first?.imageTint == "warning")
var closedRunning = runningTab
closedRunning.isTabClosed = true
precondition(tabRows([closedRunning]).first?.imageTint == "blue")
var excludedTab = runningTab
excludedTab.archived = true
precondition(tabRows([excludedTab]).first?.imageTint == "")
excludedTab = runningTab
excludedTab.childSessionPlacement = "side-panel"
precondition(tabRows([excludedTab]).first?.imageTint == "")
excludedTab = runningTab
excludedTab.machineId = "other-machine"
precondition(tabRows([excludedTab]).first?.imageTint == "")
var unreadTab = runningTab
unreadTab.status = "completed"
unreadTab.lastMessageAt = 20
unreadTab.lastReadAt = 10
precondition(tabRows([unreadTab]).first?.unread == true)
unreadTab.isTabClosed = true
precondition(tabRows([unreadTab]).first?.unread == false)
var separateOpenedChat = runningTab
separateOpenedChat.parentSessionId = nil
separateOpenedChat.openedBySessionId = tabOwner.id
precondition(tabRows([separateOpenedChat]).first?.imageTint == "")

// Hiding the repeated project label must not erase raw repository identity used by
// the index; an opened child from another project must not supply the root logo.
let logoCatalog = SessionCatalog(projects: [
  SessionProject(id: "logo-root", name: "Root", repoFullName: "synthetic-owner/root"),
  SessionProject(id: "logo-child", name: "Child", repoFullName: "another-owner/child"),
], sessions: [
  SessionItem(id: "logo-session", projectId: "logo-root"),
  SessionItem(id: "logo-opened", projectId: "logo-child", openedBySessionId: "logo-session"),
])
let logoGroups = InboxSections.home(logoCatalog, grouping: .project, now: now)
precondition(logoGroups.count == 1 && logoGroups[0].id == "group:logo-root")
precondition(logoGroups[0].rows[0].place.isEmpty)
precondition(logoGroups[0].rows[0].repository == "synthetic-owner/root")
precondition(logoGroups[0].rows[1].repository == "another-owner/child")
print("PASS: project grouping hides presentation while retaining root and cross-project child repository identity")


var relationRoot = SessionItem(id: "relation-root", title: "Root")
var relationTab = SessionItem(id: "relation-tab", title: "Tab", parentSessionId: relationRoot.id)
var relationChild = SessionItem(id: "relation-child", title: "Child", openedBySessionId: relationTab.id, openedByRootSessionId: relationRoot.id)
var relationSibling = SessionItem(id: "relation-sibling", openedBySessionId: relationRoot.id)
var relationGrandchild = SessionItem(id: "relation-grandchild", openedBySessionId: relationChild.id)
var relationSide = SessionItem(id: "relation-side", childSessionPlacement: "side-panel", parentSessionId: relationRoot.id)
var relationClosed = SessionItem(id: "relation-closed", isTabClosed: true, parentSessionId: relationRoot.id)
let related = [relationRoot, relationTab, relationChild, relationSibling, relationGrandchild, relationSide, relationClosed]
let relationTree = SessionRelations.tree(sessions: related, current: relationChild.id)
precondition(relationTree.hasRelations)
precondition(Set(relationTree.rows.flatMap { $0.sessions.map(\.id) }) == Set([relationRoot.id, relationTab.id, relationChild.id, relationSibling.id, relationGrandchild.id]))
precondition(relationTree.rows.first { $0.session.id == relationChild.id }?.depth == 1)
precondition(relationTree.rows.first { $0.session.id == relationGrandchild.id }?.depth == 2)
precondition(relationTree.rows.count == 4, "Contained Tabs do not add hierarchy rows")
precondition(relationTree.rows.first { $0.session.id == relationRoot.id }?.tabs.map(\.id) == [relationTab.id])
precondition(!relationTree.rows.contains { $0.session.id == relationTab.id }, "Tabs share the root row")
let branchRows = relationTree.rows
let rootBranch = SessionRelations.branch(at: 0, rows: branchRows)
let childBranch = SessionRelations.branch(at: branchRows.firstIndex { $0.session.id == relationChild.id }!, rows: branchRows)
let grandchildBranch = SessionRelations.branch(at: branchRows.firstIndex { $0.session.id == relationGrandchild.id }!, rows: branchRows)
let lastBranch = SessionRelations.branch(at: branchRows.count - 1, rows: branchRows)
precondition(rootBranch.depth == 0 && rootBranch.ancestors.isEmpty)
precondition(childBranch.depth == 1 && childBranch.continues, "Parent rail continues through its descendants to the next sibling")
precondition(grandchildBranch.depth == 2 && grandchildBranch.ancestors == [0] && !grandchildBranch.continues)
precondition(!lastBranch.continues, "Final child ends its curved branch without a dangling trunk")
precondition(SessionRelations.target(relationTab.id, sessions: related) == relationTab.id)
precondition(SessionRelations.target(relationTab.id, sessions: related.filter { $0.id != relationRoot.id }) == nil)
precondition(!SessionRelations.tree(sessions: [relationRoot, relationTab], current: relationTab.id).hasRelations)
precondition(!SessionRelations.tree(sessions: [relationRoot, relationChild], current: relationChild.id).hasRelations, "Missing precise opener must not fall back to openedByRootSessionId")
precondition(SessionRelations.tree(sessions: related, current: relationClosed.id).rows.contains { $0.tabs.contains { $0.id == relationClosed.id } })
relationRoot.archived = true
precondition(SessionRelations.target(relationTab.id, sessions: [relationRoot, relationTab]) == nil)
relationRoot.archived = false
relationRoot.openedBySessionId = relationGrandchild.id
let cycle = SessionRelations.tree(sessions: [relationRoot, relationTab, relationChild, relationGrandchild], current: relationChild.id)
precondition(cycle.rows.count == 3 && Set(cycle.rows.flatMap { $0.sessions.map(\.id) }).count == 4)
print("Related conversations: precise opener, containment, exact Tab targets, missing/archived roots and cycles passed")

// A refresh rebuilds the projection; Settled folds past its root limit without splitting a family.
let settledSessions = (0..<21).map {
  SessionItem(id: "settled-root-\($0)", projectId: "p", lastMessageAt: Double(100 - $0), lastReadAt: 100)
} + [SessionItem(id: "settled-child", projectId: "other", openedBySessionId: "settled-root-19", lastMessageAt: 1, lastReadAt: 100)]
var settledLayout = StatusViewLayout(settled: (0..<21).map { index in
  StatusViewRow(
    id: "settled-root-\(index)", tier: .settled,
    children: index == 19 ? [StatusViewRow(id: "settled-child", tier: .settled)] : [], activityAt: Double(100 - index)
  )
})
func settledRows(_ layout: StatusViewLayout, expanded: Bool = false) -> [LodyListRow] {
  InboxSections.home(SessionCatalog(sessions: settledSessions), grouping: .status, layout: layout, settledExpanded: expanded, now: now)
    .first { $0.id == InboxSections.settledId }?.rows ?? []
}
let limitedSettled = settledRows(settledLayout)
precondition(limitedSettled.count == 22 && limitedSettled.suffix(2).map(\.id) == ["settled-child", InboxSections.settledMoreId])
precondition(limitedSettled.first { $0.id == "settled-child" }?.parentId == "settled-root-19")
precondition(!limitedSettled.contains { $0.id == "settled-root-20" })
precondition(settledRows(settledLayout, expanded: true).count == 23)
settledLayout.settled.removeLast()
precondition(!settledRows(settledLayout).contains { $0.id == InboxSections.settledMoreId })
for grouping in [HomeGrouping.time, .project, .status] {
  let cycleRows = InboxSections.home(SessionCatalog(sessions: [cycleA, cycleB]), grouping: grouping, now: now).flatMap(\.rows)
  precondition(cycleRows.map(\.id) == ["a", "b"] && cycleRows.allSatisfy { $0.parentId.isEmpty })
}

// Share/project ordering includes contained Tabs, ignores archives, and breaks ties by name.
let sortProjects = [SessionProject(id: "b", name: "Beta"), SessionProject(id: "a", name: "Alpha"), SessionProject(id: "empty", name: "Empty"), SessionProject(id: "m:unassigned", name: "Chat")]
var sortSessions = [
  SessionItem(id: "sort-a", status: "idle", projectId: "a", lastMessageAt: 10),
  SessionItem(id: "sort-b", status: "idle", projectId: "b", lastMessageAt: 10),
  SessionItem(id: "sort-archive", status: "waiting", archived: true, projectId: "empty", lastMessageAt: 100),
]
precondition(InboxSections.sortProjects(sortProjects, sessions: sortSessions, sort: .activity).map(\.id) == ["a", "b", "empty"])
sortSessions.append(SessionItem(id: "sort-tab", status: "waiting", projectId: "b", parentSessionId: "sort-b", lastMessageAt: 20))
precondition(InboxSections.sortProjects(sortProjects, sessions: sortSessions, sort: .urgency).map(\.id) == ["b", "a", "empty"])
precondition(InboxSections.sortProjects(sortProjects, sessions: sortSessions, sort: .activity).map(\.id) == ["b", "a", "empty"])
precondition(InboxSections.sortProjects(sortProjects, sessions: sortSessions, sort: .name).map(\.id) == ["a", "b", "empty"])
print("PASS: Home refresh, complete settled families, cycles and project sorting retain projection semantics")

// MARK: Status view layout (runtime `catalog.statusView`, rendered without native sorting)

let statusSaved = """
{"catalog":{"projects":[{"id":"p","name":"Lody"}],"machineIds":[],"sessions":[
{"id":"pin-default","title":"Pinned default","pinned":true,"projectId":"p","createdAt":"2026-01-02T03:04:05Z","lastMessageAt":\(now - 10 * hour),"lastReadAt":\(now)},
{"id":"pin-maint","title":"Mirror check","pinned":true,"projectId":"p","createdAt":"2026-01-02T03:04:05Z","lastMessageAt":\(now - 20 * hour),"lastReadAt":\(now)},
{"id":"focus-old","title":"Older but first","projectId":"p","createdAt":"2026-01-02T03:04:05Z","lastMessageAt":\(now - 30 * hour),"lastReadAt":\(now)},
{"id":"focus-new","title":"Newer but second","projectId":"p","createdAt":"2026-01-02T03:04:05Z","lastMessageAt":\(now - hour)},
{"id":"focus-child","title":"Opened child","projectId":"p","createdAt":"2026-01-02T03:04:05Z","openedBySessionId":"focus-new","lastMessageAt":\(now - hour)},
{"id":"later-a","title":"Snoozed","projectId":"p","createdAt":"2026-01-02T03:04:05Z","lastMessageAt":\(now - hour)},
{"id":"settled-a","title":"Done","projectId":"p","createdAt":"2026-01-02T03:04:05Z","lastMessageAt":\(now - 200 * hour)},
{"id":"read-only","title":"Teammate's","projectId":"p","createdAt":"2026-01-02T03:04:05Z","lastMessageAt":\(now - hour)}
],
"pinSections":[{"id":"maint","name":"Maintenance","orderKey":"80"},{"id":"empty","name":"Empty","orderKey":"90"},{"broken":true}],
"statusView":{
 "mine":{
  "pinned":[
   {"sectionId":null,"name":null,"rows":[{"id":"pin-default","tier":"pinned","children":[],"activityAt":\(now - 10 * hour),"unread":false,"snoozedUntil":null,"woken":false,"canManage":true,"canPrefer":true}],"hiddenCount":0},
   {"sectionId":"maint","name":"Maintenance","rows":[{"id":"pin-maint","tier":"pinned","children":[],"activityAt":\(now - 20 * hour),"unread":false,"snoozedUntil":null,"woken":false,"canManage":true,"canPrefer":true}],"hiddenCount":2},
   {"sectionId":"empty","name":"Empty","rows":[],"hiddenCount":0}
  ],
  "focus":[
   {"id":"focus-old","tier":"focus","children":[],"activityAt":\(now - 2 * hour),"unread":true,"snoozedUntil":null,"woken":true,"canManage":true,"canPrefer":true},
   {"id":"focus-new","tier":"focus","children":[{"id":"focus-child","tier":"focus","children":[],"activityAt":\(now - hour),"unread":false,"snoozedUntil":null,"woken":false,"canManage":true,"canPrefer":true}],"activityAt":\(now - hour),"unread":true,"snoozedUntil":null,"woken":false,"canManage":true,"canPrefer":true},
   {"id":"read-only","tier":"focus","children":[],"activityAt":\(now - hour),"unread":false,"snoozedUntil":null,"woken":false,"canManage":false,"canPrefer":false},
   {"id":"unknown-tier","tier":"someday","children":[]}
  ],
  "later":[{"id":"later-a","tier":"later","children":[],"activityAt":\(now - hour),"unread":false,"snoozedUntil":\(now + 2 * hour + 60_000),"woken":false,"canManage":true,"canPrefer":true}],
  "settled":[{"id":"settled-a","tier":"settled","children":[],"activityAt":\(now - 200 * hour),"unread":false,"snoozedUntil":null,"woken":false,"canManage":true,"canPrefer":true}],
  "canManageSections":true,
  "nextChangeAt":\(now + 2 * hour)
 },
 "team":{"pinned":[],"focus":[],"later":[],"settled":[],"canManageSections":false,"nextChangeAt":null},
 "nowMs":\(now),
 "sectionsLoaded":true
}}}
"""
let statusCatalog = SessionCatalog.decode(saved: Data(statusSaved.utf8))!
let statusLayouts = statusCatalog.statusView!
let statusLayout = statusLayouts.mine
precondition(statusCatalog.pinSections.map(\.id) == ["maint", "empty"], "Malformed pin section rows are dropped, not the catalog")
precondition(statusLayouts.nowMs == now && statusLayouts.sectionsLoaded && statusLayout.canManageSections && !statusLayouts.team.canManageSections)
precondition(statusLayout.focus.map(\.id) == ["focus-old", "focus-new", "read-only"], "Unknown tiers drop only that row")
precondition(statusLayout.focus[1].children.map(\.id) == ["focus-child"] && statusLayout.later[0].snoozedUntil != nil)
precondition(statusLayout.nextChangeAt == now + 2 * hour && statusLayouts.team.focus.isEmpty)
precondition(statusLayout.pinned.map(\.sectionId) == [nil, "maint", "empty"] && statusLayout.pinned[1].hiddenCount == 2)
precondition(statusLayouts.row("pin-maint", team: true)?.tier == .pinned, "The conversation page finds a row in either scope")
precondition(SessionCatalog.decode(saved: Data(saved.utf8))?.statusView == nil, "Catalogs from older runtimes carry no layout")

let statusSections = InboxSections.home(statusCatalog, grouping: .status, layout: statusLayout, now: now)
precondition(statusSections.map(\.id) == ["pinned", "pinned:maint", "pinned:empty", "focus", "later", "settled"], "\(statusSections.map(\.id))")
precondition(statusSections.map(\.header) == ["inbox.section.pinned", "Maintenance", "Empty", "home.status.focus", "home.status.later", "home.status.settled"])
let focusSection = statusSections[3]
precondition(focusSection.rows.map(\.id) == ["focus-old", "focus-new", "focus-child", "read-only"], "Layout order wins over recency")
precondition(focusSection.rows[2].parentId == "focus-new" && focusSection.headerValue == "4")
precondition(focusSection.rows[0].unread && focusSection.rows[0].value == LodyRelativeTime.compact(now - 2 * hour, now: now),
  "Unread and activity time come from the layout row (a woken snooze)")
precondition(!statusSections[1].rows.contains { $0.id == "focus-old" })
precondition(statusSections[1].rows.last?.id == InboxSections.hiddenRowPrefix + "pinned:maint", "The scope-hidden count follows its section")
precondition(statusSections[2].rows.isEmpty && statusSections[2].keepsEmpty, "An empty user section stays a drop target")
precondition(statusSections[0].headerMenu.map(\.id) == [InboxSections.sectionActions.create], "The default section is only a place to create one")
precondition(statusSections[1].headerMenu.map(\.id) == [
  InboxSections.sectionActions.create, InboxSections.sectionActions.rename, InboxSections.sectionActions.down, InboxSections.sectionActions.delete,
])
precondition(statusSections[2].headerMenu.map(\.id).contains(InboxSections.sectionActions.up)
  && !statusSections[2].headerMenu.map(\.id).contains(InboxSections.sectionActions.down))

// Swipes and menus follow the tier and the row's permissions.
let swipeIds = { (row: LodyListRow) in row.actions.map(\.id) }
precondition(swipeIds(focusSection.rows[0]) == [InboxSections.statusActions.settle, InboxSections.statusActions.later])
precondition(focusSection.rows[0].leadingActions.map(\.id) == ["pin"] && !focusSection.rows[0].pinned)
precondition(!focusSection.rows[0].menuActions.contains { $0.id == "pin" }, "Pin lives in the status menu beside Move to section")
let readOnlyRow = focusSection.rows[3]
precondition(readOnlyRow.actions.isEmpty && readOnlyRow.leadingActions.isEmpty, "Read-only members are offered no status or pin actions")
precondition(readOnlyRow.menuActions.map(\.id) == ["share"], "Without canManage, Rename, Archive and Delete leave the menu too")
let laterRow = statusSections[4].rows[0]
precondition(swipeIds(laterRow) == [InboxSections.statusActions.settle, InboxSections.statusActions.later])
precondition(laterRow.value == "3h" && laterRow.valueSymbol == "clock", "Later rows show their countdown")
precondition(swipeIds(statusSections[5].rows[0]) == ["archive", InboxSections.statusActions.focus], "Settled rows offer Archive and Move to Focus")
precondition(statusSections[0].rows[0].pinned && statusSections[0].rows[0].leadingActions.first?.title == "session.action.unpin")

// The local viewed watermark clears emphasis before the read receipt syncs.
var viewedStatus = statusCatalog
viewedStatus.sessions = viewedStatus.sessions.map { session in
  var session = session
  if session.id == "focus-new" { session.lastViewedMessageAt = now - hour }
  return session
}
precondition(InboxSections.home(viewedStatus, grouping: .status, layout: statusLayout, now: now)[3].rows[1].unread == false)

// Time and project buckets keep native grouping but never repeat a pinned conversation.
for grouping in [HomeGrouping.time, .project] {
  let sections = InboxSections.home(statusCatalog, grouping: grouping, layout: statusLayout, now: now)
  precondition(Array(sections.prefix(3).map(\.id)) == ["pinned", "pinned:maint", "pinned:empty"])
  let ids = sections.flatMap(\.rows).map(\.id)
  precondition(ids.filter { $0 == "pin-maint" }.count == 1 && ids.contains("settled-a"))
}

// A creation the catalog has not read back opens at the top of Focus.
var pendingCatalog = statusCatalog
pendingCatalog.sessions.append(SessionItem.markedPending(SessionItem(id: "pending-new", projectId: "p")))
precondition(InboxSections.home(pendingCatalog, grouping: .status, layout: statusLayout, now: now)[3].rows.first?.id == "pending-new")

// Drop planning: the neighbour the row lands before, the area rules, and keyboard-free alternatives.
let items = ["focus-old", "focus-new", "focus-child", "read-only"]
let roots: Set = ["focus-old", "focus-new", "read-only"]
precondition(StatusViewPlanning.beforeId(moving: "read-only", family: [], items: items, roots: roots, index: 0) == "focus-old")
precondition(StatusViewPlanning.beforeId(moving: "focus-old", family: [], items: items, roots: roots, index: 3) == nil, "The end lands last")
precondition(StatusViewPlanning.beforeId(moving: "focus-old", family: [], items: items, roots: roots, index: 1) == "read-only",
  "A drop between an opener and its child lands after that family")
precondition(StatusViewPlanning.beforeId(moving: "focus-new", family: ["focus-child"], items: items, roots: roots, index: 1) == "read-only")
let laterLayoutRow = statusLayout.later[0]
precondition(StatusViewPlanning.drop(laterLayoutRow, into: .focus, beforeId: "focus-old")
  == .move(sessionId: "later-a", to: .focus, beforeId: "focus-old"), "A Later row dropped into Focus is restored there")
precondition(StatusViewPlanning.drop(statusLayout.focus[2], into: .focus, beforeId: nil) == nil, "Read-only rows cannot be reordered")
precondition(StatusViewPlanning.drop(statusLayout.pinned[0].rows[0], into: .focus, beforeId: nil)
  == .move(sessionId: "pin-default", to: .focus, beforeId: nil), "A pinned row dropped into Focus is unpinned there (Spec)")
var pinOnly = statusLayout.pinned[0].rows[0]
pinOnly.canManage = false
precondition(StatusViewPlanning.drop(pinOnly, into: .focus, beforeId: nil) == nil, "Placing in Focus still needs canManage")
// An Outbox creation listed above Focus is unknown to the planner: dropping before it means the top.
precondition(StatusViewPlanning.knownBefore("pending-new", moving: "later-a", in: .focus, of: statusLayout) == "focus-old")
precondition(StatusViewPlanning.knownBefore("pending-new", moving: "focus-old", in: .focus, of: statusLayout) == "focus-new")
precondition(StatusViewPlanning.knownBefore("focus-new", moving: "later-a", in: .focus, of: statusLayout) == "focus-new")
precondition(StatusViewPlanning.knownBefore(nil, moving: "later-a", in: .focus, of: statusLayout) == nil)
precondition(StatusViewPlanning.drop(statusLayout.focus[0], into: .pinned("maint"), beforeId: nil)
  == .move(sessionId: "focus-old", to: .pinned("maint"), beforeId: nil), "Dropping into the pin area pins")
precondition(StatusViewPlanning.step("focus-new", up: true, in: statusLayout) == .move(sessionId: "focus-new", to: .focus, beforeId: "focus-old"))
precondition(StatusViewPlanning.step("focus-old", up: false, in: statusLayout) == .move(sessionId: "focus-old", to: .focus, beforeId: "read-only"))
precondition(StatusViewPlanning.step("focus-new", up: false, in: statusLayout) == .move(sessionId: "focus-new", to: .focus, beforeId: nil))
precondition(StatusViewPlanning.step("focus-old", up: true, in: statusLayout) == nil && StatusViewPlanning.step("focus-child", up: true, in: statusLayout) == nil)
precondition(StatusViewPlanning.step("later-a", up: true, in: statusLayout) == nil, "Later keeps the runtime's wake-up order")
let moveDirections = StatusViewPlanning.moveDirections(in: statusLayout)
precondition(moveDirections["focus-old"] == .init(up: false, down: true))
precondition(moveDirections["focus-new"] == .init(up: true, down: true))
precondition(moveDirections["focus-child"] == nil && moveDirections["read-only"] == nil && moveDirections["later-a"] == nil)
precondition(StatusViewPlanning.moveToTop("focus-new", in: statusLayout) == .move(sessionId: "focus-new", to: .focus, beforeId: "focus-old"))
precondition(StatusViewPlanning.moveToTop("focus-old", in: statusLayout) == nil)
precondition(StatusViewArea(sectionId: "pinned:maint") == .pinned("maint") && StatusViewArea(sectionId: "pinned") == .pinned(nil)
  && StatusViewArea(sectionId: "later") == nil && StatusViewArea.pinned("maint").sectionId == "pinned:maint")
let sectionOrder = ["a", "b", "c"]
precondition(StatusViewPlanning.moveSection("b", up: true, sections: sectionOrder) == .moveSection(sectionId: "b", beforeId: "a"))
precondition(StatusViewPlanning.moveSection("a", up: false, sections: sectionOrder) == .moveSection(sectionId: "a", beforeId: "c"))
precondition(StatusViewPlanning.moveSection("b", up: false, sections: sectionOrder) == .moveSection(sectionId: "b", beforeId: nil))
precondition(StatusViewPlanning.moveSection("a", up: true, sections: sectionOrder) == nil)

// The held order shows the drop at once and yields to the catalog's read-back.
let dropped = StatusViewCommand.move(sessionId: "later-a", to: .focus, beforeId: "focus-new")
var held = StatusViewHold(dropped, base: statusLayout)!
let shown = held.apply(to: statusLayout)
precondition(shown.focus.map(\.id) == ["focus-old", "later-a", "focus-new", "read-only"] && shown.later.isEmpty)
precondition(shown.focus[1].tier == .focus && shown.focus[1].snoozedUntil == nil)
precondition(!held.released(by: statusLayout), "Unrelated or stale layouts keep the dropped order")
precondition(held.released(by: shown), "A layout showing the row where it was dropped releases the hold")
held.acknowledged = true
precondition(!held.released(by: statusLayout))
var unrelated = statusLayout
unrelated.nextChangeAt = now + 3 * hour
unrelated.settled[0].unread = true
precondition(!held.released(by: unrelated), "A catalog update that does not move the row keeps the hold until read-back")
let elsewhere = StatusViewHold(.move(sessionId: "later-a", to: .focus, beforeId: nil), base: statusLayout)!.apply(to: statusLayout)
precondition(held.released(by: elsewhere), "After the write is accepted, a layout that moved the row wins")
held.acknowledged = false
held.failed = true
precondition(held.released(by: statusLayout), "A failed write puts the published order back")
let pinnedHold = StatusViewHold(.move(sessionId: "focus-old", to: .pinned("empty"), beforeId: nil), base: statusLayout)!.apply(to: statusLayout)
precondition(pinnedHold.pinned[2].rows.map(\.id) == ["focus-old"] && pinnedHold.focus.map(\.id) == ["focus-new", "read-only"])
precondition(StatusViewHold(.settle(sessionId: "x", includeOpened: false), base: statusLayout) == nil)
// Two quick moves both stay on screen.
let firstMove = StatusViewHold(.move(sessionId: "later-a", to: .focus, beforeId: "focus-old"), base: statusLayout)!
let secondMove = StatusViewHold(.move(sessionId: "settled-a", to: .pinned("empty"), beforeId: nil), base: statusLayout)!
let both = StatusViewHold.apply([firstMove, secondMove], to: statusLayout)
precondition(both.focus.first?.id == "later-a" && both.pinned[2].rows.map(\.id) == ["settled-a"] && both.settled.isEmpty)

// A read-back for a different move can change the next row without moving this row.
let earlier = StatusViewHold(.move(sessionId: "focus-new", to: .pinned("empty"), beforeId: nil), base: statusLayout)!
var later = StatusViewHold(.move(sessionId: "focus-old", to: .focus, beforeId: nil), base: statusLayout)!
later.acknowledged = true
later.concurrentMoves = [earlier.sessionId]
let partial = earlier.apply(to: statusLayout)
precondition(earlier.released(by: partial))
precondition(!later.released(by: partial), "Another move's read-back must not release this row")
let complete = later.apply(to: partial)
precondition(later.released(by: complete) && complete.focus.last?.id == "focus-old")

// Undo returns each conversation to where it was: a child that was already settled stays settled.
precondition(StatusViewPlanning.undo([statusLayout.focus[1], statusLayout.settled[0], statusLayout.focus[1]], now: now)
  == [.moveToFocus(sessionId: "focus-new", includeOpened: false), .settle(sessionId: "settled-a", includeOpened: false)])
// Undo returns a conversation to where it was.
precondition(StatusViewPlanning.undo(statusLayout.focus[0], includeOpened: true, now: now) == .moveToFocus(sessionId: "focus-old", includeOpened: true))
precondition(StatusViewPlanning.undo(laterLayoutRow, includeOpened: false, now: now)
  == .snooze(sessionId: "later-a", until: laterLayoutRow.snoozedUntil!, includeOpened: false))
precondition(StatusViewPlanning.undo(laterLayoutRow, includeOpened: false, now: laterLayoutRow.snoozedUntil! + 1) == .moveToFocus(sessionId: "later-a", includeOpened: false))
precondition(StatusViewPlanning.undo(statusLayout.settled[0], includeOpened: false, now: now) == .settle(sessionId: "settled-a", includeOpened: false))

// Countdown labels match web `formatSnoozeCountdown`.
// Whole milliseconds, as the runtime sends them, keep the boundaries exact.
let tick = now.rounded()
for (remaining, label) in [(30_000.0, "<1m"), (45 * 60_000.0, "45m"), (2 * hour, "2h"), (23 * hour, "23h"), (3 * 24 * hour, "3d"), (24 * hour, "1d")] {
  let shown = StatusViewFormat.countdown(until: tick + remaining, now: tick)
  precondition(shown == label, "\(remaining) -> \(String(describing: shown))")
}
precondition(StatusViewFormat.countdown(until: tick, now: tick) == nil)

// Commands encode to the note's JSON; nulls stay explicit.
func commandJSON(_ command: StatusViewCommand) -> String {
  String(decoding: try! JSONSerialization.data(withJSONObject: command.json, options: [.sortedKeys]), as: UTF8.self)
}
precondition(commandJSON(.move(sessionId: "s", to: .pinned(nil), beforeId: nil))
  == #"{"beforeId":null,"sessionId":"s","to":{"area":"pinned","sectionId":null},"type":"move"}"#)
precondition(commandJSON(.move(sessionId: "s", to: .focus, beforeId: "t")) == #"{"beforeId":"t","sessionId":"s","to":{"area":"focus"},"type":"move"}"#)
precondition(commandJSON(.snooze(sessionId: "s", until: 5, includeOpened: true)) == #"{"includeOpened":true,"sessionId":"s","type":"snooze","until":5}"#)
precondition(commandJSON(.moveSection(sectionId: "a", beforeId: nil)) == #"{"beforeId":null,"sectionId":"a","type":"moveSection"}"#)

// A read-only member (the host knows the role) and unread section rows withdraw actions.
let readOnlyLayout = statusLayouts.layout(team: false, readOnly: true)
precondition(readOnlyLayout.index.values.allSatisfy { !$0.canManage && !$0.canPrefer } && !readOnlyLayout.canManageSections)
precondition(readOnlyLayout.focus.map(\.id) == statusLayout.focus.map(\.id), "Read-only members still see the same order")
let readOnlySections = InboxSections.home(statusCatalog, grouping: .status, layout: readOnlyLayout, now: now)
precondition(readOnlySections.allSatisfy { $0.headerMenu.isEmpty })
precondition(readOnlySections.flatMap(\.rows).allSatisfy { $0.leadingActions.isEmpty && !$0.actions.contains { $0.id.hasPrefix("status:") } })
var unloaded = statusLayouts
unloaded.sectionsLoaded = false
precondition(!unloaded.layout(team: false).canManageSections && unloaded.layout(team: false).index["focus-old"]?.canPrefer == true)
precondition(StatusViewPlanning.drop(readOnlyLayout.focus[0], into: .focus, beforeId: nil) == nil)

// The server clock: `nowMs` paired with the device instant it arrived at. A catalog restored from
// cache carries its receipt time, so it cannot pollute the offset; real skew of hours is kept.
var clock = StatusViewClock()
clock.observe(serverNow: tick + 30_000, deviceNow: tick)
precondition(clock.now(device: tick + 1_000) == tick + 31_000)
clock.observe(serverNow: tick - 3 * hour + 30_000, deviceNow: tick - 3 * hour)
precondition(clock.offset == 30_000, "An older sample (a cached catalog received hours ago) never replaces a newer one")
clock.observe(serverNow: tick + 2 * hour + 1_000, deviceNow: tick + 1_000)
precondition(clock.offset == 2 * hour, "A device clock hours off is still corrected")
clock.observe(serverNow: .nan, deviceNow: tick + 2_000)
precondition(clock.offset == 2 * hour)
let receivedSaved = Data((String(statusSaved.dropLast(1)) + #","syncedAt":1234}"#).utf8)
precondition(SessionCatalog.decode(saved: receivedSaved)?.statusView?.receivedAt == 1234, "The receipt time travels with nowMs")
precondition(statusLayouts.receivedAt == nil && SessionCatalog.decode(saved: receivedSaved)?.statusView == statusLayouts)

// Opening a conversation marks it read, and its root up to a woken snooze.
var wokenRoot = statusCatalog.session("focus-old")!
// Its messages were read before the snooze woke it.
wokenRoot.lastReadAt = now - 20 * hour
let wokenRow = statusLayout.index["focus-old"]!
precondition(StatusViewRead.receipts(page: wokenRoot, root: wokenRoot, rootRow: wokenRow, now: now)
  == [.init(sessionId: "focus-old", at: now, viewed: now - 2 * hour)], "Reading only up to lastMessageAt leaves a woken row unread")
var wokenTab = SessionItem(id: "woken-tab", projectId: "p", parentSessionId: "focus-old", lastMessageAt: now - 40 * hour, lastReadAt: now)
precondition(StatusViewRead.receipts(page: wokenTab, root: wokenRoot, rootRow: wokenRow, now: now)
  == [.init(sessionId: "focus-old", at: now, viewed: now - 2 * hour)], "A Tab page clears its root's wake-up")
var unreadRoot = wokenRoot
unreadRoot.lastReadAt = now - 40 * hour
precondition(StatusViewRead.receipts(page: wokenTab, root: unreadRoot, rootRow: wokenRow, now: now).isEmpty,
  "A Tab never marks its root's own unseen messages read")
wokenTab.lastReadAt = nil
precondition(StatusViewRead.receipts(page: wokenTab, root: unreadRoot, rootRow: wokenRow, now: now)
  == [.init(sessionId: "woken-tab", at: now, viewed: now - 40 * hour)])
let unreadPage = statusCatalog.session("focus-new")!
precondition(StatusViewRead.receipts(page: unreadPage, root: unreadPage, rootRow: statusLayout.index["focus-new"], now: now)
  == [.init(sessionId: "focus-new", at: now, viewed: now - hour)])
precondition(StatusViewRead.receipts(page: statusCatalog.session("pin-default")!, root: statusCatalog.session("pin-default")!,
  rootRow: statusLayout.index["pin-default"], now: now).isEmpty, "Read conversations send nothing")

// An internal Tab's unread output keeps its conversation's dot, whatever the layout row says.
var tabCatalog = statusCatalog
tabCatalog.sessions.append(SessionItem(id: "settled-tab", projectId: "p", parentSessionId: "settled-a", lastMessageAt: now - hour))
let tabSettled = InboxSections.home(tabCatalog, grouping: .status, layout: statusLayout, now: now)[5].rows[0]
precondition(tabSettled.id == "settled-a" && tabSettled.unread, "Tab unread is not overwritten by the layout row")

// An opened child carried under a pinned opener is not itself pinned: it offers Pin, not Unpin.
var carriedLayout = statusLayout
carriedLayout.pinned[0].rows[0].children = [StatusViewRow(id: "carried", tier: .pinned, activityAt: now - hour, canManage: true, canPrefer: true)]
var carriedCatalog = statusCatalog
carriedCatalog.sessions.append(SessionItem(id: "carried", projectId: "p", openedBySessionId: "pin-default", lastMessageAt: now - hour, lastReadAt: now))
let carriedRows = InboxSections.home(carriedCatalog, grouping: .status, layout: carriedLayout, now: now)[0].rows
precondition(carriedRows.map(\.id) == ["pin-default", "carried"] && carriedRows[0].pinned && !carriedRows[1].pinned)
precondition(carriedRows[1].leadingActions.first?.title == "session.action.pin")

// Time and project rows never offer management the layout withholds.
let timeReadOnly = InboxSections.home(statusCatalog, grouping: .time, layout: readOnlyLayout, now: now).flatMap(\.rows)
precondition(timeReadOnly.filter { !$0.id.hasPrefix("view:") }.allSatisfy {
  $0.leadingActions.isEmpty && !$0.actions.contains { $0.id == "archive" } && !$0.menuActions.contains { ["rename", "archive", "delete"].contains($0.id) }
})

let legacyReadOnly = InboxSections.readOnly(InboxSections.home(statusCatalog, grouping: .project, now: now))
let legacyRows = legacyReadOnly.flatMap(\.rows).filter { $0.id == "focus-old" }
precondition(legacyRows.count == 1 && legacyRows[0].leadingActions.isEmpty && legacyRows[0].actions.isEmpty
  && legacyRows[0].menuActions.contains { $0.id == "share" }
  && !legacyRows[0].menuActions.contains { ["rename", "archive", "delete", "pin"].contains($0.id) })

// The runtime's own fixture catalog decodes and renders in its order.
let runtimeFixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .appendingPathComponent("../../../../../packages/cloud-runtime/contract/fixtures/catalog-status-view.json").standardized
let fixtureCatalog = try! JSONSerialization.jsonObject(with: Data(contentsOf: runtimeFixture))
let fixture = SessionCatalog.decode(saved: try! JSONSerialization.data(withJSONObject: ["catalog": fixtureCatalog]))!
let fixtureView = fixture.statusView!
precondition(fixtureView.sectionsLoaded && fixtureView.nowMs.isFinite && !fixture.pinSections.isEmpty)
let fixtureLayout = fixtureView.layout(team: false)
let fixtureSections = InboxSections.home(fixture, grouping: .status, layout: fixtureLayout, now: fixtureView.nowMs)
let fixtureFocus = fixtureSections.first { $0.id == InboxSections.focusId }!.rows.filter { !$0.id.hasPrefix("view:") }.map(\.id)
let fixtureFocusIds = fixtureLayout.focus.flatMap(\.family).map(\.id).filter { id in fixture.sessions.contains { $0.id == id } }
precondition(fixtureFocus == fixtureFocusIds, "\(fixtureFocus) vs \(fixtureFocusIds)")
precondition(Array(fixtureSections.prefix(fixtureLayout.pinned.count).map(\.id)) == fixtureLayout.pinned.map { StatusViewArea.pinned($0.sectionId).sectionId })
print("PASS: Status view layout decodes, renders in runtime order, plans drops and holds them until read-back")

var lanSection = LodyListSection()
var cloudRow = LodyListRow()
cloudRow.id = "session"
cloudRow.preview = "session"
var shareAction = LodyListAction(); shareAction.id = "share"
var archiveAction = LodyListAction(); archiveAction.id = "archive"
cloudRow.menuActions = [shareAction, archiveAction]
lanSection.rows = [cloudRow]
let restricted = SessionRows.restrictingCloud([lanSection], lan: true)[0].rows[0]
precondition(restricted.preview == "session" && restricted.menuActions.map(\.id) == ["archive"])
precondition(SessionRows.restrictingCloud([lanSection], lan: false)[0].rows[0].preview == "session")
print("PASS: LAN preserves cached session previews and native actions while removing Cloud sharing")

// By Machine groups conversations by computer (falling back to project ownership),
// with pinned sessions split out when rendered through `home(..., grouping: .machine)`.
var machineProjects = [
  SessionProject(id: "ma", name: "A project"),
  SessionProject(id: "mb", name: "B project"),
  SessionProject(id: "mc", name: "C project"),
]
machineProjects[0].machineId = "z"
machineProjects[1].machineId = "a"
machineProjects[2].machineId = "a"
let machineCatalog = SessionCatalog(projects: machineProjects, sessions: [
  item("machine-latest", project: "ma", at: midday),
  item("machine-attention", "waiting", project: "mb", at: midday - day),
  item("machine-complete", project: "mc", at: midday - 2 * day),
  item("machine-pinned", project: "ma", at: midday) { $0.pinned = true },
  item("machine-chat", project: "w:unassigned", at: midday),
], machineIds: ["z", "a"], machineNames: ["z": "Zulu", "a": "Alpha"])
let byMachine = InboxSections.home(machineCatalog, grouping: .machine, now: midday)
precondition(byMachine.map(\.id) == ["pinned", "machine:z", "machine:", "machine:a"], "\(byMachine.map(\.id))")
precondition(byMachine[1].header == "Zulu" && byMachine[1].headerValue == "1")
precondition(byMachine[3].header == "Alpha" && byMachine[3].headerValue == "2")
var unnamedMachine = machineCatalog
unnamedMachine.machineNames = [:]
precondition(InboxSections.home(unnamedMachine, grouping: .machine, now: midday)[1].header == "z")
precondition(InboxSections.machineSectionId("a") == "machine:a" && InboxSections.isMachineSectionId("machine:a"))
print("PASS: By Machine grouping resolves machine aliases, project ownership fallback and pinned separation")
