# Remaining implementation plan

This plan tracks the remaining native wallpaper work and outstanding validation. Current support is listed in `FEATURES.md`. Community features, profiles, network services and third-party runtime dependencies are outside its scope.

The native-provider playback and file-access feasibility gate has passed on the tested OS. Step 2 is implemented in the library model. The app build connects the library catalog and explicit setup to System Settings. Native assignments still belong to macOS rather than the app’s saved surface model; the remaining real-system scenarios in steps 1 and 6 still need validation.

## 1. Prove the native provider works with the real system host

**Status:** core feasibility accepted on arm64 macOS 27.0.1 (26A434). The bootstrap fix and boxed download-status reply allow real system selection. WallpaperAgent created desktop and preview contexts, delivered snapshots and played bundled and externally supplied video through multiple loops. A sandboxed probe could not read the external fixture before the host supplied a file wrapper; image/video sessions then held an active scope. Real lock/unlock updates were observed, and the user confirmed visible motion on the Lock Screen. Playback continued with the disposable containing application exited. Removal and restoration to a readable baseline were verified. Actual idle/screen-saver transitions remain unverified. See the [observations and restore procedure](../Sources/WallpaperExtension/README.md#real-host-feasibility-result).

1. Use the existing image/video fixtures in `Sources/WallpaperExtension/` to establish the required signing, entitlements, registration and sandbox access. **Done for the tested OS.**
2. Verify that System Settings displays the provider, accepts a selection and requests rendered frames from it. **Done for the test fixtures.**
3. Verify actual desktop, locked and idle presentation, including continued playback after the test application exits. **Partial:** host rendering, visible Lock Screen motion, lock/unlock updates and containing-app exit are verified; actual idle/screen-saver transitions remain unverified.
4. Record the exact OS versions tested, host restrictions, failure logs and a repeatable removal/restore procedure in the experimental documentation. **Done for the checks performed.**

**Acceptance:** real host playback and file access are demonstrated, or a concrete blocker is documented before building the production bridge. Standalone XPC tests alone do not pass this step. Keep the main application's macOS 15 minimum and gate native support to verified OS versions.

Repeat `make wallpaper-test` after provider changes before running host checks. Temporary registration, selection and activation are authorized as reversible integration checks when implementing this plan. Use disposable fixtures, record the affected system settings and establish rollback before changing them, then restore the previous settings and registration state on completion or failure. Ask before irreversible changes or when reliable restoration cannot be established. Standalone tests alone do not establish real-host acceptance.

## 2. Model desktop and Lock Screen assignments separately

**Status:** done in the library model. Deterministic tests and the isolated smoke run pass. The desktop app applies and restores only the desktop surface. A stored desktop Still mode is rendered as a retained frame. The saved Lock Screen assignment is not applied by the app. The app directly applies a selected video or scene to all displays and Spaces; it does not consume the saved per-display Lock Screen/link model.

1. Extend `DisplayAssignment` with per-surface selection and persistent Animated/Still mode, plus a linked/independent setting. Keep this separate from the existing Mirrored/Per Display setting. **Done.**
2. Decode old assignments into the desktop surface with their playlist index, history and timing intact. Leave the Lock Screen unmanaged until the user assigns it or enables linking. **Done.**
3. Define linking to copy the desktop selection and mode to the Lock Screen and follow subsequent desktop changes. Unlinking preserves the current values for independent editing. **Done.** A change made for either linked surface updates both.
4. Update assignment changes, mirrored synchronization, playlist advancement, removal, stopping and restoration to respect the selected surface and link state. **Done.** Mirrored mode copies the whole desktop/Lock Screen pair, including modes and link state. Desktop apply, playlist advancement and stop leave an unlinked Lock Screen choice in place.
5. Keep assignments keyed by stable display UUIDs, retaining disconnected displays' saved choices for reconnection. **Done.**

**Acceptance:** deterministic tests cover legacy decoding, link/unlink, independent modes, mirrored displays, playlist advancement, removed content and persistence. **Met** by `make test` and the assignment checks in `make smoke`. Physical multi-display behavior remains unverified.

## 3. Implement Animated and Still rendering for each surface

1. Extend `Engine.swift` so Still is a persistent rendering choice rather than the temporary global pause state. **Done** for the desktop surface.
2. Generate and retain still assets for videos and procedural scenes. Use the chosen video thumbnail frame, respecting valid trim bounds; images remain still in either mode. **Done.** Files are written under `Stills/` and the source file is left unchanged.
3. Extend the provider configuration and renderer to honor per-surface modes and supported trim, speed, fit and dimming settings. **Done.** Catalog rows carry speed, dimming, fit, a valid video trim, the still-frame time, and one desktop mode and one Lock Screen mode. Conflicting per-display modes publish Animated. The renderer applies that configuration; idle presentation uses the Lock Screen mode. Suspension and resume leave the saved mode unchanged, and the source file is not modified.
4. Provide native animated output or locally prepared loop assets for the four built-in scenes before exposing them as animated native choices. **Done.** The provider draws aurora, cosmos, ocean and ember into the session surface, so no loop file is required. `catalog.json` lists an unblocked scene with an empty file path, its speed and dimming, and still time 7 (the desktop thumbnail). A video badge exposes that row as an animated choice. Suspension and resume leave the saved mode unchanged. The app applies these rows directly from Flua and also publishes them to System Settings; real-system results are recorded in the provider documentation.
5. Keep temporary suspension, resume and lock/idle transitions separate from the saved mode. Avoid desktop-overlay and system-provider playback competing for the same desktop. **Partial:** pause and resume leave the saved desktop mode unchanged. Direct native apply uses a still underlying desktop to avoid competing native animation beneath overlays. Sleep and actual idle transitions remain unverified.

**Acceptance:** deterministic configuration checks and runtime tests show that surface modes survive restart, suspension and resume without altering source media.

## 4. Connect the library to the provider and System Settings

1. Publish a small versioned local catalog containing stable IDs, configuration, thumbnails and references to durable library-owned assets. Write it atomically instead of exposing partially saved application state. **Done.** `catalog.json` is written beside `library.json`. It lists image and video files under `Media/`, and the four built-in scenes with no media file. It omits other kinds, blocked tags and unsafe filenames. Video rows and scene rows still use the prototype thumbnail.
2. Give the provider the read access proven in step 1. **Done for the app build.** The sandbox reads only `catalog.json` through a file-specific exception. Media stays on host wrappers. `FLUA_CATALOG_PATH` binds disposable integration builds to an isolated library; setup rejects a mismatched library. Existing catalog version, ID and containment validation remains in place.
3. Populate the desktop and screen-saver catalogs from eligible library entries. **Done for native library discovery and refresh on the tested OS.** The native build hides prototype fixtures, lists library image/video and scene rows, and respects blocked tags. A real library-video choice acquired scoped files and looped in WallpaperAgent. Atomic catalog replacement updated the selected title in System Settings. A cached-choice acquire also starts catalog refresh when the host does not request settings again. Reapply a choice from Flua after playback-setting edits to update its active configuration.
4. Resolve per-display desktop/Lock Screen choices and host idle requests without adding a third independent assignment surface unless required by the host. **Partial:** direct apply updates every current system display/Space assignment to the selected item, with a still desktop and animated Lock Screen. Saved independent native choices, linking controls and physical multi-display validation remain outstanding.
5. Keep selected assets and configurations available after Flua exits. Handle missing media, stale choices and incompatible catalog data with a usable still fallback or a recoverable error.

**Acceptance:** a real library import appears in System Settings, renders through the sandboxed provider and keeps playing after Flua quits. **Met for the tested native library video on macOS 27.0.1.** The user confirmed motion during a real lock/unlock with Flua closed. The provider logged continued frames and loops, and an atomic catalog replacement updated the selected title in System Settings. Per-display native resolution and recovery remain outstanding.

## 5. Add setup, recovery and surface controls

1. Add explicit provider status and setup/recovery actions, including clear unavailable states on unsupported systems. **Done for direct apply/retry.** `make build` embeds a sandboxed extension, exposes Apply in the inspector and Settings, verifies registration and writes the choice through a guarded, backed-up WallpaperAgent store transaction. A newly imported video passed the app-button and real-host scoped-access checks; the user confirmed locked motion with the direct method. Other OS versions show an unavailable explanation. Automatic crash/access recovery remains outstanding.
2. Add Desktop/Lock Screen targeting, link/unlink and Animated/Still controls in the inspector. Show each surface's effective assignment and mode.
3. Route apply, stop, edits and restoration through the appropriate desktop engine or native-provider path. **Partial:** native Apply uses the selected item directly, independent of the Settings catalog cache. Desktop playback remains available when native setup is unavailable. Native stop, automatic reapply after edits and saved-assignment restoration remain outstanding.
4. Recover from provider crashes, lost media access, stale catalogs and display reconnection without silently replacing saved selections.
5. Make setup retryable and removal reversible. **Partial:** setup/retry and quit-behavior text are implemented; switching to another system wallpaper stops native playback, and exact-path unregistration is documented. A dedicated removal UI remains outstanding.

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

- [x] Verify keyboard-only access to library filters, clickable tags, clear/reset and blocked-tag controls, including empty results. Checked on macOS 27.0.1 (26A434) with Keyboard navigation enabled and disposable libraries. Inspector tags stay in the focus order and scroll into view; search reset is labeled Clear search. VoiceOver was turned on; its caption read the sidebar group PLAYLISTS, and the renamed browsing controls were not reached. `make smoke` passed on macOS 27.0.1, including the offscreen check of the names VoiceOver reads for those controls. See the [repeatable keyboard check](DEVELOPMENT.md#keyboard-verification).

- Run `make test` after model, persistence, metadata and package-validation changes. Add focused standalone Swift tests under `Tests/FluaTests/` through `scripts/test.sh`.
- Run `make build`, then `make smoke`, after UI, rendering, playback and import/export changes. Extend `SmokeRunner.swift` only for behavior an isolated run can actually establish.
- Run `make wallpaper-test` after provider changes, followed by the reversible real-host checks required above, preserving and restoring the previous system state.
- Use fresh disposable `--data-dir` directories for application verification. Do not edit generated build output or use the developer's real application-support data.
