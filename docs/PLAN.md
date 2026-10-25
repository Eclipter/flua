# Remaining work

Current capabilities and limitations are listed in [FEATURES.md](FEATURES.md). This plan contains only unresolved implementation and validation work. Remove completed tasks instead of keeping checked entries; record verified capabilities and evidence in FEATURES.md and the relevant documentation. Community features, profiles, network services and third-party runtime dependencies are outside its scope.

## Real-system validation

Use disposable libraries and matching catalog builds. Follow the [integration and rollback procedure](DEVELOPMENT.md#lock-screen-integration-checks); standalone tests and application smoke do not establish system playback behavior.

- Currently blocked: verify native fullscreen entry/exit pause and resume on multiple physical displays. A second physical display is unavailable; current evidence covers only the built-in display on one Mac.
- Currently blocked: verify independent and linked Desktop/Lock Screen choices, modes, Stop, restart and disconnect/reconnect with multiple physical displays. A second physical display is unavailable. Include automatic playlist advancement while another selected display remains stopped, Desktop assignment routing and restoration.
- Currently blocked: verify sleep/wake provider recovery. Active `PreventUserIdleSystemSleep` assertions from runningboardd, sharingd, powerd and ChatGPT prevented a safe sleep transition during the 2026-10-25 check; no power policy was changed. Visible provider output across two built-in Retina scaling modes passed; see the [recorded display results](../Sources/WallpaperExtension/README.md#retina-scaling-and-sleepwake-check).
- Currently blocked: verify HDR output on suitable hardware. A dedicated HDR display is unavailable; the built-in display's limited HDR capability is insufficient for full HDR validation.

Update capability claims only after the relevant checks pass. Keep untested OS versions and hardware explicitly unverified.

## Correctness and safe verification

- **Medium:** Preserve native playback intent and report failure when [Library.stop](../Sources/Flua/Library.swift) cannot call the system stop operation because the provider is unavailable or the catalog mismatches. Cover both cases and keep isolated-verification behavior safe.
- **Medium:** Include `--preview-smoke` in [AppContext verification isolation](../Sources/Flua/App.swift). Add regressions for missing and overlapping `--data-dir` arguments before library access, and ensure verification disables native operations.
- **Medium:** Replace the duplicate `FocusClearView` and picker implementation in [FocusTests.swift](../Tests/FluaTests/FocusTests.swift) with coverage of production code, so production regressions cannot pass because the test compiles only its own copy.

## Performance and provider behavior

- **Medium:** Avoid full catalog serialization for unchanged or favorite-only saves, and move expensive changed-catalog serialization off the UI thread with serialized writes. A synthetic 1,000-entry catalog containing a real Flua thumbnail measured 54.6 MB; repeated release-optimized saves took 143–151 ms. Verify unchanged catalog contents for favorite-only edits and responsiveness at a representative large size. See [Library.save](../Sources/Flua/Library.swift) and [LibraryDisk.saveCatalog](../Sources/Flua/Model.swift).
- **Low:** In [Provider.m](../Sources/WallpaperExtension/Provider.m), query fullscreen Spaces only when at least one applicable Desktop session enables fullscreen pause. Avoid unnecessary polling for static content, preserve enabled-rule responsiveness, and verify monitoring behavior deterministically; the current policy timer polls at 30 Hz.

## Tooling and concurrency

- **Low:** Mark UI ownership explicitly with `@MainActor` and define worker boundaries in [Library.swift](../Sources/Flua/Library.swift) and related code. Make opt-in strict concurrency checking clean on the supported toolchain; the audit build passed with 99 warnings, including 52 in `Library.swift`.
