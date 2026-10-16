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

`Package.swift` supports SwiftPM and opening the source package in Xcode. Use `make build` for a runnable `.app`; `swift build` alone only produces an executable. Model/package tests are standalone executables run by `make test`, not XCTest targets. Smoke tests write only to a fresh directory under `build/verification/`; they briefly create and remove a desktop overlay.

## Layout

- `Sources/Flua/`: main application, rendering, persistence, importer and editor.
- `Tests/FluaTests/`: deterministic model, library path and package validation tests.
- `Resources/`: bundle metadata and original application icon.
- `scripts/`: reproducible build, test and release entry points.
- `docs/`: architecture and feature status.
- `experimental/WallpaperExtension/`: independent native-provider prototype, not embedded in the application.
- `.build/`, `build/`, `dist/`: ignored, generated artifacts.

## Changes and validation

Keep media and account information out of the repository. Test model/import changes with `make test`, and playback/UI/export changes with `make smoke`. Build the experimental provider separately when changing its protocol. Update FEATURES.md when support changes. Validation results belong in fresh generated output.

The project is a local Git repository; commits and remotes are left to the developer. No CI service, signing account or deployment credentials are required. Release bundles are ad-hoc signed, not notarized.

## Local data and packages

The bundle ID is `local.flua.desktop`. Normal launches use `~/Library/Application Support/Flua/`; an explicit `--data-dir` selects a separate library. The app creates its library on first launch and retains existing Flua data. It does not search other application directories. Login startup is opt-in.

Scene exports use `.flua` folders containing a video, thumbnail and JSON manifest. Imports accept manifest folders, direct JSON manifests and ZIP archives. ZIP members and media paths are validated before import; source files remain intact. Interactive scene runtimes are unsupported.
