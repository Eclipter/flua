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

Inspector checks run in the actual library window with its unified toolbar. They verify mouse hit targets for Play Wallpaper and a playback slider, then send a mouse click to Play Wallpaper and check desktop playback for both a built-in scene and an imported video. The offscreen accessibility name audit alone does not cover this routing.

The transparent menu bar PNG lives in `Sources/Flua/Resources/MenuBarSakura.png`. SwiftPM packages it in `Flua_Flua.bundle`; the build script copies that bundle into the app's `Contents/Resources/` before signing. `MenuBarIcon.swift` loads it as an 18-point template image so macOS supplies the menu bar color. The library sidebar draws the same image at 22 points and tints it with the accent color. The prompt that produced it is `docs/MENU_BAR_ICON_PROMPT.md`.

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

`make build` creates `build/Flua.app`. The extension requires a macOS 26 or newer SDK; the setup UI is gated to macOS 27. The extension uses `local.flua.desktop.wallpaper`, a sandbox signature and a file-only read exception for `~/Library/Application Support/Flua/catalog.json`. Prototype fixtures are hidden. Apply registers the containing app and its extension, selects its PlugInKit election and directly updates the user wallpaper store through a guarded transaction. The helper validates the current-user agent before pausing it; EOF, timeout or handled termination resumes it. A successful write restarts it. `NativeWallpaperStore` rejects unknown formats and resolves saved choices and modes for targeted displays and existing Spaces. Unassigned surfaces and untargeted overrides are preserved; Per Display moves the previous global choice into the default fallback before writing the global override as `$null`. A backup is retained in the library as `NativeWallpaperBackup.plist`. Playback-setting edits reuse the guarded transaction after a 0.5-second debounce, updating matching active choices while preserving modes. Deterministic descriptor tests do not access the user’s wallpaper store. Desktop and Lock Screen use their saved independent or linked selections and modes. Successful application removes overlays on targeted native desktops; Pause, playlists and automatic native launch restoration remain separate. Stop restores both targeted native surfaces from `NativeWallpaperBaseline.plist` while retaining saved Flua choices. The baseline is captured before native Apply and retained across repeated applies and playback edits. Missing or unusable baselines fail without writing the system store; select another system wallpaper before applying Flua to establish a new baseline. Native Stop skips automatic playlist advancement and reconnection restoration on those displays for the rest of the session until playback is explicitly started again.

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

Browsing rules and media bucket boundaries are tested in `ModelTests.swift`. The isolated smoke run additionally measures image/video imports and rotated video, exercises legacy metadata backfill, checks classification preservation through package export/import, and verifies blocked Discover entries, cleared selections, filter reset without clearing persisted blocked tags, and the VoiceOver names of the browsing controls. It saves filter, empty-result, Settings, Discover and editor screenshots alongside `smoke-results.json` for visual inspection.
