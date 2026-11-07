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
