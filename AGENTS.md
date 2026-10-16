# Flua agent guide

## Project boundaries

- Flua is a local-only SwiftUI/AppKit application for Apple Silicon Macs running macOS 15 or later.
- Keep the main app in `Sources/Flua/` free of third-party runtime dependencies unless the task explicitly requires one.
- Treat `experimental/WallpaperExtension/` as a separate prototype. It uses private macOS APIs, requires a macOS 26 SDK/runtime, and is not part of the desktop app build.
- Do not add network services, telemetry, accounts, or cloud storage unless explicitly requested.

## Source map

- `App.swift`: application lifecycle, windows, menu bar, and top-level SwiftUI views.
- `Library.swift`: library operations, persistence coordination, imports, and playback actions.
- `Model.swift`: Codable state and playlist behavior.
- `LibraryPaths.swift`: application-support directory resolution.
- `Engine.swift`: per-display desktop windows and AVFoundation playback.
- `SceneView.swift`: built-in procedural scenes.
- `Editor.swift`: video preview and export.
- `ScenePackage.swift`: package and ZIP validation/import.
- `SmokeRunner.swift`: opt-in isolated runtime verification.

## Working rules

- Make the smallest complete change and follow the patterns already present in nearby code.
- Feel free to add nested `AGENTS.md` files when a directory genuinely needs local rules that do not apply to the whole repository; avoid them otherwise.
- Preserve backward compatibility for persisted Codable data. Existing libraries must continue to load without migration-related data loss.
- Treat file paths, manifests, and ZIP contents as untrusted input. Keep path-containment and archive validation at import boundaries.
- Never use a developer's real `~/Library/Application Support/Flua/` data for tests. Use a new disposable directory with `--data-dir`.
- Preserve source media during import and editing. Export to a new destination and do not overwrite an existing destination unless the task explicitly changes that behavior.
- Keep UI and user-facing documentation in English, matching the existing application.
- Follow `.editorconfig`: four spaces in Swift, tabs in `Makefile`, LF endings, and a final newline.
- Do not edit generated `.build/`, `build/`, `dist/`, or `experimental/**/Built/` artifacts.
- Do not commit, push, notarize, register login items, or activate the experimental system provider unless explicitly requested.

## Validation

Run the narrowest relevant checks, then expand when the change crosses boundaries:

- Model, persistence, paths, or package import: `make test`.
- Main app build or compile-sensitive UI changes: `make build`.
- Playback, UI, import/export, or end-to-end behavior: `make smoke` after `make build` (the `make smoke` target builds automatically).
- Experimental provider changes: `make native-test`.
- Release packaging changes: `make release` and verify the produced archive under `dist/`.

Smoke tests briefly create a desktop overlay and write only to a fresh directory under `build/verification/`. Do not claim multi-display, sleep/wake, fullscreen, battery, login startup, system-provider activation, or other hardware/OS integration behavior was verified unless it was tested on the relevant real setup.

## Tests and documentation

- Add or update a focused deterministic test for non-trivial model, persistence, path, or package-validation logic.
- Tests in `Tests/FluaTests/` are standalone Swift executables driven by `scripts/test.sh`, not XCTest targets.
- Update `docs/FEATURES.md` when capability status changes, `docs/ARCHITECTURE.md` when responsibilities or boundaries change, and `README.md` / `docs/DEVELOPMENT.md` when user or developer workflows change.
- Keep documentation claims aligned with behavior that has actually been implemented and verified.
