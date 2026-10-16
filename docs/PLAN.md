# Remaining implementation plan

This plan tracks the remaining native wallpaper work and outstanding validation. Current support is listed in `FEATURES.md`. Community features, profiles, network services and third-party runtime dependencies are outside its scope.

The native-provider playback and file-access feasibility gate has passed on the tested OS. Step 2 is implemented in the library model. Steps 3–5 can proceed; the remaining real-system scenarios in steps 1 and 6 still need validation.

## 1. Prove the native provider works with the real system host

**Status:** core feasibility accepted on arm64 macOS 27.0.1 (26A434). The bootstrap fix and boxed download-status reply allow real system selection. WallpaperAgent created desktop and preview contexts, delivered snapshots and played bundled and externally supplied video through multiple loops. A sandboxed probe could not read the external fixture before the host supplied a file wrapper; image/video sessions then held an active scope. Real lock/unlock updates were observed, and the user confirmed visible motion on the Lock Screen. Playback continued with the disposable containing application exited. Removal and restoration to a readable baseline were verified. Actual idle/screen-saver transitions remain unverified. See the [observations and restore procedure](../experimental/WallpaperExtension/README.md#real-host-feasibility-result).

1. Use the existing image/video fixtures in `experimental/WallpaperExtension/` to establish the required signing, entitlements, registration and sandbox access. **Done for the tested OS.**
2. Verify that System Settings displays the provider, accepts a selection and requests rendered frames from it. **Done for the test fixtures.**
3. Verify actual desktop, locked and idle presentation, including continued playback after the test application exits. **Partial:** host rendering, visible Lock Screen motion, lock/unlock updates and containing-app exit are verified; actual idle/screen-saver transitions remain unverified.
4. Record the exact OS versions tested, host restrictions, failure logs and a repeatable removal/restore procedure in the experimental documentation. **Done for the checks performed.**

**Acceptance:** real host playback and file access are demonstrated, or a concrete blocker is documented before building the production bridge. Standalone XPC tests alone do not pass this step. Keep the main application's macOS 15 minimum and gate native support to verified OS versions.

Repeat `make native-test` after provider changes before running host checks. Temporary registration, selection and activation are authorized as reversible integration checks when implementing this plan. Use disposable fixtures, record the affected system settings and establish rollback before changing them, then restore the previous settings and registration state on completion or failure. Ask before irreversible changes or when reliable restoration cannot be established. Standalone tests alone do not establish real-host acceptance.

## 2. Model desktop and Lock Screen assignments separately

**Status:** done in the library model. Deterministic tests and the isolated smoke run pass. The desktop app still applies and restores only the desktop surface; Animated/Still is stored but not used by rendering, and there is no setup UI.

1. Extend `DisplayAssignment` with per-surface selection and persistent Animated/Still mode, plus a linked/independent setting. Keep this separate from the existing Mirrored/Per Display setting. **Done.**
2. Decode old assignments into the desktop surface with their playlist index, history and timing intact. Leave the Lock Screen unmanaged until the user assigns it or enables linking. **Done.**
3. Define linking to copy the desktop selection and mode to the Lock Screen and follow subsequent desktop changes. Unlinking preserves the current values for independent editing. **Done.** A change made for either linked surface updates both.
4. Update assignment changes, mirrored synchronization, playlist advancement, removal, stopping and restoration to respect the selected surface and link state. **Done.** Mirrored mode copies the whole desktop/Lock Screen pair, including modes and link state. Desktop apply, playlist advancement and stop leave an unlinked Lock Screen choice in place.
5. Keep assignments keyed by stable display UUIDs, retaining disconnected displays' saved choices for reconnection. **Done.**

**Acceptance:** deterministic tests cover legacy decoding, link/unlink, independent modes, mirrored displays, playlist advancement, removed content and persistence. **Met** by `make test` and the assignment checks in `make smoke`. Physical multi-display behavior remains unverified.

## 3. Implement Animated and Still rendering for each surface

1. Extend `Engine.swift` so Still is a persistent rendering choice rather than the temporary global pause state.
2. Generate and retain still assets for videos and procedural scenes. Use the chosen video thumbnail frame, respecting valid trim bounds; images remain still in either mode.
3. Extend the provider configuration and renderer to honor per-surface modes and supported trim, speed, fit and dimming settings.
4. Provide native animated output or locally prepared loop assets for the four built-in scenes before exposing them as animated native choices.
5. Keep temporary suspension, resume and lock/idle transitions separate from the saved mode. Avoid desktop-overlay and system-provider playback competing for the same desktop.

**Acceptance:** deterministic configuration checks and runtime tests show that surface modes survive restart, suspension and resume without altering source media.

## 4. Connect the library to the provider and System Settings

1. Publish a small versioned local catalog containing stable IDs, configuration, thumbnails and references to durable library-owned assets. Write it atomically instead of exposing partially saved application state.
2. Give the provider the read access proven in step 1. Validate catalog versions, IDs and asset containment, and obtain media access through the host's supported file-wrapper mechanism.
3. Populate the desktop and screen-saver catalogs from eligible library entries. Respect blocked tags and reflect imports, metadata edits and removals through host refresh callbacks.
4. Resolve per-display desktop/Lock Screen choices and host idle requests without adding a third independent assignment surface unless required by the host.
5. Keep selected assets and configurations available after Flua exits. Handle missing media, stale choices and incompatible catalog data with a usable still fallback or a recoverable error.

**Acceptance:** a real library import appears in System Settings, renders through the sandboxed provider and keeps playing after Flua quits. Catalog refresh and app-exit behavior must be observed through the real host.

## 5. Add setup, recovery and surface controls

1. Add explicit provider status and setup/recovery actions, including clear unavailable states on unsupported systems. Keep the prototype and optional native build separate from the default desktop build.
2. Add Desktop/Lock Screen targeting, link/unlink and Animated/Still controls in the inspector. Show each surface's effective assignment and mode.
3. Route apply, stop, edits and restoration through the appropriate desktop engine or native-provider path. Keep current desktop playback available when native setup is unavailable.
4. Recover from provider crashes, lost media access, stale catalogs and display reconnection without silently replacing saved selections.
5. Make setup retryable and removal reversible. Update quit-behavior text to distinguish app-owned overlays from system-owned playback.

**Acceptance:** isolated smoke tests cover UI/state changes and failure handling; reversible host tests within the task cover setup, recovery and removal. No login item registration is needed for playback owned by the system host.

## 6. Verify complete workflows and update capability claims

1. Test linked and independent selections/modes across actual displays, including disconnect/reconnect and application restart.
2. Test real desktop → lock → unlock and active → idle/screen saver → active transitions, including Still mode and Flua exiting during playback.
3. Verify sleep/wake, display scaling/Retina and HDR behavior on relevant hardware before claiming support. Record untested OS versions and setups explicitly.
4. Verify setup failure, provider termination, missing files and recovery using disposable libraries. Keep the developer's normal library untouched.
5. Update `docs/FEATURES.md` as each capability passes its acceptance checks; update `docs/ARCHITECTURE.md` when the provider boundary changes, and `README.md` / `docs/DEVELOPMENT.md` when workflows change.
6. If native release packaging changes, run `make release` and inspect the archive under `dist/`. Keep signing/notarization and distribution claims aligned with what was actually performed.

**Acceptance:** every planned capability has a recorded passing check or remains explicitly marked experimental/unverified. Standalone tests and overlay smoke tests cannot substitute for real system transition tests.

## Validation throughout implementation

- Verify keyboard-only access to library filters, clickable tags, clear/reset and blocked-tag controls, including empty results.

- Run `make test` after model, persistence, metadata and package-validation changes. Add focused standalone Swift tests under `Tests/FluaTests/` through `scripts/test.sh`.
- Run `make build`, then `make smoke`, after UI, rendering, playback and import/export changes. Extend `SmokeRunner.swift` only for behavior an isolated run can actually establish.
- Run `make native-test` after provider changes, followed by the reversible real-host checks required above, preserving and restoring the previous system state.
- Use fresh disposable `--data-dir` directories for application verification. Do not edit generated build output or use the developer's real application-support data.
