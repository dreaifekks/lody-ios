# LAN P0 offline checks

From the checkout root, run `python3 verification/kit/lan-invite/check.py`.
This uses Swift 6 and the selected Xcode SDK, acquires the shared native-job
`mkdir` lock, and skips compilation above a one-minute load of 6. It does not
run xcodebuild, a simulator, system Keychain operations, network requests or a
real hub. The check is deliberately not wired into root scripts in this task.

Coverage:

- Lody invite encoding, IPv6, port normalization, IDs and probe HTTP status policy.
- Signed hub moves, term ordering and cached catalog member discovery (see `../lan-hub-follow`).
- Production AuthSession with isolated in-memory dependencies: cancellation,
  Cloud/LAN replacement, failed login preservation, LAN startup context and
  awaiting native device deregistration before deleting credentials.
- Production scheme forwarding policy: only owned `/ds/` URLs, no traversal.
- Production outbox store/dispatcher: owned inflight leases, retryable waiting
  wakeup, pending/absent confirmation, and no replay of unknown writes.

The app's actual WebKit streaming callbacks/reconnect, system Keychain,
TLS-PSK handshake with a real member, SwiftPM XCTest suite and full native build
remain integration checks for the main session. `LodyDataTests` also covers the
account projection, scheme policy, inflight ownership and stale unsubscribe.
The native confirm calls require the protocol task's generated
`ConfirmSessionCreation` / `ConfirmSessionTurn` contract before app compilation.
