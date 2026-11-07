# Loopback LAN runtime verification

The caller starts an isolated Streams hub and prepares its `lody` bucket. This
script never launches `loro dev`, reads account credentials, or addresses a real
machine. It creates UUID-scoped synthetic streams with a 900-second TTL and
uses only the fixed synthetic token `loopback`.

Run from the checkout (Node 22.13+ and the checkout's dependencies):

```sh
unset FORCE_COLOR
TZ=UTC NO_COLOR=1 LODY_HUB_URL=http://127.0.0.1:18799 LODY_HUB_TOKEN=loopback \
  node --experimental-strip-types verification/lan-hub/reconnect.mjs
```

Only `http(s)://127.0.0.1`, `http(s)://localhost`, or `http(s)://[::1]`, with an
optional port, are accepted. Credentials, other hosts, URL paths, queries,
fragments, and non-synthetic `LODY_HUB_TOKEN` values fail before the first seed
write. All fetches remain on that origin and reject redirects.

The main session may add this package script; this task does not change the
root package:

```json
"verify:lan-hub": "node --experimental-strip-types verification/lan-hub/reconnect.mjs"
```

The scenarios retain the old fork's send/reconnect behavior through the new
versioned channel: ordinary send, a lost append ACK with producer deduplication,
a dropped socket, an unreachable route before writing, reset of a stalled
append followed by authoritative absence and a new retry ID, an uncommitted
pointer repaired after another client marks the turn seen, and a committed
pointer whose ACKs were lost. Catalog polling preserves its cursor through a
dropped read without exceeding STALL_GRACE; synthetic machine ping verifies
latency and a silent peer's timeout without inventing heartbeat presence.

`confirmSessionTurn` uses the typed `seen/pending/absent/not_ready` result and
`delivery/retryId` fields. Neither confirmation nor the verifier replays the old
turn or dispatch RPC.

The runtime bundle runs in an owned Worker with the production embedded-WASM
mapping. Every exit path cancels owned fetches and the synthetic RPC responder,
clears timer/fault resources, restores the Worker fetch implementation, and
awaits Worker termination. A five-minute run deadline bounds unattended runs;
each typed request has its own deadline. Failures exit nonzero without an
unconditional `process.exit`.

Offline checks require no hub and do not write streams:

```sh
unset FORCE_COLOR
TZ=UTC NO_COLOR=1 node --experimental-strip-types --experimental-test-module-mocks \
  --test tests/cloud/lan-hub-verification.test.mjs
```

A passing offline check establishes address fencing, fault injection, typed
bundle loading, and teardown. It does not establish that the real Streams
integration scenarios passed; the main session runs those against its prepared
loopback hub.
