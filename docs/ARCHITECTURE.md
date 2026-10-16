# Architecture

Flua is a local SwiftUI/AppKit macOS application. `App.swift` creates the shared library and owns windows, settings and the menu bar. `Library.swift` coordinates UI actions, persistence and playback. `Model.swift` contains Codable state and playlist transitions; `LibraryPaths.swift` resolves the application's local library directory.

`Engine.swift` maintains click-through desktop windows and AVFoundation playback per display. `SceneView.swift` renders the four procedural scenes. `Editor.swift` previews and exports media without overwriting source files. `ScenePackage.swift` validates manifest folders and ZIP containers before imports copy media into the library. `SmokeRunner.swift` runs only when explicitly requested with isolated test paths.

The experimental native provider is a separate build boundary and uses private OS protocols. It is not registered by the desktop application. Its standalone test success does not establish acceptance by WallpaperAgent. Supported capabilities and remaining work are tracked in FEATURES.md.
