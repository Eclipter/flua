# Development

Requires macOS 15+, Apple Silicon and Apple Swift command-line tools (`xcode-select --install`). The experimental wallpaper extension additionally needs a macOS 26 SDK/runtime. There are no external Swift package dependencies.

```sh
make build       # release executable, app bundle, ad-hoc signature
make test        # model, library path, package security tests
make smoke       # isolated end-to-end app tests, then exits
make run         # open the desktop app
make release     # dist/Flua-macOS.zip
make native-test # isolated experimental provider tests, no OS activation
```

`Package.swift` supports SwiftPM and opening the source package in Xcode. Use `make build` for a runnable `.app`; `swift build` alone only produces an executable. Model/package tests are standalone executables run by `make test`, not XCTest targets. Smoke tests launch a separate app instance through Launch Services, wait for it to exit, and write only to a fresh directory under `build/verification/`; they briefly create and remove a desktop overlay.

The build script updates the app bundle's modification time after signing so Launch Services can detect changed metadata and icon resources on subsequent launches.

## Layout

- `Sources/Flua/`: main application, rendering, persistence, media inspection, importer and editor.
- `Tests/FluaTests/`: deterministic model, library path and package validation tests.
- `Resources/`: bundle metadata and original application icon.
- `scripts/`: reproducible build, test and release entry points.
- `docs/`: architecture and feature status.
- `experimental/WallpaperExtension/`: independent native-provider prototype, not embedded in the application.
- `.build/`, `build/`, `dist/`: ignored, generated artifacts.

## Changes and validation

Keep media and account information out of the repository. Test model/import changes with `make test`, and playback/UI/export changes with `make smoke`. Build the experimental provider separately when changing its protocol. Update [feature status](FEATURES.md) when support changes. Validation results belong in fresh generated output.

`make native-test` also verifies the boxed download-status reply over XPC. It does not register or select a wallpaper. Real-host playback and file-access checks use disposable containing apps and the [provider verification and restoration procedure](../experimental/WallpaperExtension/README.md#playback-scoped-files-and-restoration). Keep their source copies, fixtures, local settings snapshots and logs outside Git.

The project is a local Git repository; commits and remotes are left to the developer. No CI service, signing account or deployment credentials are required. Release bundles are ad-hoc signed, not notarized.

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

The library root contains `library.json`, `catalog.json` and a `Media/` directory of copied imports. `catalog.json` is rewritten on each successful save and lists image and video files for the experimental provider. Removing a scene retains its media file. If `library.json` cannot be decoded, the app shows the initial scenes in memory and blocks saves and imports, preserving the unreadable manifest. Quit before inspecting or restoring that file. For isolated runtime verification, supply both `--data-dir` and `--smoke-test` as shown in the [README](../README.md#build-and-verify); `--smoke-test` alone does not select a separate library.

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
