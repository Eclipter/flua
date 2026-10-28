# Remaining work

Current capabilities and limitations are listed in [FEATURES.md](FEATURES.md). This plan contains only unresolved implementation and validation work. Remove completed tasks instead of keeping checked entries; record verified capabilities and evidence in FEATURES.md and the relevant documentation. The live online wallpaper catalog is the sole network feature; other network services, community features, profiles and third-party runtime dependencies remain out of scope.

## Audit follow-ups (2026-10-28)

Keep the audit numbers below when referring to these tasks. Native coordination reproductions used a stubbed OS boundary; they do not establish real-system behavior.

4. **P2 — Verify native restoration after removal.** Verify OS restoration separately with disposable fixtures. Blocked on the current host: the prior Flua wallpaper provider ran from a deleted build path and has since exited; reliable restoration of that playback has not been established.
5. **P2 — Verify native edit refresh after Quit.** Separately verify saved trim and cover settings in real native playback after Quit, using a disposable matching-catalog build and a reliably restorable system baseline. Blocked on the current host: the prior Flua wallpaper provider ran from a deleted build path and has since exited; reliable restoration of that playback has not been established.

## Real-system validation

Use disposable libraries and matching catalog builds. Follow the [integration and rollback procedure](DEVELOPMENT.md#lock-screen-integration-checks); standalone tests and application smoke do not establish system playback behavior.

- Currently blocked: verify native fullscreen entry/exit pause and resume on multiple physical displays. A second physical display is unavailable; current evidence covers only the built-in display on one Mac.
- Currently blocked: verify independent and linked Desktop/Lock Screen choices, modes, Stop, restart and disconnect/reconnect with multiple physical displays. A second physical display is unavailable. Include automatic playlist advancement while another selected display remains stopped, Desktop assignment routing and restoration.
- Currently blocked: verify sleep/wake provider recovery. Active `PreventUserIdleSystemSleep` assertions from runningboardd, sharingd, powerd and ChatGPT prevented a safe sleep transition during the 2026-10-25 check; no power policy was changed. Visible provider output across two built-in Retina scaling modes passed; see the [recorded display results](../Sources/WallpaperExtension/README.md#retina-scaling-and-sleepwake-check).
- Currently blocked: verify HDR output on suitable hardware. A dedicated HDR display is unavailable; the built-in display's limited HDR capability is insufficient for full HDR validation.

Update capability claims only after the relevant checks pass. Keep untested OS versions and hardware explicitly unverified.
