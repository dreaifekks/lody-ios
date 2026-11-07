# LAN files checks

Source-only port of the df8d9343 TLS-PSK member fixture. This task did not compile or run either Swift check and did not start a listener.

The main session should register:

- `lan-files`: sources `LAN/LanMemberProtocol.swift`, `LAN/LanMemberChannel.swift`, `LAN/LanFileChannel.swift`, main `verification/kit/lan-files/main.swift`. Host/macOS check. Covers files hello/service, capability and safe names, two transfers on one connection, read/digest verification, damaged/missing files, refusal, foreign machine, old member, wrong key and unreachable endpoint. The listener is constrained to loopback.
- `lan-files-cache`: source `LAN/LanImageCache.swift`, main override `verification/kit/lan-files/cache/main.swift`. Host/macOS check. The nested main needs an explicit override in `native.py`; no server. Covers canonical digest filename, in-flight joining, stable disk hits after runtime replacement / with an offline runtime, notification identity, retry, account switches and old epoch callbacks that ignore cancellation. Pending cleanup checks the task ID so an old completion cannot erase a replacement fetch.

`packages/LodyData/Tests/LanAttachmentTests.swift` adds package tests for the actual shared ImageIO helper, the upload limit before connection, and user/agent local file-to-image transcript rows. Run through the main session's normal package/native validation.

UI case `lan-files` uses `lan-files-preview` (ready ID `lan-files-status`), script `verification/ui/lan-files.py`, plus an independent deep-link reset to `lan-files-late`. Injected providers exercise production chat, composer, gallery, Quick Look and edit controller; no runtime, authentication, Cloud access or live member. The parent runner owns video recording and light/dark English runs. New-session form recovery remains with the form session; reuse its `create-lan`, create-parity and share-ingest coverage after integration.

The review fix adds `lan-files-recovery` to DebugSceneFactory. The existing `lan-files` UI script resets into it and scripts epoch replacement during gallery/Quick Look loads and edit preparation/send/confirmation. It checks explicit retry, automatic thumbnail refresh via didCache, warm offline cache reuse, text+file restoration, cancellation and one edit send (no replay). No extra runner case registration is needed beyond `lan-files`.

Stable identity API lives in LodyData's `LAN/AttachmentIdentity.swift`: `AttachmentIdentity.key(userId:workspaceId:lanId:)` and `AuthSession.attachmentIdentity(workspace:)`. The App-only `AttachmentUIIdentity.current` resolves the workspace from `SessionSource.live.state`; LodyData never imports UIKit or the App live extension. Runtime I/O still uses its original generation/owner fence. `LanImageCache.file` adds optional `epoch` and `isCurrent` arguments; neither contributes to the disk namespace or notification identity.
