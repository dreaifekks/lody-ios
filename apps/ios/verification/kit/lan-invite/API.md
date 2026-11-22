# Native LAN P0 integration API

All account/UI state is `@MainActor`. Credentials stay native; do not put
`LanInvite` or GitHub tokens in UI JSON, SQLite, App Group snapshots or WebView arguments.

```swift
public struct LanHubSummary: Codable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let url: String
  public let workspaceId: String
  public let userId: String
}

// Existing AuthAccount / AuthSession / DataRuntime types gain:
AuthAccount.lan: LanHubSummary?
AuthAccount.isLAN: Bool
AuthSession.isLAN: Bool
DataRuntime.isLAN: Bool

// AuthSession:
public func joinLAN(_ inviteString: String) async throws
// Throws on malformed/rejected/unreachable/cancelled joins. A verified identity
// replacement is serialized to completion; failed probes retain the current account.

// Native-only access:
LanHub.current() throws -> LanInvite?
LanHub.read() throws -> LanInvite?
LanHub.credential(for workspace: String) -> LanInvite?
LanHub.summary(_ invite: LanInvite) -> LanHubSummary
LanHub.probe(_ invite: LanInvite) async throws
LanHub.githubToken(_ invite: LanInvite) async throws -> String?
LanHub.request(_ invite: LanInvite, path: String, method: String = "GET",
               body: Data? = nil, timeout: TimeInterval = 15) async throws -> (Data, HTTPURLResponse)
// Request injects bearer, refuses redirects and foreign origins; caller handles HTTP statuses.

// LodyHost requirement: await LAN deregistration before returning.
func forgetDevice() async

Notification.Name.lodyLANHubDidMove
// Notification.object is LanHubSummary. iOS owns LAN push re-registration.
```

`LanInvite` exposes `url`, `token`, `name`, mutable `term`, `id`, `workspaceId`,
`userId`, `displayName`; `parse(_:) throws` and
`init(url: String, token: String, name: String?, term: Int? = nil)` retain fork semantics.
Keychain service remains `app.innei.lody.auth`, with accounts
`better-auth-session` and `lan-hub`; there is no desktop credential migration.

F06 uses the protocol task's generated calls from commit `a645ef89`:

- `Calls.ConfirmSessionCreation`: `{workspaceId, sessionId}` →
  `{state: seen | pending | absent | not_ready}`.
- `Calls.ConfirmSessionTurn`: `{sessionId, id}` →
  `{state: seen | pending | absent | not_ready, delivery?: uploaded | queued, retryId?: String}`.

`DataRuntime.confirmSessionCreation(_ payload: String, sink: ReplySink)` and
`confirmSessionTurn(_ payload: String, sink: ReplySink)` wire these into
`OutboxServices.confirmSessionCreation` / `.confirmSessionTurn` optional async JSON
closures. Production OutboxSession supplies both. `seen` creation resumes its
first waiting turn; `seen` turn settles delivery; `absent` fails with a new turn
ID. Unknown writes are never automatically resent. The protocol task owns
appendOnce, fresh reads and durable pointer completion.

Root source-check/verification scripts were intentionally not edited. SPM discovers
new package sources automatically; the main session must run the offline runner
above explicitly or wire it into its authorized verification entrypoint.
