# Architecture

Flua is a local SwiftUI/AppKit application for Apple Silicon Macs running macOS 27 or later. The main app has no third-party runtime dependencies. macOS owns wallpaper playback through the embedded provider; the app has no desktop overlay playback engine.

## Application and library

- `App.swift` owns application lifecycle, windows, Settings, menu bar and library views. Shared controls honor the selected accent and Reduce Transparency. Menu bar and Dock visibility are persisted; hiding the Dock requires the menu bar icon to remain enabled.
- `Library.swift` coordinates browsing, imports, edits, persistence, playlists and native playback. A two-second timer advances playlists only when needed. Pause stops automatic playlist advancement; battery, Low Power Mode and fullscreen preferences are stored but do not control native playback.
- `Model.swift` contains backward-compatible Codable state, filtering, media classifications and playlist transitions. Display assignments use stable UUIDs and retain disconnected displays. Each stores Desktop and optional Lock Screen choices with separate modes and playlist state. Linking synchronizes both surfaces; Mirrored mode synchronizes the whole pair across connected displays.
- `LibraryPaths.swift` resolves the library root. `MediaFacts.swift` inspects local media and classifies bounded thumbnails off the main thread.

`LibraryDisk` in `Model.swift` atomically writes `library.json` and `catalog.json`. Imported media is copied under `Media/`; retained still frames use `Stills/`. Removing an entry retains its copied media. An unreadable library manifest leaves the original file untouched and blocks saves and imports for that session.

The versioned provider catalog publishes eligible images, videos and the four built-in scenes. Rows contain stable IDs, media references, speed, dimming, fit, video trim, still time and surface modes. Scene still time is 7; conflicting display modes publish Animated for that surface. Blocked or unsafe entries are omitted.

## Previews, editing and imports

`Engine.swift` provides `MediaSurface` for app previews and display identification. Video and scene previews pause when hidden, offscreen or fully occluded. Volume applies to app video previews; native configuration does not carry it.

`SceneView.swift` hosts an `MTKView`. `ScenePreviewRenderer.swift` shares Metal resources, and `ScenePreview.metal` renders four scenes at up to 60 fps, capped at 1280 pixels on the long edge with at most two frames in flight. A busy GPU skips frames; failed setup shows a still preview. `SceneDrawing.swift` supplies the Core Graphics reference used for thumbnails, still frames and provider rendering at up to 24 fps.

`Editor.swift` owns draft video trim/cover edits and portable package export. Save Changes commits; Cancel or closing discards drafts. `ScenePackage.swift` validates package manifests, paths and ZIP contents before copying media. Source files are preserved. Global imports reveal the added batch and retain IDs for Undo; playlist imports receive an explicit destination.

## Native wallpaper boundary

`NativeWallpaper.swift` registers and verifies the current containing app and extension, checks the catalog path, serializes transactions and invokes `FluaWallpaperGuard`. The helper validates the current-user WallpaperAgent executable and pauses it while the store is read and replaced. Commit restarts the agent; EOF, timeout or handled termination resumes an abandoned transaction.

`NativeWallpaperStore.swift` validates the private store format and resolves saved choices into Desktop and Lock Screen descriptors across targeted displays and existing Spaces. It preserves unrelated metadata and choices. Per Display retains the global choice as the default fallback and writes targeted overrides; Mirrored updates defaults and targeted assignments. Missing or blocked saved items abort application.

`NativeWallpaperBackup.plist` backs up the last transaction. `NativeWallpaperBaseline.plist` retains previous system choices across repeated applies and edits. Stop restores targeted Flua surfaces while retaining library selections. Missing or unsafe baselines fail without a store write. Provider removal restores remaining Flua surfaces, unregisters the exact app/extension paths and repeats restoration to clear cached host choices. Foreign selections and library media are preserved.

`LibraryState.nativePlayback` records active or stopped intent per display. Launch and reconnection compare saved assignments with the system store and provider registration; matching choices continue without a reload. Changed assignments use guarded Apply. Stopped displays skip restoration and automatic advancement. Unavailable or mismatched builds retain intent without applying wallpapers. Explicit Apply reloads even unchanged choices to permit recovery after termination.

Playback edits and active saved-assignment changes are coalesced for 0.5 seconds. Parameter refresh matches provider, kind and media URLs, preserves surface modes and unknown configuration fields, and skips no-op reloads. Assignment replacement first restores Flua-owned surfaces from the baseline, preventing cleared choices from leaving stale selections.

## Provider

`Sources/WallpaperExtension/` is a separate compile boundary using private macOS protocols. `make build` embeds a sandboxed provider under `Contents/Extensions/`. Its file-read exception covers only `catalog.json`; media access uses host-supplied scoped wrappers. `FLUA_CATALOG_PATH` and `FLUA_WALLPAPER_IDENTIFIER` select disposable integration builds. `FLUALibraryOnly` hides standalone prototype fixtures.

The provider watches catalog writes and atomic replacements, including acquisition from cached host choices. Desktop presentation uses the Desktop mode; locked and idle presentations use the Lock Screen mode. Suspension preserves saved modes. Missing or undecodable media uses a static gradient; a five-second retry while unsuspended can rebuild the renderer in the same remote context. Missing or unusable wrappers require explicit reapply for fresh grants. Cached descriptors can render independently of the catalog; unsupported descriptor versions return an error.

Protocol details and recorded host checks live in the [provider documentation](../Sources/WallpaperExtension/README.md) and [protocol reference](../Sources/WallpaperExtension/PROTOCOL.md).

## Verification boundary

`SmokeRunner.swift` requires isolated paths and disables system Apply, Stop, restoration, refresh and removal while retaining persistence and descriptor validation. It checks app previews and workflows; native host behavior is tested separately. See [DEVELOPMENT.md](DEVELOPMENT.md) for procedures, [FEATURES.md](FEATURES.md) for support and [PLAN.md](PLAN.md) for unresolved work.
