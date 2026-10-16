# Architecture

Flua is a local SwiftUI/AppKit macOS application. `App.swift` creates the shared library and owns windows, settings and the menu bar. `Library.swift` coordinates UI actions, persistence and playback. `Model.swift` contains backward-compatible Codable state, exact-tag normalization, browsing/filter rules, media buckets and playlist transitions; `LibraryPaths.swift` resolves the application's local library directory.

`MediaFacts.swift` measures local image/video facts and classifies a bounded thumbnail off the main thread. `Library.swift` records successful import dates, backfills legacy facts and routes Discover and collection views through the same model rules. Blocked tags affect browsing while preserving playback assignments.

`LibraryDisk` in `Model.swift` atomically writes `library.json` and resolves imported files under `Media/`. An unreadable manifest leaves the saved library untouched: `Library.swift` uses the initial scenes in memory and blocks saves and imports for that session. Removing a library entry retains its copied media file.

`Engine.swift` maintains click-through desktop windows and AVFoundation playback per display. `SceneView.swift` renders the four procedural scenes. `Editor.swift` previews and exports media without overwriting source files. `ScenePackage.swift` validates manifest folders and ZIP containers before imports copy media into the library. `SmokeRunner.swift` runs only when explicitly requested with isolated test paths.

The experimental native provider is a separate build boundary and uses private OS protocols. It is not registered by the desktop application. Its standalone test success does not establish acceptance by WallpaperAgent. Supported capabilities and remaining work are tracked in [feature status](FEATURES.md) and the [implementation plan](PLAN.md).
