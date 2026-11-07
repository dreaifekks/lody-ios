# LAN terminal

`node --experimental-strip-types --test verification/kit/lan-terminal/static.test.mjs`
is the dependency-free static / catalog projection check. It neither compiles Swift
nor opens a listener. This is the only executed terminal check in round 2 P1a.

`main.swift` ports df8d9343's real Network.framework TLS 1.2 PSK loopback member.
It checks the key vector, UTF-8/newline framing and size ceiling, event/command
schema, hello identity, open, attach replay, list, resize, input, close, delayed
open cleanup, refusal, wrong key/machine and unreachable address. It binds only
127.0.0.1. It must never target a real hub or member.

Pending registration in `verification/native.py`:

- case `lan-terminal`
- source inputs `LAN/LanMemberProtocol.swift`, `LAN/LanTerminalLink.swift`,
  `Sessions/SessionCatalog.swift`
- host macOS Network / CryptoKit; `verification/kit/lan-terminal/main.swift`
- native checks that already compile `Sessions/SessionCatalog.swift` also need
  `LAN/LanMemberProtocol.swift` (session-rows and project-index).

The owner integrates this into the existing caller-managed native batch. No
standalone build/lock/server launch is performed in this task.

## Review follow-up (B1 / S1 / S2)

The loopback member now retains PTYs when its socket drops, as the desktop does.
The source checks reconnect list/adopt/attach with the same ID and no extra open,
scoped cancel after adoption, dead-link cleanup that preserves a desktop-owned
shell, and bounded exit from stopping with an unanswered open. Failed cleanup
also terminates. These Swift sources were not compiled or run in this task.

`LanTerminalLink` adds `adopt(terminalId:)`, `disconnect()`, `onOwnedTerminal`,
`cancel(completion:)` (true only for confirmed absence/exit), and static bounded
`cleanup(endpoint:lanId:key:machineId:sessionId:terminalId:completion:)`.
Cleanup never opens/attaches/closes a whole session. The injected UIKit Factory
now takes `TerminalShellOwnership` as its first argument; channels implement
`adopt` and `disconnect` as well as `stop`. Existing runner/source registration
is unchanged. An additional `terminal-preview-unknown` Debug scene is entered
from the existing UI script, without a new runner case.

An open with no returned ID cannot be identified safely from a list. The page
shows an explicit unknown-outcome notice and blocks another open in that page;
the native link waits at most one further request timeout for a late answer.
After that deadline, remote cleanup requires the member's terminal list/manual
action or a future protocol that correlates request IDs with created shells.
No terminal ID is guessed and no desktop-owned terminal is reclaimed.
