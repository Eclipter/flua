# Remaining work

Current capabilities and limitations are listed in [FEATURES.md](FEATURES.md). This plan contains only unresolved implementation and validation work. Remove completed tasks instead of keeping checked entries; record verified capabilities and evidence in FEATURES.md and the relevant documentation. Community features, profiles, network services and third-party runtime dependencies are outside its scope.

## Real-system validation

Use disposable libraries and matching catalog builds. Follow the [integration and rollback procedure](DEVELOPMENT.md#lock-screen-integration-checks); standalone tests and application smoke do not establish system playback behavior.

- Verify native fullscreen entry/exit on the affected displays, including pause and resume with Flua closed.
- Verify native playback through VoiceOver by activating playback controls and Set Wallpapers with a disposable matching-catalog build and rollback procedure.
- Verify independent and linked Desktop/Lock Screen choices, modes, Stop, restart and disconnect/reconnect with multiple physical displays. Include automatic Desktop assignment routing and restoration.
- Verify sleep/wake, visible provider output across display scaling modes, and HDR output on suitable hardware. The recorded display-mode switch does not establish rendering correctness.
- Verify recovery after revoking a live sandbox token. A separate voluntary lease-release check denied a fresh file open and explicit Apply reacquired scoped playback; it does not revoke a still-active host-issued grant. Automatic provider relaunch was not observed during a 90-second provider-crash check with WallpaperAgent alive. See the [recorded scope](../Sources/WallpaperExtension/README.md#provider-termination-and-released-access-lease); live token revocation and automatic recovery remain unestablished.

Update capability claims only after the relevant checks pass. Keep untested OS versions and hardware explicitly unverified.

## Audit follow-ups

The numbers below match the repository audit findings. Each fix needs a focused regression check; these entries describe pending work, not completed capabilities.

### Must fix

4. **Apply automatic playlist changes only to displays that advanced.** A stopped, selected display must stay stopped when another display advances. Cover target selection deterministically and verify behavior on multiple physical displays. See `Sources/Flua/Library.swift`.
5. **Honor the selected surface in playlist controls.** Start and manually advance the selected Desktop or Lock Screen playlist. Automatically advance independent surfaces and process linked surfaces once. Test that the other surface is preserved. See `Sources/Flua/Library.swift`.

### Should fix

9. **Make all intended smoke checks affect the suite result.** Add `desktopPlaylistPreservesLockScreen`, `desktopStopPreservesLockScreen` and `surfaceAssignmentsPersisted` to the required checks. Verify a false result causes failure. See `Sources/Flua/SmokeRunner.swift`.
10. **Remove the unused on-disk still cache.** Delete its helpers, directory creation and cache-only checks without changing provider-owned Still playback. Update the architecture description and retain useful still-frame and mode tests. Approximately 45 lines can be removed; no dependency change is needed. See `Sources/Flua/Model.swift`, its tests and `Sources/Flua/SmokeRunner.swift`.
