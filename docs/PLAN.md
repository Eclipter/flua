# Remaining work

Current capabilities and limitations are listed in [FEATURES.md](FEATURES.md). This plan contains only unresolved implementation and validation work. Remove completed tasks instead of keeping checked entries; record verified capabilities and evidence in FEATURES.md and the relevant documentation. The live online wallpaper catalog is the sole network feature; other network services, community features, profiles and third-party runtime dependencies remain out of scope.

## Audit follow-ups (2026-10-28)

Keep the audit numbers below when referring to these tasks. Native coordination reproductions used a stubbed OS boundary; they do not establish real-system behavior.

2. **P1 — Keep pending imports outside committed state.** A batch exposes records before its final save, allowing another save to commit them; a later import rollback can delete their already-committed media. Stage pending records privately until committing them and never delete media referenced by a successful commit. Test an intervening save followed by a failed final import save, then reload and verify every persisted media reference.
3. **P2 — Roll back failed removal and playlist saves.** These mutations ignore save failure, leaving memory and disk inconsistent; removal also continues thumbnail cleanup and native refresh scheduling. Restore the previous state on failure and perform follow-up actions only after a successful commit. Add failure tests covering wallpaper removal, playlist mutations, assignments, cleanup intent and reload consistency.
4. **P2 — Handle removal during the first native Apply.** Removal can run before Apply records active playback, so it queues no cleanup; Apply then marks a removed assignment active. Guard removal during native transactions or reconcile mutations before accepting their completion. Add a deterministic test with a delayed stubbed Apply, asserting that removal cannot leave active playback without a saved assignment or cleanup request; verify OS restoration separately with disposable fixtures.
5. **P2 — Verify native edit refresh after Quit.** Separately verify saved trim and cover settings in real native playback after Quit, using a disposable matching-catalog build and a reliably restorable system baseline. Blocked on the current host: the active Flua wallpaper provider runs from a deleted build path, so a host restart may prevent restoring its playback.

## Real-system validation

Use disposable libraries and matching catalog builds. Follow the [integration and rollback procedure](DEVELOPMENT.md#lock-screen-integration-checks); standalone tests and application smoke do not establish system playback behavior.

- Currently blocked: verify native fullscreen entry/exit pause and resume on multiple physical displays. A second physical display is unavailable; current evidence covers only the built-in display on one Mac.
- Currently blocked: verify independent and linked Desktop/Lock Screen choices, modes, Stop, restart and disconnect/reconnect with multiple physical displays. A second physical display is unavailable. Include automatic playlist advancement while another selected display remains stopped, Desktop assignment routing and restoration.
- Currently blocked: verify sleep/wake provider recovery. Active `PreventUserIdleSystemSleep` assertions from runningboardd, sharingd, powerd and ChatGPT prevented a safe sleep transition during the 2026-10-25 check; no power policy was changed. Visible provider output across two built-in Retina scaling modes passed; see the [recorded display results](../Sources/WallpaperExtension/README.md#retina-scaling-and-sleepwake-check).
- Currently blocked: verify HDR output on suitable hardware. A dedicated HDR display is unavailable; the built-in display's limited HDR capability is insufficient for full HDR validation.

Update capability claims only after the relevant checks pass. Keep untested OS versions and hardware explicitly unverified.
