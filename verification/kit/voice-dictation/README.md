# Native voice dictation

Run `pnpm verify:native --case voice-dictation` in the caller's managed simulator
lease. This compiles the production Swift lifecycle and settings projection. A
fake media peer and fake Machine RPC exercise start/poll/cursor/stop, accumulated
transcripts, late-start cleanup, failed polls, permission cancellation, decoded
Agent discovery, device selection and workspace-default restoration. No microphone,
account, hub, token or external voice service is used.

`pnpm verify:ui --case voice-dictation --app <Lody.app> --require-video` exercises
production shared composer instances from chat and new-session hosts plus the
production Preferences controller in English/light and English/dark. Debug's
media/RPC seam deliberately holds start until Connect, then supplies a transcript.
This proves controls and state transitions, not real microphone or WebRTC transport.
The signed app links the same WebRTC 154 binary as the old fork via SPM.
