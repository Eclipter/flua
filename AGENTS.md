# Flua agent guide

## Project boundaries

- Flua is a local-only SwiftUI/AppKit application for Apple Silicon Macs running macOS 27 or later.
- Keep the main app in `Sources/Flua/` free of third-party runtime dependencies unless the task explicitly requires one.
- `Sources/WallpaperExtension/` is the wallpaper provider. It uses private macOS APIs and macOS 27 SDK. `make build` embeds it in `Flua.app`. Flua relies exclusively on macOS native wallpaper playback.
- Do not add network services, telemetry, accounts, or cloud storage unless explicitly requested.

## Source map

- `App.swift`: application lifecycle, windows, menu bar, and top-level SwiftUI views.
- `Library.swift`: library operations, persistence coordination, imports, and playback actions.
- `Model.swift`: Codable state and playlist behavior.
- `LibraryPaths.swift`: application-support directory resolution.
- `MediaFacts.swift`: local image/video inspection and thumbnail color classification.
- `Engine.swift`: media preview surface and display identification.
- `SceneView.swift`: built-in procedural preview host. `ScenePreviewRenderer.swift` and `ScenePreview.metal` render previews on the GPU; `SceneDrawing.swift` remains the thumbnail/still/provider reference.
- `Editor.swift`: video preview and export.
- `ScenePackage.swift`: package and ZIP validation/import.
- `SmokeRunner.swift`: opt-in isolated runtime verification.
- `Sources/WallpaperExtension/`: wallpaper provider, its fixtures and standalone tests.

## Working rules

- Make the smallest complete change and follow the patterns already present in nearby code.
- Feel free to add nested `AGENTS.md` files when a directory genuinely needs local rules that do not apply to the whole repository; avoid them otherwise.
- Preserve backward compatibility for persisted Codable data. Existing libraries must continue to load without migration-related data loss.
- Treat file paths, manifests, and ZIP contents as untrusted input. Keep path-containment and archive validation at import boundaries.
- Never use a developer's real `~/Library/Application Support/Flua/` data for tests. Use a new disposable directory with `--data-dir`.
- When testing native wallpaper application or provider setup with a disposable `--data-dir`, rebuild the app bundle with `FLUA_CATALOG_PATH` set to that directory's `catalog.json` (and `FLUA_WALLPAPER_IDENTIFIER` if testing provider registration). Otherwise, applying native wallpapers in the app will be blocked with *"This build uses a different library"*. A build with `FLUA_CATALOG_PATH` opens that catalog’s library when `--data-dir` is omitted.
- Preserve source media during import, editing and export. Replacing an existing export destination is allowed with explicit user consent, such as confirmation in the save dialog. Never replace files silently.
- Keep UI and user-facing documentation in English, matching the existing application.
- Follow `.editorconfig`: four spaces in Swift, tabs in `Makefile`, LF endings, and a final newline.
- Do not edit generated `.build/`, `build/`, `dist/`, or `Sources/WallpaperExtension/Built/` artifacts.
- Do not push, notarize, or register login items unless explicitly requested.
- Run `make release` only when the user explicitly requests a release. It increments the app and wallpaper extension patch version and build number, builds the app and creates `dist/Flua.zip`. Never run it as routine implementation, verification, or task completion; keep versions unchanged during ordinary development.
- Reversible OS integration checks are authorized when needed to implement or verify the requested task, including temporary registration, selection and activation of the wallpaper provider. No separate confirmation is needed for these checks. Use disposable fixtures, record the affected system settings and establish a rollback procedure before changing them, then restore the previous settings and registration state on completion or failure. Ask before irreversible changes or when reliable restoration cannot be established.

## Git history

- Keep `main` linear. Integrate each completed task with a squash merge, producing one commit for one coherent change; do not create merge commits or replay a task's intermediate commits onto `main`.
- Use `git merge --squash <branch>` locally or `gh pr merge --squash` for pull requests. Review the staged result, run the relevant checks, then commit before deleting the task branch or worktree.
- After that commit is on `main`, run `make build` with `FLUA_CATALOG_PATH` and `FLUA_WALLPAPER_IDENTIFIER` unset. The resulting `build/Flua.app` matches `main` and the standard library. When the integration was `gh pr merge --squash`, update the local `main` checkout first, then run the same build.
- Write English Conventional Commit subjects (`feat:`, `fix:`, `perf:`, `test:`, `docs:`, `build:`, `chore:`) describing the resulting behavior. Add a body only when it explains a useful reason, limitation or validation detail. Omit branch names, plan item numbers and intermediate attempts.
- Rewrite published history or force-push only when explicitly requested. See [the development workflow](docs/DEVELOPMENT.md#git-workflow) for local configuration.

## Validation

Run the narrowest relevant checks, then expand when the change crosses boundaries:

- Run GUI verification and profiling through `scripts/system-test-lock.py` so worktrees wait for one shared per-user lock. `make smoke` and the fullscreen observer acquire it automatically. Wrap every other command that launches Flua for verification or changes native wallpaper/system state in the same helper, holding it through rollback and verification. The lock releases when its process exits; it cannot verify rollback after a forced termination. Never launch a test copy while any Flua process is running. Agents may gracefully quit any running Flua instance, including the user’s normal library session, when needed for the task or verification, without asking for separate confirmation. Wait for the app to exit before launching a test copy; do not force-quit a normal library session.

- The agent that prepares a system integration test and records its baseline owns the full procedure through OS changes, checks, restoration and a fresh verification that the baseline state is restored. Read-only preparation may be delegated. If that agent is interrupted and a replacement must continue, the replacement must reacquire the shared lock, compare actual processes and settings with the original baseline, and finish and verify restoration before starting another test. A previous success report may predate a later failed attempt and does not prove the current state is restored.

- After every UI change, visually inspect the current build in a real app window with a disposable `--data-dir`. Check the affected layout and interactions before reporting completion; builds and smoke tests alone do not count as visual verification.

- Model, persistence, paths, or package import: `make test`.
- Main app build or compile-sensitive changes not covered by smoke: `make build`.
- Playback, UI, import/export, or end-to-end behavior: `make smoke`. It builds its disposable app itself; do not run a separate `make build` first.
- Wallpaper provider changes: `make wallpaper-test`.
- Release packaging changes: run `python3 Tests/Scripts/ReleaseTests.py` in disposable fixtures. Only when the user explicitly requests a release, run `make release` and verify the produced archive under `dist/`.

Smoke app bundles and test data live in a fresh workspace under `/private/tmp/flua-smoke.*/`, linked from `build/verification/`. Keep the smoke app, test data and launch working directory outside privacy-protected folders such as Documents; leave the normal `build/Flua.app` unchanged. Do not claim multi-display, sleep/wake, fullscreen, battery, login startup, system-provider activation, or other hardware/OS integration behavior was verified unless it was tested on the relevant real setup.

## Tests and documentation

- Keep `docs/PLAN.md` limited to unresolved work. Remove completed tasks instead of retaining checked entries; keep capability status and verification evidence in the relevant documentation.

- Add or update a focused deterministic test for non-trivial model, persistence, path, or package-validation logic.
- Tests in `Tests/FluaTests/` are standalone Swift executables driven by `scripts/test.sh`, not XCTest targets.
- Update `docs/FEATURES.md` when capability status changes, `docs/ARCHITECTURE.md` when responsibilities or boundaries change, and `README.md` / `docs/DEVELOPMENT.md` when user or developer workflows change.
- Keep documentation claims aligned with behavior that has actually been implemented and verified.
