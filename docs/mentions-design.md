# Mentions alignment (#11)

The picker inserts references, never instructions. Files stay `@path`, skills
use `$name`, GitHub references stay `#number`, commands stay `/name`. Session
and Role references carry an explicit namespace and stable id (`@session:id`,
`@role:id`) so a restored native text draft cannot silently bind to a renamed
session, another Role, or a file with the same name. Labels in the picker remain
human readable. This deliberately retains the namespaced spelling rather than
introducing a second persisted range/chip model in the native composer.

A Role is a template and its targets are what run. The catalog reads the fork's
v1 `instances`, v1 inline plus `additionalTargets`, and v2 `targets`, retaining
every target's stable identity. The picker lists every configured target across
machines, with the composer's machine first. Entries name their machine; sibling
targets on one machine also name their alias or agent. Native text keeps the
explicit `@role:<role id>@<machine id>@<target id>` identity when that machine has
several targets, and only needs the machine suffix for a unique machine target.

Role discovery does not depend on machine liveness: a Role starts another session,
which need not run where the composer does. While presence is unknown, the catalog
is marked incomplete and the Roles category remains visible. Presence, connection readiness and catalog revision changes
refresh the category and an already-open picker; send-time expansion still waits
for a complete catalog.

The runtime expands immediately before `sendTurn` writes history or the queue.
Creation's first turn uses that same send operation; Steer moves an already
expanded queue entry without expanding it twice. File, issue, PR and command
expansion is identity. Skills resolve their machine path; sessions become the
OSS MCP history query; Roles become the OSS MCP create-session instruction,
which names the Role and the instance.
Role mentions do not mutate the current turn's `agentRoleId` or run config.
This is independent of #19's current-session Role selector; both must consume
the workspace Role catalog, with private-role visibility and machine binding
checked before expansion. No separate Role store or CRUD is introduced here.

Catalogs remain native-runtime owned. Session candidates use workspace metadata,
exclude the current session and rank unarchived entries first. Commands come from
the selected agent's machine capability. Optional catalogs other than Roles with no usable rows
are hidden. File traversal and its 20,000-file ceiling remain unchanged, and
partial/truncated results stay visible in the picker. Expansion failures happen
before any durable write and leave the draft available to retry. Partial skill
discovery also blocks expansion: otherwise a missing project override could
silently resolve the same token to a global skill.

GitHub categories require a GitHub project (`github:owner/repo`). Native code
exchanges the Keychain login session for a short-lived Convex JWT, then calls
the official client repository-token action. Login sessions are not CLI tokens.
All three credentials stay native; only open issue/PR display rows reach the UIKit picker.

Verification covers reference insertion in both production hosts, direct `$` and
`/`, cancellation, missing optional sources, truncation, and the actual outbound
prompt for normal sends, queued sends, first turns and Steer. Offline fixtures
exercise production components without user credentials or a connected machine.
