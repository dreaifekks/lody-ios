# Native UI regression verification

The runner installs a signed native `Lody.app`, launches it with `--ui-verify`,
and opens independently resettable Debug scenes through `lody://debug` links.
There is no Metro server, React inspector or JavaScript UI bundle. Auth restoration,
OneSignal initialization and external networking are disabled in this mode.
Production UIKit controllers receive deterministic catalog data or scripted services.

## Run

Use Node 22 LTS, Xcode, AXe and ffmpeg. Install dependencies with `pnpm install`,
and `brew install xcodegen cmake`.
Generate with `pnpm prebuild`.

```sh
pnpm verify:simulator --name 'Native regression' -- bash -c '
  pnpm verify:build
  pnpm verify:ui --suite core --require-video --app /absolute/path/to/Lody.app
'
pnpm verify:ui --case create-parity --app /absolute/path/to/Lody.app
pnpm verify:ui --parallel --app /absolute/path/to/Lody.app
pnpm verify:native
swift test --package-path packages/lody-core
```

`verify:build` prints the app path (`--json` returns structured output) and reuses
one Xcode DerivedData per checkout. Keep signing enabled. Never use a per-task
DerivedData or copy the checkout to a temporary directory. `verify:clean` reports
and reclaims leftover builds.

Omit `--udid` to lease a `Lody * Verify` Simulator. Build-plus-check commands share
`$LODY_VERIFY_UDID` inside `verify:simulator`. Parallel mode owns separate leases;
do not wrap it in a single-device lease. Explicit `--udid` is for caller-owned
simulators, including CI. Never create unmanaged local simulators.

The runner establishes the English software keyboard and offline baseline once
per batch, then launches a fresh app for each case. Run English only (`en`,
`en_US`). Individual cases default to light and dark; core suites default to light.
`--embedded` is accepted only for old callers and has no effect.

`LODY_UI_PENDING_ONLY=1 pnpm verify:ui --case send --require-video --app /absolute/path/to/Lody.app`
checks only the pending message's Check and continue / Remove locally actions,
retained identity and delivery-only state. The full `send` case also exercises
these actions after its offline send, failure and reply scenarios.

## Case inventory

`run.py` owns the executable inventory; `--help` lists available cases and suites.

| Suite / batch                           | Coverage                                                                                                                                                |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `core`                                  | Onboarding, Home → Settings/Debug, navigation, sending, native session, create parity                                                                   |
| `core-home` / `core-send`               | The corresponding halves of core                                                                                                                        |
| `pages` batch                           | Home/workspaces, creation/model memory, project/branch/history/directory, activity, notifications, diagnostics and preferences (including the app icon) |
| `send` batch                            | Text send, queued/guide/interrupt turns, rounds, scroll behavior, session tools, permissions, editing, sharing, agent errors and native diffs/files     |
| `settings-workspace` / `settings` batch | Agents, prompt shortcuts, project visibility, GitHub, usage and agent roles                                                                             |
| Individual iPad cases                   | Adaptive split, creation, chrome, sidebar, devices, search, deletion and wide panels                                                                    |
| `toast`                                 | Archive/restore completion, archive failure, warning and copy notifications: localized accessibility labels, rendered glyph colors and dismissal        |

`home-grouping-crash` (also in `pages`) launches the offline Home fixture with
`--ui-verify-sticky-groups`: 54 conversations across three projects. It switches
time/project/status grouping eight times while scrolled and checks that rows,
semantic headings and the app process survive. Run it in light and dark with:

```sh
pnpm verify:ui --case home-grouping-crash --require-video --app /absolute/path/to/Lody.app
```

`home-status-drag` uses AXe 2.1 or newer for `drag --hold`. It checks a straight
vertical drag within Focus, a drop onto an empty pin section, and the native menu
on a stationary long press. Run it with `--case home-status-drag --require-video`.

`pad-layout` checks rotation and size-class changes with a retained conversation,
its draft and sheets, and returns to Chats to exercise a row after each compact
handoff. Its width overrides preserve window bounds and do not simulate a held
resize handle. For window-resize changes, also enable Windowed Apps on a leased
iPad Simulator and record a physical corner drag across the compact/regular
boundary: enlarge then shrink without lifting, shrink then enlarge, and enlarge
then shrink with a release between them. Check Chats rows and Schedules after
release, including gestures that end on either side of the boundary. A live
process alone is insufficient: a detached list can leave an otherwise responsive
tab bar above blank content. AXe 1.8 derives landscape touch mapping from the app
window; use portrait hardware coordinates for this windowed check.

`roles-production` checks that the real chat and new-session hosts retain the Roles category while presence is incomplete, update an already-open picker on live presence, recover an initial Role load failure, refresh when catalog revision changes with presence still live, ignore an older reload succeeding or failing after that update, and preserve same-machine instance and remote-machine references. Run it in both appearances (the default).

The native boundaries are `LodyShell`, `AuthSession`, `CatalogSession`,
`OutboxSession`, `LodyCore.AppRouting`, and feature preview controllers.
Add checks to the runner inventory and exercise production controllers.

## Evidence and behavior

Each run writes `results.json`, environment/readiness timings, AX snapshots,
screenshots, per-case logs and video when requested. Missing scenes, timeouts and
missing required video fail the run. Review screenshots for visual correctness
and video for transitions; screenshot existence alone is not acceptance.

Use `UI.open_case` to enter fixtures, never scroll through the Debug menu. Batch
text entry; tap individual keys only when testing the key itself. Prefer observable
readiness over sleeps. Use `axe drag` for UIKit pan/edge gestures. Shared controls
must be exercised in every affected host.

Before changing the new-session form, capture `create-parity` from the previous
build, then compare with `parity-diff.py`. Preserve both screenshots and video.
Native policy checks cover persistence-before-dispatch, account/workspace routing,
share inbox ingestion, watchdog recovery and no replay of uncertain writes.

Offline fixtures do not establish deployed Cloud/CLI compatibility, real APNs,
physical camera behavior or haptics. Those need separate app-authorized checks.
No desktop credentials, real turns or private user data belong in fixtures.

For visual/interaction requirement alignment only, export a finished run with
`acceptance-round.py` and ingest its claims through the acceptance tool. Ordinary
regression runs remain programmatic gates and are not ingested.

The runner reads `CFBundleIdentifier` and `LodyAppGroup` from the selected app's
Info.plist and passes that identity to child cases, including Share probes.
Standalone scripts without an `--app` input use `LODY_VERIFY_BUNDLE_ID` (or the
prebuild `LODY_BUNDLE_ID`) and `LODY_VERIFY_APP_GROUP`. The rotation probe's
`app.innei.lody.verify.width` string is a fixed Darwin notification protocol,
not an installed app identifier.

The real Share Extension probe must run inside its current managed Verify
Simulator lease, because it temporarily sets `LODY_VERIFY_OFFLINE=1` in that
simulator's launchd environment. Hold the repository heavy-work lock on the mini:

```sh
pnpm verify:simulator --name 'Share Probe' -- python3 apps/ios/verification/ui/share-probe.py \
  --app /path/to/Lody.app --lan-branches --appearance light \
  --output .artifacts/share-probe/light
```

Use a separate output directory for dark appearance. The containing app stays
stopped while the extension runs; cold handoff must observe the destination PID,
its verification environment and the process-scoped offline marker. Notification
permission UI fails this offline check. The probe restores the previous environment
on normal exit, exceptions, SIGTERM and SIGHUP. `--host-app` can reuse a matching
prebuilt probe host; it does not rebuild or re-sign that host. This probe rejects
arbitrary `--udid` devices outside the managed lease, and does not establish an
authenticated ShareInbox drain into a live outbox.

`home-machine` and `home-machine-pad` restore saved mode 3, machine aliases/project counts, folding, sort order and LAN cached transcript previews in the phone list and iPad sidebar. `connection` follows production Settings → LAN account → Connection, checks latency, failed-list retry, stream resync and heartbeat-authoritative reachability with contradictory ping outcomes. `lan-agent-usage` covers config-scoped/legacy quotas and Gemini + Argon; `lan-session-menus` covers project previews, Cloud-share isolation and active/archived terminal availability. `lan-join-errors` exercises malformed/rejected/unreachable invites and successful retry. All cases run English in both appearances without credentials or network. Notification permission providers remain disabled in offline runs; the actual post-join prompt is checked separately with the synthetic tailnet hub in `apps/ios/verification/home-tailnet`.

### Conversation proposal and file cards

`proposal-cards` uses Debug-only synthetic transcript scenes for Role creation,
updates, owner-only actions, saved/dismissed receipts, schedule creation/Open,
schedule edit proposals (current/proposed values, prompt diff, Apply, stale,
deleted and owner-only states), system notices (fork origin, resumed history,
agent warning, worktree script, a hidden unknown notice), failed and pending
decisions, and agent-shared PDF/Markdown files. The runner
captures light/dark appearances and exercises the fixture's decision transitions
through production card controls. It does not verify cloud persistence or file downloads.

```sh
pnpm verify:ui --case proposal-cards --require-video --app /absolute/path/to/Lody.app
```

### Conversation usage

`session-preview-usage` renders the production conversation with a synthetic 42%
context ring beside Send. `session-preview-usage-popup` opens its native usage
popover (84K / 200K, weekly and five-hour meters). The fixture clock is fixed;
reset-time arrows independently toggle relative and concrete dates. These Debug
scenes are reachable with `lody:///debug?verifyCase=<scene>` under `--ui-verify`.
When AXe is unavailable, launch with `--ui-verify --ui-review-usage` or
`--ui-verify --ui-review-usage-popup` using `simctl launch`; these bypass the
Simulator's external-URL confirmation, not product navigation. Native `message-details` checks
context normalization/window ordering/reset mode; `remote-settings` checks exact
account, model and capability quota selection. Neither scene performs cloud I/O.
