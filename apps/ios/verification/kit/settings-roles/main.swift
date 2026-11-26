import Foundation
import LodyCore

func entry(
  _ id: String, owner: String = "me",
  scope: RuntimeContract.PromptShortcutScope = .init()
) -> PromptShortcutEntry {
  PromptShortcutEntry(
    v: 1, id: id, workspaceId: "w", ownerUserId: owner, name: id.uppercased(), slug: id,
    scope: scope, revision: "r1", createdAt: 1, updatedAt: 1, bodyDocId: "body-\(id)", dependencySummary: []
  )
}

let single = PromptShortcutSections.make([entry("review-pr")], userId: "me")
let row = single[0].rows[0]
precondition(row.subtitle == "/review-pr" && row.subtitleMono, "Rows show only the command")
precondition(row.trailingSymbol.isEmpty, "An owned plain shortcut is editable")

let marked = PromptShortcutSections.make(
  [entry("mine"), entry("theirs", owner: "other"), entry("context", scope: .init(machineId: "m"))],
  userId: "me"
).flatMap(\.rows).filter { $0.trailingSymbol == "eye" }
precondition(marked.map(\.id) == ["theirs", "context"], "Templates another member owns or that need context are view only")
precondition(marked.allSatisfy { $0.trailingSymbolLabel == "settings.shortcuts.viewOnly" })

let sections = PromptShortcutSections.make([entry("a"), entry("b")], userId: "me")
precondition(sections.map(\.id) == ["shortcuts"], "Workspace shortcuts render in a single section")
precondition(sections[0].footer == "settings.shortcuts.hintShort")
precondition(PromptShortcutSections.make([], userId: "me").isEmpty)

precondition(PromptShortcutSections.validSlug("review-pr") && PromptShortcutSections.validSlug("a"))
for slug in ["", "-review", "Review", "review pr", "review\n", String(repeating: "a", count: 41)] {
  precondition(!PromptShortcutSections.validSlug(slug), "Invalid slug accepted: \(slug)")
}

let value = PromptShortcutValue(
  v: 1, id: "review", workspaceId: "w", ownerUserId: "me", name: "Review", slug: "review",
  scope: .init(), revision: "r1", createdAt: 1, updatedAt: 1, prompt: "Review", mentions: []
)
precondition(!PromptShortcutSections.readOnly(value, userId: "me"))
precondition(PromptShortcutSections.readOnly(value, userId: "other"), "Only the owner edits")
var long = value
long.prompt = String(repeating: "a", count: 16001)
precondition(PromptShortcutSections.readOnly(long, userId: "me"), "Prompts beyond the mobile limit are view only")

let target = RuntimeContract.AgentRoleItemTargetsItem(
  machineId: "m1", agentConfigId: "a1", machineName: "Studio", agentName: "Coder", state: .configured
)
func role(_ id: String, owner: String = "me", name: String = "Reviewer", targets: [RuntimeContract.AgentRoleItemTargetsItem] = [target]) -> AgentRole {
  AgentRole(
    id: id, ownerUserId: owner, visibility: owner == "me" ? .private : .workspace, name: name,
    description: "Review changes", promptPrefix: "Keep changes focused.", revision: 1, updatedAt: 1, targets: targets
  )
}
var missing = target
missing.state = .agentUnavailable
let roles = AgentRoleSections.make([role("review"), role("search", owner: "other"), role("missing", targets: [missing])], userId: "me")
precondition(roles.map(\.id) == ["mine", "shared"])
precondition(roles[0].rows.map(\.id) == ["role:review", "role:missing"])
precondition(roles[0].rows[0].subtitle == "Review changes" && roles[0].rows[0].value == "settings.roles.private")
precondition(roles[0].rows[1].subtitle == "settings.roles.agentUnavailable · Review changes")
precondition(roles[1].rows.map(\.id) == ["role:search"])
precondition(roles[1].rows[0].subtitle == "Review changes" && roles[1].rows[0].value.isEmpty)
precondition(roles[1].footer == "settings.roles.hintShort")

precondition(AgentRoleSections.editable(role("r"), userId: "me"))
precondition(!AgentRoleSections.editable(role("r", owner: "other"), userId: "me"))
precondition(AgentRoleSections.editable(role("r", name: String(repeating: "😀", count: 60)), userId: "me"), "Names count code points")
precondition(!AgentRoleSections.editable(role("r", name: String(repeating: "a", count: 61)), userId: "me"))
precondition(AgentRoleSections.readOnlyHint(role("r", owner: "other"), userId: "me") == "settings.roles.readOnly")
precondition(AgentRoleSections.readOnlyHint(role("r", name: String(repeating: "a", count: 61)), userId: "me") == "settings.roles.longReadOnly")
precondition(AgentRoleSections.readOnlyHint(role("r"), userId: "me", live: false) == "settings.roles.cachedReadOnly")
precondition(AgentRoleSections.readOnlyHint(role("r", owner: "other"), userId: "me", live: false) == "settings.roles.readOnly")
precondition(AgentRoleSections.readOnlyHint(role("r"), userId: "me") == nil)

func error(_ text: String) -> NSError { NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
let duplicate = AgentRoleSections.failure(error("command_failed: role_duplicate"))
precondition(duplicate.message == "settings.roles.duplicate" && !duplicate.uncertain)
precondition(AgentRoleSections.failure(error("role_conflict")).message == "settings.remote.conflict")
let unknown = AgentRoleSections.failure(error("send_timeout: timed out"))
precondition(unknown.message == "settings.roles.unknown" && unknown.uncertain, "Unrecognised failures need a fresh read")

print("PASS: shortcut rows, view-only marks, slug and owner rules; role rows, ownership limits and failure mapping")
