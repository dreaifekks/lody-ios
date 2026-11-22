# Vendored Lody Status view modules

These files mirror `packages/shared/src` of the public Lody repository at the
commit on `main` in `provenance.json` (from LodyAI/Lody#3063; AGPL-3.0-only; the
fractional index is MIT, see its header). They are byte-for-byte upstream except
the relative import extensions listed per file under `adapt`; formatting is
upstream's, so Prettier ignores this directory.

- `status-view/` — `buildStatusViewLayout`, `planStatusViewCommand`, tiers, the
  opened-by tree and snooze presets, with the golden vectors in `vectors/`.
- `pinned-sections.ts`, `vendor/loro-fractional-index.ts` — what they import.

`apps/ios/tests/cloud/status-view.test.mjs` checks every file against its
recorded SHA-256 after undoing the adaptations, and runs both vector files
against these copies. To refresh: copy the same paths from the new upstream
commit, re-apply only the import extensions, and update `provenance.json`.
Never edit the logic here; change it upstream and re-vendor.
