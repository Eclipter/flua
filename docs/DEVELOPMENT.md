# Development

Requires macOS 15+, Apple Silicon and Apple Swift command-line tools (`xcode-select --install`). The wallpaper extension needs a macOS 26 SDK/runtime. There are no external Swift package dependencies.

```sh
make build          # Flua.app with the wallpaper extension, ad-hoc signature
make test           # model, library path, package security tests
make smoke          # isolated end-to-end app tests, then exits
make run            # open the app
make release        # dist/Flua-macOS.zip
make wallpaper-test # isolated wallpaper extension tests, no OS activation
```

`Package.swift` supports SwiftPM and opening the source package in Xcode. Use `make build` for a runnable `.app`; `swift build` alone only produces an executable. Model/package tests are standalone executables run by `make test`, not XCTest targets. Smoke tests launch a separate app instance through Launch Services, wait for it to exit, and write only to a fresh directory under `build/verification/`; they briefly create and remove a desktop overlay.

The build script updates the app bundle's modification time after signing so Launch Services can detect changed metadata and icon resources on subsequent launches.

The smoke launch suppresses automatic library-window creation to verify that the application opens it explicitly. Reopen checks send a process-targeted system reopen event after closing and minimizing the library while desktop playback continues.

The library hides the toolbar title and background using SwiftUI while retaining native window controls and the sidebar toggle. Smoke tests check the hidden window title and visible close/minimize/zoom buttons. Discover and Browse share one native vertical scroll view that extends through the title-bar safe area to the bottom of the window. The playback bar is an overlay inset from the native scrollbar; its measured height pads the scroll content rather than shrinking the viewport. Top padding protects the first content row without insetting the scrollbar. The inspector uses the same separation between viewport and content insets. Smoke checks compare both scroll-view and visible scrollbar bounds with the full window height in Discover and Browse, and verify the system’s preferred scroller style.

Inspector checks run in the actual library window with its unified toolbar. They verify mouse hit targets for Play Wallpaper and a playback slider, then send a mouse click to Play Wallpaper and check desktop playback for both a built-in scene and an imported video. The offscreen accessibility name audit alone does not cover this routing.

Settings → General stores menu bar visibility and Dock hiding in `library.json`. Missing keys keep the menu bar icon visible and the Dock icon shown. The transparent menu bar PNG lives in `Sources/Flua/Resources/MenuBarSakura.png`. SwiftPM packages it in `Flua_Flua.bundle`; the build script copies that bundle into the app's `Contents/Resources/` before signing. `MenuBarIcon.swift` loads it as an 18-point template image so macOS supplies the menu bar color. The library sidebar draws the same image at 22 points and tints it with the accent color. The prompt that produced it is `docs/MENU_BAR_ICON_PROMPT.md`.

## Layout

- `Sources/Flua/`: main application, rendering, persistence, media inspection, importer and editor.
- `Tests/FluaTests/`: deterministic model, library path and package validation tests.
- `Resources/`: bundle metadata and original application icon.
- `scripts/`: reproducible build, test and release entry points.
- `docs/`: architecture and feature status.
- `Sources/WallpaperExtension/`: wallpaper provider, compiled separately and embedded by `make build`.
- `.build/`, `build/`, `dist/`: ignored, generated artifacts.

## Changes and validation

Keep media and account information out of the repository. Test model/import changes with `make test`, and playback/UI/export changes with `make smoke`. Run `make wallpaper-test` when changing the provider protocol. Update [feature status](FEATURES.md) when support changes. Validation results belong in fresh generated output.

`make wallpaper-test` also verifies the boxed download-status reply over XPC. It does not register or select a wallpaper. Real-host playback and file-access checks use disposable containing apps, following the [provider verification and restoration procedure](../Sources/WallpaperExtension/README.md#playback-scoped-files-and-restoration). Keep their source copies, fixtures, local settings snapshots and logs outside Git.

The project is a local Git repository; commits and remotes are left to the developer. No CI service, signing account or deployment credentials are required. Release bundles are ad-hoc signed, not notarized.

## Lock Screen integration checks

`make build` creates `build/Flua.app`. The extension requires a macOS 26 or newer SDK; the setup UI is gated to macOS 27. The extension uses `local.flua.desktop.wallpaper`, a sandbox signature and a file-only read exception for `~/Library/Application Support/Flua/catalog.json`. Prototype fixtures are hidden. Apply registers the containing app and its extension, removes other copies of that identifier, selects this copy, and directly updates the user wallpaper store through a guarded transaction. The helper validates the current-user agent before pausing it; EOF, timeout or handled termination resumes it. A successful write restarts it. `NativeWallpaperStore` rejects unknown formats and resolves saved choices and modes for targeted displays and existing Spaces. Unassigned surfaces and untargeted overrides are preserved; Per Display moves the previous global choice into the default fallback before writing the global override as `$null`. A backup is retained in the library as `NativeWallpaperBackup.plist`. Playback-setting edits reuse the guarded transaction after a 0.5-second debounce, updating matching active choices while preserving modes. Deterministic descriptor tests do not access the user’s wallpaper store. Desktop and Lock Screen use their saved independent or linked selections and modes. Successful application removes overlays on targeted native desktops; Launch reapplies remembered active native assignments through the guarded Apply path; Pause and playlists remain separate. Stop restores both targeted native surfaces from `NativeWallpaperBaseline.plist` while retaining saved Flua choices. The baseline is captured before native Apply and retained across repeated applies and playback edits. If Flua is already selected and no baseline exists, Apply updates that choice in place. Stop without a usable baseline fails without writing the store; select another system wallpaper and apply once to establish a baseline. Native Stop skips automatic playlist advancement and reconnection restoration on those displays across launches until playback is explicitly started again.

For isolated integration checks, create a fresh library outside the normal application-support directory and build with its absolute catalog path:

```sh
FLUA_CATALOG_PATH=/absolute/path/to/disposable-library/catalog.json \
    FLUA_WALLPAPER_IDENTIFIER=local.flua.desktop.wallpaper.disposable-test \
    make build
open -g -n build/Flua.app --args \
    --data-dir /absolute/path/to/disposable-library
```

The override is compiled into the extension’s plist and sandbox read exception. The app refuses setup if its library differs from that path. A build without the override uses the standard Flua library. After tests, rebuild without the override before using the app normally. `make wallpaper-test` checks the library-only catalog and repeated atomic catalog replacement over XPC. `make test` checks safe service PID parsing, media path containment, descriptor generation, all display/Space store updates, metadata preservation and unsupported-store rejection. These tests do not activate system wallpapers.

Before real-host selection, follow the [snapshot and restoration procedure](../Sources/WallpaperExtension/README.md#playback-scoped-files-and-restoration), using the disposable provider identifier and preserving existing registrations. Exercise **Apply Saved Wallpapers** with saved independent and linked surface choices in both display modes and with a newly imported fixture and verify both the saved choice and host scoped-file acquisition. Check that closing the guard input resumes the paused agent. Restore both store plists while the agent is paused, then restart it; compare choices against the baseline while ignoring only system-maintained timestamps. Use Settings → Lock Screen → Remove native provider… to test restoration and exact-path unregistration. If no usable baseline exists, select another wallpaper in System Settings and retry removal. For manual cleanup, unregister the exact extension with `pluginkit -r <app>/Contents/Extensions/FluaWallpaperExtension.appex`, then the containing app with `lsregister -u <app>`. Restore previous wallpaper choices and provider paths, preserving concurrent user changes. Keep snapshots and logs out of Git.

Native removal was checked on arm64 macOS 27.0.1 (26A434) using a disposable catalog and provider identifier. The settings controls and confirmation were visually inspected. Two Apply/removal cycles restored `Index.plist` and `Index_v2.plist` apart from `LastSet`/`LastUse`, removed the exact test registration and preserved every unrelated provider path. A playback-speed edit left the original baseline unchanged. Temporarily withholding that baseline produced the recovery message without changing the active selection; restoring it allowed retry. Removal retained the library. The shared baseline now remains available for Stop and retry. The merged saved-assignment/Stop implementation also passed a Per Display Apply/removal cycle on the built-in display: both stores matched the pre-apply snapshot apart from timestamps, the provider was absent and the shared baseline remained. Removal repeats its guarded restoration after unregistration to clear cached host selections. This does not verify physical multi-display restoration or other OS versions.

### Automatic saved-assignment routing

Use a disposable app bundle with a unique containing-app identifier, a unique `FLUA_WALLPAPER_IDENTIFIER`, a fresh `--data-dir`, and `FLUA_CATALOG_PATH` pointing into that library. Before applying, snapshot both wallpaper stores and record the existing provider paths.

1. Save Northern lights as the Lock Screen choice and click **Apply Saved Wallpapers** once.
2. Select Deep space, keep Lock Screen targeted and click **Save Lock Screen Choice** without applying again. Require `nativePlayback` to remain active and every test-provider `Idle` descriptor in `Index.plist` to contain the new scene. Confirm the Desktop remains unassigned and `Index_v2.plist` has no test-provider choice.
3. Use Settings → Lock Screen → Remove native provider… . Confirm the temporary provider and app registrations are gone, the pre-existing Flua provider registration is unchanged, and both stores match their snapshots ignoring only `LastSet` and `LastUse`.

This passed on arm64 macOS 27.0.1 (26A434) with one built-in display. Saving Deep space changed all 13 test-provider `Idle` descriptors from `aurora` to `cosmos` without a second Apply; the library retained active native intent. The Desktop remained unassigned, `Index_v2.plist` had no test-provider descriptor, both stores matched their original snapshots apart from system timestamps after removal, and the pre-existing Flua provider registration was unchanged. No renderer process was observed after the assignment change. The check targeted only the Lock Screen while the session was unlocked, so it verifies host-store routing, not visible Lock Screen output.

Native recovery checks use a separate provider identifier and disposable library, with both wallpaper stores and registrations recorded before selection. Apply a deliberately undecodable copied image, restore its original bytes at the same path and verify a recovered renderer in the host log without changing the saved descriptor. Terminate only that disposable provider process, then explicitly apply the unchanged assignments and verify a new host acquisition. Restore both stores apart from host timestamps and remove only the disposable registration. To check fresh wrappers, remove all POSIX permissions from the disposable image before Apply and require fallback with zero scoped files. Restore owner read/write permission, explicitly apply the unchanged choices and require a new provider process rendering the image with one wrapper and one active scope. This passed on macOS 27.0.1 (26A434) with one built-in display; it does not simulate revocation of an existing sandbox token. After terminating only that provider, no acquisition was observed during a 12-second wait; explicit Apply reacquired the image. If cleanup materializes the original default globally, verify it is the only non-timestamp difference and restore the original inheritance marker through the guarded transaction. Both stores and provider paths must match before finishing.

For video recovery, replace a copied fixture with undecodable bytes before Apply, restore its original bytes at the same path without reapply, and require recovery in the same provider process followed by frame and loop progress with scoped access. Then terminate only that provider, reapply the unchanged assignment and require a new process with continued loops and an unchanged descriptor. This passed on the same OS and display setup, with both processes reaching 90 frames and three loops; both stores and original provider paths were restored. This does not test file loss during active playback.

For active decoder recovery, first require a disposable video session to advance frames, then truncate the copied media in place without replacing its inode. Require the existing context to switch to the static fallback, restore the bytes into the same file, and require recovery with frame and loop progress, scoped access and unchanged descriptors. `make wallpaper-test` runs the same truncation/recovery path outside the host. The real-host check passed on macOS 27.0.1 (26A434) with one built-in display: playback reached 90 frames / three loops before truncation and again after recovery, with one scoped file and active scope. `Index.plist` matched its snapshot apart from `LastSet`/`LastUse`, `Index_v2.plist` matched exactly, and original provider paths were restored. The guarded Stop call reported a verification error despite matching store comparisons; the production Remove path then unregistered the exact temporary provider. This verifies host-session fallback and recovery, not visible output or revoked sandbox tokens.

Automatic media/player retries wait while suspended; missing or unusable host wrappers require reapply for fresh access. Catalog retries are covered by `make wallpaper-test`, including a failed access reply and deletion/recreation. Physical display reconnection still requires a real multi-display setup.

Native launch/edit checks use separate processes with the production `Library` startup and edit methods, an embedded disposable provider, a matching catalog grant and a fresh library. Follow the same snapshot and rollback procedure before starting:

1. Save independent video/Still Desktop and scene/Animated Lock Screen assignments with active native intent. Start a process, allow startup restoration to finish, and compare both system descriptors with `NativeWallpaperStore.assignments`. Require no desktop overlay and host acquisition of the disposable provider with an active scoped video file.
2. Exit and start another process from the saved library. Check the assignments and modes again. Make rapid speed edits followed by dimming, fit, video trim and thumbnail changes through `Library.edit`; wait for refresh to finish. Compare retained descriptors with the latest catalog, require the original baseline bytes to remain unchanged, and check fresh host acquisition without media errors.
3. In another process, invoke Stop and verify restoration and persisted stopped intent. Start once more and require no native selection or desktop overlay while retaining saved surface choices.
4. Restore only disposable-provider choices from the snapshot through the guarded transaction, unregister the exact extension and app, then repeat restoration if cached selections return. If Mirrored Stop materialized the original default as a global choice, verify that this is the only non-timestamp difference and restore the original global inheritance marker under the guard. Move the unregistered disposable extension out of the containing bundle to prevent rediscovery. Compare both stores ignoring only `LastSet`/`LastUse`, and require the original provider paths to match.

This sequence passed on macOS 27.0.1 (26A434), arm64, with one built-in display. The harness replaced the UI entrypoint in a disposable source copy; production library and provider code handled the transactions. It did not test Dock/window reopening, visible Lock Screen output, idle, sleep/wake or physical multi-display behavior. Detailed observations are in the [provider documentation](../Sources/WallpaperExtension/README.md#native-launch-restoration-and-edit-refresh).

For real transition checks, apply independent Animated Desktop and Still Lock Screen video/scene fixtures from a disposable containing harness, then let that process exit. Start the real screen saver with `open -g /System/Library/CoreServices/ScreenSaverEngine.app`; require a non-preview host acquisition followed by `idle=1` and `idle=0` updates. Record frame/loop counts to distinguish a held Still frame from Animated playback, and have the user confirm visible output. Explicit lock/unlock is a separate check requiring user unlock. Preserve password and idle-timeout preferences. Restore both stores and original provider paths as above. Video Animated/Still and aurora Still idle presentation, plus brief aurora Still lock/unlock, passed on macOS 27.0.1 with one built-in display; see the [recorded scope](../Sources/WallpaperExtension/README.md#native-locked-and-idle-transitions).

## Keyboard verification

The library controls were checked on macOS 27.0.1 (26A434) with the existing macOS Keyboard navigation preference enabled, using disposable `--data-dir` libraries. Repeat this check after changes to browsing controls:

1. Use Tab and Shift-Tab to reach Search, the playback-type picker and all five filter menus. Use arrows and Space for the playback type; Space opens menus, then arrows and Return select values.
2. Choose filters or enter a search with no matches. Reach Clear search and Clear filters with Tab, activate with Space, and confirm results return.
3. From a fresh window, Tab to the tags below Motion intensity in the right-hand details panel without scrolling first. Confirm the focused button scrolls into view. Use Space to apply it, then Shift-Tab to the active tag filter and Space to remove it.
4. Open Settings with Command-comma. Tab to the blocked-tag field and submit with Return; also test Tab/Space on Block and Unblock. Confirm blocked entries disappear and unblocking restores them.

VoiceOver was turned on for this check. With the test library in front, its caption read PLAYLISTS, the sidebar group. Speech for Search, the filter menus, tag actions, favorites, playback buttons and Blocked tags was not captured. On macOS 27.0.1, `make smoke` passed after these name changes. It runs the offscreen name check, then the interactive suite. The names checked are Search, the five filter menus, Clear search, Clear filters, Filter by tag, Remove tag filter, favorite and playback buttons, and Settings → Blocked tags. Repeat the name check after browsing-control changes:

```sh
build/Flua.app/Contents/MacOS/Flua --data-dir /tmp/flua-ax --accessibility-audit /tmp/flua-accessibility.json
```

The smoke suite also checks filter reset, including preservation of persisted blocked tags, but does not replace the keyboard interaction check above.

## Local data and packages

The bundle ID is `local.flua.desktop`. Normal launches use `~/Library/Application Support/Flua/`; an explicit `--data-dir` selects a separate library. The app creates its library on first launch and retains existing Flua data. It does not search other application directories. Login startup is opt-in.

The library root contains `library.json`, `catalog.json` and a `Media/` directory of copied imports. `catalog.json` is rewritten on each successful save and lists image and video files for the wallpaper provider, plus the four built-in scenes with no media file. Rows include speed, dimming, fit, trim, still-frame time, and desktop and Lock Screen modes. Scene still time is 7. Removing a scene retains its media file. If `library.json` cannot be decoded, the app shows the initial scenes in memory and blocks saves and imports, preserving the unreadable manifest. Quit before inspecting or restoring that file. For isolated runtime verification, supply both `--data-dir` and `--smoke-test` as shown in the [README](../README.md#build-and-verify); `--smoke-test` alone does not select a separate library.

Scene exports use `.flua` folders containing a video, thumbnail and JSON manifest. Imports accept manifest folders, direct JSON manifests and ZIP archives. ZIP members and media paths are validated before import; source files remain intact. Interactive scene runtimes are unsupported.

A folder must contain exactly one `manifest.json` or `*-manifest.json`; a directly selected JSON file can have any name. A ZIP or `.bdpkg` archive may contain that layout at its root or inside a single top-level folder. The minimum manifest is:

```json
{
  "type": "video",
  "files": {"asset": "clip.mp4"}
}
```

The asset must be a regular `.mov`, `.mp4` or `.m4v` file within the package. Optional imported fields are `title`, `tags` (an array or comma-separated string), `details`, `categoryIdentifier`, `linkTitle`, `linkURL`, `color`, `motionIntensity` and `thumbnailTimestamp`. Imports measure media facts locally and generate their own thumbnails; a manifest's dimensions, duration, date added and thumbnail file are not used as those facts or the library thumbnail.

Manifests are limited to 1 MiB and archives to 512 MiB. Folder and ZIP validation also limits individual files to 512 MiB, expanded contents to 1 GiB and entries to 4,096. ZIP import accepts stored or deflated entries and rejects links, unsafe or conflicting paths, AppleDouble entries, encryption, streaming entries, ZIP64, archive comments and excessive expansion. Directly selected manifests validate the named asset without walking unrelated files beside the manifest or imposing these folder-size limits.

Scene-package export refuses an existing destination. MP4/preview and PNG export can replace an existing destination while preserving the source. MP4 export stages its output beside the destination before moving or replacing it; cancellation leaves an existing destination intact.

Browsing rules and media bucket boundaries are tested in `ModelTests.swift`. The isolated smoke run additionally measures image/video imports and rotated video, exercises legacy metadata backfill, checks classification preservation through package export/import, and verifies blocked Discover entries, cleared selections, filter reset without clearing persisted blocked tags, and the VoiceOver names of the browsing controls. It saves filter, empty-result, Browse, Settings, Discover and editor screenshots (including light/dark control styling) alongside `smoke-results.json` for visual inspection.
