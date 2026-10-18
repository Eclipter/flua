import Foundation

@main struct ModelTests {
    static func main() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FluaTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let support = dir.appendingPathComponent("ApplicationSupport", isDirectory: true)
        let fm = FileManager.default
        let fresh = LibraryPaths.resolve(applicationSupport: support)
        precondition(fresh == support.appendingPathComponent("Flua", isDirectory: true))
        precondition(!fm.fileExists(atPath: support.path))
        let unrelated = support.appendingPathComponent("OtherLibrary", isDirectory: true)
        try fm.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let original = Data("unrelated-library".utf8)
        try original.write(to: unrelated.appendingPathComponent("library.json"))
        precondition(LibraryPaths.resolve(applicationSupport: support) == fresh)
        precondition(!fm.fileExists(atPath: fresh.path))
        try fm.createDirectory(at: fresh, withIntermediateDirectories: true)
        let current = Data("flua-library".utf8)
        try current.write(to: fresh.appendingPathComponent("library.json"))
        precondition(LibraryPaths.resolve(applicationSupport: support) == fresh)
        let retained = try Data(contentsOf: fresh.appendingPathComponent("library.json"))
        let unrelatedData = try Data(contentsOf: unrelated.appendingPathComponent("library.json"))
        precondition(retained == current && unrelatedData == original)
        print("PASS: library path resolution preserves existing data and leaves unrelated directories untouched")
        let disk = try LibraryDisk(root: dir)
        var state = try disk.load()
        precondition(state.wallpapers.count == 4)
        precondition(state.displayMode == "mirrored")
        precondition(state.accentColor == nil)
        precondition(state.nativePlayback.isEmpty)
        var nativeState = state
        nativeState.nativePlayback = ["active": true, "stopped": false, "disconnected": true]
        try disk.save(nativeState)
        let nativeRoundTrip = try disk.load()
        precondition(nativeRoundTrip.nativePlayback == nativeState.nativePlayback)
        precondition(nativeRoundTrip.nativeRestorationDisplays(connected: ["active", "stopped", "legacy"]) == ["active"])
        precondition(nativeRoundTrip.nativeRestorationDisplays(connected: ["active", "disconnected", "stopped", "legacy"], previouslyConnected: ["active"]) == ["disconnected"])
        precondition(nativeRoundTrip.nativeRestorationDisplays(connected: ["active"], previouslyConnected: ["active"]) == [])
        precondition(nativeRoundTrip.nativeRestorationDisplays(connected: [], previouslyConnected: ["active"]) == [])
        var activeNativeDisplays = nativeRoundTrip
        activeNativeDisplays.nativePlayback = ["active": true, "second": true, "stopped": false]
        precondition(activeNativeDisplays.nativeAssignmentRefreshDisplays(changed: ["stopped"], connected: ["active", "second", "stopped"], mirrored: false) == [])
        precondition(activeNativeDisplays.nativeAssignmentRefreshDisplays(changed: ["active"], connected: ["active", "second", "stopped"], mirrored: false) == ["active", "second"])
        precondition(activeNativeDisplays.nativeAssignmentRefreshDisplays(changed: ["stopped"], connected: ["active", "second", "stopped"], mirrored: true) == ["active", "second"])
        precondition(activeNativeDisplays.nativeApplicationDisplays(targeted: ["stopped"], connected: ["active", "second", "stopped"]) == ["active", "second", "stopped"])
        var nativeAssignments = LibraryState.initial
        nativeAssignments.assign("aurora", display: "active")
        nativeAssignments.assign("ocean", display: "active", surface: .lockScreen)
        nativeAssignments.assign("ember", display: "other")
        var changedNativeAssignments = nativeAssignments
        changedNativeAssignments.setMode(.still, display: "active", surface: .lockScreen)
        changedNativeAssignments.assign("cosmos", display: "other")
        precondition(changedNativeAssignments.nativeAssignmentChanges(from: nativeAssignments.displays, displays: ["active", "other", "missing"]) == ["active", "other"])
        var metadataOnlyNativeAssignment = nativeAssignments
        metadataOnlyNativeAssignment.assign("aurora", display: "active", now: Date(timeIntervalSince1970: 42))
        precondition(metadataOnlyNativeAssignment.nativeAssignmentChanges(from: nativeAssignments.displays, displays: ["active"]).isEmpty)
        var removedNativeAssignment = nativeAssignments
        removedNativeAssignment.remove("ocean")
        precondition(removedNativeAssignment.nativeAssignmentChanges(from: nativeAssignments.displays, displays: ["active"]) == ["active"])
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(nativeState)) as! [String: Any]
        legacy.removeValue(forKey: "nativePlayback")
        let legacyNativeState = try JSONDecoder().decode(LibraryState.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(legacyNativeState.nativePlayback.isEmpty && legacyNativeState.wallpapers == state.wallpapers)
        print("PASS: native playback intent retains active, stopped and disconnected displays and defaults safely for legacy libraries")
        var accentState = state
        accentState.accentColor = "Purple"
        try disk.save(accentState)
        let restoredAccent = try disk.load()
        precondition(restoredAccent.accentColor == "Purple" && restoredAccent.wallpapers == state.wallpapers)
        accentState.accentColor = nil
        let systemAccentData = try JSONEncoder().encode(accentState)
        let systemAccentJSON = try JSONSerialization.jsonObject(with: systemAccentData) as! [String: Any]
        precondition(systemAccentJSON["accentColor"] == nil)
        let legacyAccent = try JSONDecoder().decode(LibraryState.self, from: systemAccentData)
        precondition(legacyAccent.accentColor == nil && legacyAccent.wallpapers == state.wallpapers)
        try disk.save(state)
        print("PASS: accent preference persists and missing preferences follow the system")
        var presence = LibraryState.initial
        precondition(presence.showsMenuBar && presence.hidesDockIcon == false)
        let defaultJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(presence)) as! [String: Any]
        precondition(defaultJSON["showInMenuBar"] == nil && defaultJSON["hideFromDock"] == nil)
        presence.setHidesDockIcon(true)
        precondition(presence.hidesDockIcon)
        let savedPresence = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(presence))
        precondition(savedPresence.hidesDockIcon && savedPresence.showsMenuBar && savedPresence.wallpapers == presence.wallpapers)
        presence.setShowsMenuBar(false)
        precondition(presence.showsMenuBar == false && presence.hidesDockIcon == false && presence.hideFromDock == nil)
        presence.setHidesDockIcon(true)
        precondition(presence.hidesDockIcon == false)
        var inconsistent = try JSONSerialization.jsonObject(with: JSONEncoder().encode(LibraryState.initial)) as! [String: Any]
        inconsistent["showInMenuBar"] = false
        inconsistent["hideFromDock"] = true
        let rejected = try JSONDecoder().decode(LibraryState.self, from: JSONSerialization.data(withJSONObject: inconsistent))
        precondition(rejected.showsMenuBar == false && rejected.hidesDockIcon == false && rejected.hideFromDock == nil)
        inconsistent.removeValue(forKey: "showInMenuBar")
        inconsistent.removeValue(forKey: "hideFromDock")
        let legacyPresence = try JSONDecoder().decode(LibraryState.self, from: JSONSerialization.data(withJSONObject: inconsistent))
        precondition(legacyPresence.showsMenuBar && legacyPresence.hidesDockIcon == false)
        print("PASS: dock hiding requires the menu bar icon and legacy libraries keep both defaults")
        precondition(resolvedDisplayMode(nil) == "perDisplay")
        precondition(initialDisplaySelection(mode: "perDisplay", displayIDs: ["display-A"]) == "display-A")
        precondition(initialDisplaySelection(mode: nil, displayIDs: ["display-A"]) == "display-A")
        var legacyState = state
        legacyState.displayMode = nil
        let restoredLegacyState = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(legacyState))
        precondition(restoredLegacyState.displayMode == nil && resolvedDisplayMode(restoredLegacyState.displayMode) == "perDisplay")
        state.displays["display-A"] = DisplayAssignment(desktop: SurfaceAssignment(wallpaperID: "aurora", playlistID: "ambient", changedAt: Date(timeIntervalSince1970: 0)))
        precondition(state.advance(display: "display-A", now: Date(timeIntervalSince1970: 299)) == nil)
        precondition(state.advance(display: "display-A", now: Date(timeIntervalSince1970: 300))?.id == "ocean")
        precondition(state.advance(display: "display-A", now: Date(timeIntervalSince1970: 301)) == nil)
        state.playlists[0].interval = 86_400
        state.playlists[0].shuffle = false
        state.displays["display-A"] = DisplayAssignment(desktop: SurfaceAssignment(wallpaperID: "aurora", playlistID: "ambient", changedAt: Date(timeIntervalSince1970: 10_000)))
        precondition(state.advance(display: "display-A", now: Date(timeIntervalSince1970: 10_000 + 86_399)) == nil)
        precondition(state.advance(display: "display-A", now: Date(timeIntervalSince1970: 10_000 + 86_400))?.id == "ocean")
        state.playlists[0].interval = nil
        state.playlists[0].shuffle = nil
        state.displays["display-A"] = DisplayAssignment(desktop: SurfaceAssignment(wallpaperID: "aurora", playlistID: "ambient"))
        let mirroredAssignment = DisplayAssignment(desktop: SurfaceAssignment(wallpaperID: "ocean", playlistID: "ambient", index: 1,
                                                   changedAt: Date(timeIntervalSince1970: 2_000), history: ["aurora"]))
        state.displays["display-B"] = mirroredAssignment
        precondition(state.synchronizeMirrored(displayIDs: ["display-A", "display-B", "display-C"], preferredSource: "display-B")?.id == "ocean")
        precondition(state.displays["display-A"] == mirroredAssignment && state.displays["display-B"] == mirroredAssignment && state.displays["display-C"] == mirroredAssignment)
        precondition(state.advanceMirrored(displayIDs: ["display-A", "display-B", "display-C"], force: true)?.id == "cosmos")
        precondition(state.displays["display-A"] == state.displays["display-B"] && state.displays["display-B"] == state.displays["display-C"])
        state.shuffle = true
        for _ in 0..<100 {
            let old = state.displays["display-A"]?.desktop.wallpaperID
            let next = state.advance(display: "display-A", force: true)
            precondition(next != nil && next?.id != old)
            precondition(state.advance(display: "display-A", force: true, backwards: true)?.id == old)
        }
        let oldSchema = Data("{\"id\":\"old\",\"title\":\"Old scene\",\"kind\":\"video\",\"tags\":\"\",\"favorite\":false,\"speed\":1,\"volume\":0,\"dimming\":0,\"fit\":false}".utf8)
        let oldWallpaper = try JSONDecoder().decode(Wallpaper.self, from: oldSchema)
        precondition(oldWallpaper.videoEdit == nil && oldWallpaper.metadata == nil)
        state.displays["display-A"] = DisplayAssignment(desktop: SurfaceAssignment(wallpaperID: "aurora"))
        state.displays["display-B"] = DisplayAssignment(desktop: SurfaceAssignment(wallpaperID: "ember"))
        state.remove("ember")
        precondition(state.displays["display-B"] == nil)
        precondition(state.playlists.allSatisfy { !$0.items.contains("ember") })
        let activeID = state.displays["display-A"]!.desktop.wallpaperID!
        state.remove(activeID)
        precondition(state.displays["display-A"] == nil)
        state.displayMode = "perDisplay"
        try disk.save(state)
        let restored = try disk.load()
        precondition(restored.wallpapers == state.wallpapers && restored.playlists == state.playlists && restored.displays == state.displays && restored.displayMode == "perDisplay")
        precondition(disk.url(for: Wallpaper(title: "bad", kind: "video", file: "../../secret")) == nil)
        precondition(disk.url(for: Wallpaper(title: "good", kind: "video", file: "clip.mp4"))!.deletingLastPathComponent() == disk.assets)
        try surfaceAssignmentTests(disk: disk)
        try browsingTests(disk: disk)
        let invalid = Data("not valid json".utf8)
        try invalid.write(to: disk.manifest)
        do { _ = try disk.load(); preconditionFailure("Corrupt library accepted") } catch LibraryError.invalidLibrary {}
        let preserved = try Data(contentsOf: disk.manifest)
        precondition(preserved == invalid)
        state.playlists = [Playlist(id: "empty", name: "Empty")]
        state.displays["display-C"] = DisplayAssignment(desktop: SurfaceAssignment(playlistID: "empty"))
        precondition(state.advance(display: "display-C", force: true) == nil)
        try stillAssetTests(dir.appendingPathComponent("stills-case"))
        try catalogTests(dir.appendingPathComponent("catalog-case"))
        print("PASS: global, per-playlist and mirrored scheduling, 100 shuffle transitions, removal cleanup, persistence, path validation, corrupt-library preservation, empty playlists, still frames, provider catalog")
    }
    static func stillAssetTests(_ root: URL) throws {
        precondition(stillFrameTime(edit: nil, duration: nil) == 0)
        precondition(stillFrameTime(edit: VideoEdit(thumbnail: -2), duration: nil) == 0)
        precondition(stillFrameTime(edit: VideoEdit(thumbnail: 1.5), duration: nil) == 1.5)
        let inside = VideoEdit(start: 0.25, end: 0.75, thumbnail: 0.5)
        precondition(stillFrameTime(edit: inside, duration: 1) == 0.5)
        precondition(stillFrameTime(edit: VideoEdit(start: 0.25, end: 0.75, thumbnail: 0), duration: 1) == 0.25)
        precondition(stillFrameTime(edit: VideoEdit(start: 0.25, end: 0.75, thumbnail: 9), duration: 1) == 0.75 - 1.0 / 600)
        precondition(stillFrameTime(edit: VideoEdit(start: 2, end: 1, thumbnail: 0.2), duration: 5) == 0.2)
        precondition(stillFrameTime(edit: VideoEdit(thumbnail: 9), duration: 1) == 1 - 1.0 / 600)
        var library = LibraryState()
        library.wallpapers = [Wallpaper(id: "clip", title: "Clip", kind: "video", file: "clip.mov", videoEdit: inside)]
        precondition(library.assign("clip", display: "A"))
        library.setMode(.still, display: "A", surface: .desktop)
        library.paused = true
        library.paused = false
        let decoded = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(library))
        precondition(decoded.paused == false && decoded.displays["A"]?.desktop.mode == .still && decoded.displays["A"]?.desktop.wallpaperID == "clip")
        let disk = try LibraryDisk(root: root)
        let source = disk.assets.appendingPathComponent("clip.mov")
        let original = Data("source-bytes".utf8)
        try original.write(to: source)
        precondition(disk.stillFile(id: "../secret") == nil && disk.stillFile(id: "a/b") == nil && disk.stillFile(id: "..") == nil)
        let rejected = try disk.writeStill(id: "../secret", stamp: "video 0.500000", data: Data([1]))
        precondition(rejected == nil)
        let stamp = stillStamp(for: library.item("clip")!)
        let file = try disk.writeStill(id: "clip", stamp: stamp, data: Data([0x89, 0x50, 0x4e, 0x47]))
        precondition(file?.deletingLastPathComponent().lastPathComponent == "Stills")
        precondition(disk.retainedStill(id: "clip", stamp: stamp) == file)
        precondition(disk.retainedStill(id: "clip", stamp: "video 0.000000") == nil)
        let preserved = try Data(contentsOf: source)
        precondition(preserved == original)
        precondition(!FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("secret").path))
    }
    static func catalogTests(_ root: URL) throws {
        let disk = try LibraryDisk(root: root)
        var state = LibraryState()
        state.blockedTags = ["hidden"]
        state.wallpapers = [
            Wallpaper(id: "clip", title: "Clip", kind: "video", file: "clip.mov", speed: 1.5, dimming: 0.25, fit: true,
                      videoEdit: VideoEdit(start: 0.25, end: 0.75, thumbnail: 0.5)),
            Wallpaper(id: "pic", title: "Pic", kind: "image", file: "pic.png"),
            Wallpaper(id: "aurora", title: "Northern lights", kind: "aurora", speed: 0.5, dimming: 0.2),
            Wallpaper(id: "escape", title: "Escape", kind: "video", file: "../secret.mov"),
            Wallpaper(id: "hidden-pic", title: "Hidden", kind: "image", file: "hidden.png", tags: "hidden"),
            Wallpaper(id: "ember", title: "Ember", kind: "ember", tags: "hidden"),
            Wallpaper(id: "plugin", title: "Plugin", kind: "plugin"),
            Wallpaper(id: "bad", title: "Bad", kind: "video", file: "bad.mov", videoEdit: VideoEdit(start: 2, end: 1, thumbnail: 0.2))
        ]
        precondition(state.assign("clip", display: "A"))
        state.setMode(.still, display: "A", surface: .desktop)
        precondition(state.assign("clip", display: "B"))
        state.setMode(.still, display: "B", surface: .desktop)
        precondition(state.assign("clip", display: "A", surface: .lockScreen))
        precondition(state.assign("pic", display: "C", surface: .lockScreen))
        state.setMode(.still, display: "C", surface: .lockScreen)
        precondition(state.assign("pic", display: "D"))
        state.setMode(.still, display: "D", surface: .desktop)
        precondition(state.assign("pic", display: "E"))
        state.setMode(.animated, display: "E", surface: .desktop)
        precondition(state.assign("aurora", display: "F"))
        state.setMode(.still, display: "F", surface: .desktop)
        let catalog = providerCatalog(from: state)
        precondition(catalog == ProviderCatalog(items: [
            .init(id: "clip", title: "Clip", kind: "video", file: "Media/clip.mov", fit: "fit", speed: 1.5, dimming: 0.25,
                  trimStart: 0.25, trimEnd: 0.75, still: 0.5, desktop: .still, lockScreen: .animated),
            .init(id: "pic", title: "Pic", kind: "image", file: "Media/pic.png", fit: "fill", lockScreen: .still),
            .init(id: "aurora", title: "Northern lights", kind: "aurora", file: "", fit: "fill", speed: 0.5, dimming: 0.2,
                  still: 7, desktop: .still, lockScreen: .animated),
            .init(id: "bad", title: "Bad", kind: "video", file: "Media/bad.mov", fit: "fill", still: 0.2)
        ]))
        try disk.save(state)
        let saved = try JSONDecoder().decode(ProviderCatalog.self, from: Data(contentsOf: disk.catalog))
        precondition(saved == catalog)
        try Data("broken".utf8).write(to: disk.manifest)
        do { _ = try disk.load(); preconditionFailure("Corrupt library accepted") } catch LibraryError.invalidLibrary {}
        let preserved = try JSONDecoder().decode(ProviderCatalog.self, from: Data(contentsOf: disk.catalog))
        precondition(preserved == catalog)
    }
    static func surfaceAssignmentTests(disk: LibraryDisk) throws {
        let start = Date(timeIntervalSinceReferenceDate: 42)
        let oldData = Data(#"{"wallpaperID":"ocean","playlistID":"ambient","index":1,"changedAt":42,"history":["aurora","missing"]}"#.utf8)
        let legacy = try JSONDecoder().decode(DisplayAssignment.self, from: oldData)
        precondition(legacy.desktop == SurfaceAssignment(wallpaperID: "ocean", playlistID: "ambient", index: 1,
                                                         changedAt: start, history: ["aurora", "missing"]))
        precondition(legacy.lockScreen == nil && !legacy.surfacesLinked && legacy.desktop.mode == .animated)
        var oldLibrary = try JSONSerialization.jsonObject(with: JSONEncoder().encode(LibraryState.initial)) as! [String: Any]
        oldLibrary["displays"] = ["saved-display-UUID": try JSONSerialization.jsonObject(with: oldData)]
        try JSONSerialization.data(withJSONObject: oldLibrary).write(to: disk.manifest)
        let loadedLegacy = try disk.load()
        precondition(loadedLegacy.displays["saved-display-UUID"] == legacy)

        var state = LibraryState.initial
        state.displays["A"] = DisplayAssignment(
            desktop: SurfaceAssignment(wallpaperID: "ocean", playlistID: "ambient", index: 1,
                                       changedAt: start, history: ["aurora"], mode: .still),
            lockScreen: SurfaceAssignment(wallpaperID: "ember", changedAt: start))
        state.setSurfacesLinked(true, display: "A")
        precondition(state.displays["A"]?.lockScreen == state.displays["A"]?.desktop)
        precondition(state.displays["A"]?.lockScreen?.history == ["aurora"])
        state.assign("cosmos", display: "A", surface: .lockScreen, now: start)
        precondition(state.displays["A"]?.desktop.wallpaperID == "cosmos")
        precondition(state.displays["A"]?.desktop.mode == .still && state.displays["A"]?.surfacesLinked == true)
        state.setMode(.animated, display: "A", surface: .lockScreen)
        precondition(state.displays["A"]?.desktop.mode == .animated && state.displays["A"]?.lockScreen?.mode == .animated)
        let linked = state.displays["A"]!
        state.setSurfacesLinked(false, display: "A")
        precondition(state.displays["A"]?.desktop == linked.desktop && state.displays["A"]?.lockScreen == linked.lockScreen)
        state.assign("ember", display: "A", surface: .lockScreen, now: start)
        state.setMode(.still, display: "A", surface: .lockScreen)
        precondition(state.displays["A"]?.desktop == linked.desktop && state.displays["A"]?.lockScreen?.wallpaperID == "ember")
        precondition(state.displays["A"]?.lockScreen?.mode == .still)
        let unchanged = state.displays
        precondition(!state.assign("missing", display: "A"))
        precondition(!state.assign("aurora", display: "A", playlistID: "missing"))
        precondition(state.displays == unchanged)

        state.playlists.append(Playlist(id: "fast", name: "Fast", items: ["missing", "ember", "cosmos"], interval: 60, shuffle: false))
        state.assign("aurora", display: "A", playlistID: "ambient", now: start)
        state.assign("ember", display: "A", surface: .lockScreen, playlistID: "fast", now: start)
        let desktop = state.displays["A"]!.desktop
        precondition(state.advance(display: "A", surface: .lockScreen, now: start.addingTimeInterval(59)) == nil)
        precondition(state.advance(display: "A", surface: .lockScreen, now: start.addingTimeInterval(60))?.id == "cosmos")
        precondition(state.displays["A"]?.desktop == desktop && state.displays["A"]?.lockScreen?.history == ["ember"])
        precondition(state.displays["A"]?.lockScreen?.mode == .still)
        precondition(state.advance(display: "A", surface: .lockScreen, now: start.addingTimeInterval(61), force: true, backwards: true)?.id == "ember")
        let lockScreen = state.displays["A"]!.lockScreen
        precondition(state.advance(display: "A", now: start.addingTimeInterval(299)) == nil)
        precondition(state.advance(display: "A", now: start.addingTimeInterval(300))?.id == "ocean")
        precondition(state.displays["A"]?.lockScreen == lockScreen)
        state.setSurfacesLinked(true, display: "A")
        precondition(state.advance(display: "A", surface: .lockScreen, now: start.addingTimeInterval(301), force: true)?.id == "cosmos")
        precondition(state.displays["A"]?.desktop == state.displays["A"]?.lockScreen)
        precondition(state.displays["A"]?.desktop.history == ["aurora", "ocean"])

        state.displays["disconnected-UUID"] = DisplayAssignment(
            desktop: SurfaceAssignment(wallpaperID: "ember", changedAt: start, mode: .still),
            lockScreen: SurfaceAssignment(wallpaperID: "aurora", changedAt: start))
        let disconnected = state.displays["disconnected-UUID"]
        state.displays["B"] = DisplayAssignment(desktop: SurfaceAssignment(wallpaperID: "ember", changedAt: start))
        precondition(state.synchronizeMirrored(displayIDs: ["B", "A", "C"], preferredSource: "A")?.id == "cosmos")
        precondition(state.displays["A"] == state.displays["B"] && state.displays["B"] == state.displays["C"])
        precondition(state.displays["B"]?.surfacesLinked == true && state.displays["disconnected-UUID"] == disconnected)
        precondition(state.advanceMirrored(displayIDs: ["A", "B", "C"], surface: .lockScreen,
                                          now: start.addingTimeInterval(302), force: true)?.id == "ember")
        precondition(state.displays["A"] == state.displays["C"] && state.displays["A"]?.desktop == state.displays["A"]?.lockScreen)
        state.setSurfacesLinked(false, display: "A")
        state.assign("aurora", display: "A", surface: .lockScreen, now: start)
        state.setMode(.still, display: "A", surface: .lockScreen)
        precondition(state.synchronizeMirrored(displayIDs: ["A", "B", "C"], surface: .lockScreen)?.id == "aurora")
        precondition(state.displays["A"] == state.displays["B"] && state.displays["B"] == state.displays["C"])
        precondition(state.displays["B"]?.surfacesLinked == false && state.displays["B"]?.lockScreen?.mode == .still)

        state.stop(display: "A", now: start)
        precondition(state.displays["A"]?.desktop.wallpaperID == nil && state.displays["A"]?.lockScreen?.wallpaperID == "aurora")
        precondition(state.synchronizeMirrored(displayIDs: ["A", "new-display-UUID"], preferredSource: "A") == nil)
        precondition(state.displays["A"] == state.displays["new-display-UUID"])
        let saved = state.displays
        try disk.save(state)
        state = try disk.load()
        precondition(state.displays == saved && state.displays["disconnected-UUID"] == disconnected)
        precondition(state.synchronizeMirrored(displayIDs: ["disconnected-UUID", "reconnected-UUID"], preferredSource: "disconnected-UUID")?.id == "ember")
        precondition(state.displays["reconnected-UUID"] == disconnected)
        state.stop(display: "A", surface: .lockScreen, now: start)
        precondition(state.displays["A"]?.lockScreen?.wallpaperID == nil && state.displays["A"]?.lockScreen?.mode == .still)
        state.assign("ocean", display: "A", surface: .lockScreen, now: start)
        precondition(state.displays["A"]?.lockScreen?.mode == .still)
        state.setSurfacesLinked(true, display: "B")
        state.stop(display: "B", surface: .lockScreen, now: start)
        precondition(state.displays["B"]?.desktop.wallpaperID == nil && state.displays["B"]?.lockScreen?.wallpaperID == nil)
        precondition(state.displays["B"]?.surfacesLinked == true)

        state = .initial
        state.assign("aurora", display: "A", playlistID: "ambient", now: start)
        state.assign("ember", display: "A", surface: .lockScreen, playlistID: "ambient", now: start)
        state.setMode(.still, display: "A", surface: .lockScreen)
        state.removePlaylist("ambient")
        precondition(state.displays["A"]?.desktop.playlistID == nil && state.displays["A"]?.lockScreen?.playlistID == nil)
        precondition(state.displays["A"]?.desktop.wallpaperID == "aurora" && state.displays["A"]?.lockScreen?.wallpaperID == "ember")
        state.remove("aurora")
        precondition(state.displays["A"]?.desktop.wallpaperID == nil && state.displays["A"]?.lockScreen?.wallpaperID == "ember")
        state.remove("ember")
        precondition(state.displays["A"]?.lockScreen?.wallpaperID == nil && state.displays["A"]?.lockScreen?.mode == .still)
        state = .initial
        state.displays["A"] = DisplayAssignment(
            desktop: SurfaceAssignment(wallpaperID: "ocean", playlistID: "ambient", index: 1,
                                       changedAt: start, history: ["aurora", "ember"]),
            lockScreen: SurfaceAssignment(wallpaperID: "cosmos", changedAt: start, history: ["aurora"]))
        state.remove("aurora")
        precondition(state.displays["A"]?.desktop.index == 0 && state.displays["A"]?.desktop.history == ["ember"])
        precondition(state.displays["A"]?.lockScreen?.history == [])
        state.setSurfacesLinked(true, display: "A")
        state.remove("ocean")
        precondition(state.displays["A"]?.desktop.wallpaperID == nil && state.displays["A"]?.lockScreen?.wallpaperID == nil)

        var malformed = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        var nested = malformed["desktop"] as! [String: Any]
        nested["mode"] = "unsupported"
        malformed["desktop"] = nested
        do {
            _ = try JSONDecoder().decode(DisplayAssignment.self, from: JSONSerialization.data(withJSONObject: malformed))
            preconditionFailure("Unknown surface mode accepted")
        } catch is DecodingError {}
        state = .initial
        state.displays["A"] = DisplayAssignment(desktop: SurfaceAssignment(playlistID: "ambient", index: -100, changedAt: start))
        precondition(state.advance(display: "A", now: start, force: true, backwards: true)?.id == "ember")
        print("PASS: legacy surface migration, linked/independent assignments and modes, per-surface playlists/history, mirrored pairs, disconnected display restoration, stopping, removal and persistence")
    }
    static func browsingTests(disk: LibraryDisk) throws {
        precondition(normalizedTags(" Nature, , NATURE, natural, BLUE ") == ["nature", "natural", "blue"])
        var old = LibraryState.initial
        for i in old.wallpapers.indices { old.wallpapers[i].metadata = nil }
        old.wallpapers.append(Wallpaper(id: "legacy", title: "Existing import", kind: "video", file: "retained.mov",
                                       videoEdit: VideoEdit(start: 1, end: 3), metadata: SceneMetadata(details: "Original", category: "Custom")))
        old.playlists[0].items.append("legacy")
        old.displays["saved-display"] = DisplayAssignment(desktop: SurfaceAssignment(wallpaperID: "legacy", playlistID: "ambient", index: 4,
                                                         changedAt: Date(timeIntervalSince1970: 1000), history: ["ocean", "aurora"]))
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        object.removeValue(forKey: "blockedTags")
        let legacy = try JSONDecoder().decode(LibraryState.self, from: JSONSerialization.data(withJSONObject: object))
        precondition(legacy.blockedTags.isEmpty && legacy.wallpapers == old.wallpapers && legacy.playlists == old.playlists && legacy.displays == old.displays)
        let date = Date(timeIntervalSince1970: 123456)
        var state = LibraryState()
        let video = Wallpaper(id: "video", title: "A video", kind: "video", file: "source.mp4", tags: "Nature, ocean", favorite: true,
                              videoEdit: VideoEdit(start: 2, end: 7), metadata: SceneMetadata(category: "Nature", color: "Blue", motion: "Low"),
                              mediaFacts: MediaFacts(width: 3840, height: 2160, bytes: 1234, sourceDuration: 10), dateAdded: date)
        let image = Wallpaper(id: "image", title: "B image", kind: "image", file: "image.png", tags: "natural, red",
                              metadata: SceneMetadata(category: "Abstract", color: "Red", motion: "High"), mediaFacts: MediaFacts(width: 2560, height: 1080))
        let unknown = Wallpaper(id: "unknown", title: "C unknown", kind: "ocean", tags: " Nature, RED ")
        state.wallpapers = [video, image, unknown]
        state.playlists = [Playlist(id: "ordered", name: "Order", items: ["unknown", "image", "video"])]
        state.displays = ["display": DisplayAssignment(desktop: SurfaceAssignment(wallpaperID: "video", playlistID: "ordered", index: 2, history: ["image"]))]
        var filter = LibraryFilter()
        filter.tags = ["nature"]
        precondition(state.browsing(section: "all", filter: filter).map(\.id) == ["video", "unknown"])
        filter.colors = ["Blue", "Unknown"]
        filter.categories = ["nature", "Unknown"]
        filter.motions = ["Low", "Unknown"]
        precondition(state.browsing(section: "all", filter: filter).map(\.id) == ["video", "unknown"])
        filter.resolutions = ["4K+"]
        filter.aspects = ["Standard"]
        precondition(state.browsing(section: "all", filter: filter).map(\.id) == ["video"])
        precondition(state.browsing(section: "all", query: "missing", filter: filter).isEmpty)
        filter.kind = "still"
        precondition(state.browsing(section: "all", filter: filter).isEmpty)
        filter = LibraryFilter()
        precondition(filter.activeCount == 0)
        precondition(state.browsing(section: "all", filter: filter).count == 3)
        precondition(state.browsing(section: "favorites").map(\.id) == ["video"])
        precondition(state.browsing(section: "imports").map(\.id) == ["video", "image"])
        precondition(state.browsing(section: "playlist:ordered", sort: "favorites").map(\.id) == ["unknown", "image", "video"])
        filter.tags = ["red", "OCEAN"]
        precondition(state.browsing(section: "all", filter: filter).count == 3)
        filter = LibraryFilter()
        filter.resolutions = ["Unknown"]
        filter.aspects = ["Unknown"]
        filter.colors = ["Unknown"]
        filter.motions = ["Unknown"]
        precondition(state.browsing(section: "all", filter: filter).map(\.id) == ["unknown"])
        precondition(video.editedDuration == 5 && image.editedDuration == nil)
        var invalidVideo = video
        invalidVideo.videoEdit?.start = 11
        precondition(invalidVideo.editedDuration == nil)
        for (width, height, resolution, aspect) in [
            (1279, 720, "Below 720p", "Standard"), (1280, 720, "720p", "Standard"),
            (1920, 1080, "1080p", "Standard"), (2560, 1440, "1440p", "Standard"),
            (2160, 3840, "4K+", "Portrait"), (3840, 1080, "1080p", "Ultrawide"),
            (100, 100, "Below 720p", "Square"), (200, 100, "Below 720p", "Ultrawide")
        ] {
            let facts = MediaFacts(width: width, height: height)
            precondition(facts.resolution == resolution && facts.aspect == aspect)
        }
        precondition(MediaFacts(width: -1, height: 100).resolution == "Unknown")
        precondition(MediaFacts().aspect == "Unknown")
        precondition(classifiedColor(red: 1, green: 0, blue: 0) == "Red")
        precondition(classifiedColor(red: 0, green: 0, blue: 1) == "Blue")
        precondition(classifiedColor(red: 0, green: 1, blue: 0) == "Green")
        precondition(classifiedColor(red: 0.5, green: 0.5, blue: 0.5) == "Neutral")
        state.blockedTags = [" NATURE ", "nature", "red"]
        for section in ["discover", "browse", "all", "favorites", "imports", "playlist:ordered"] {
            precondition(state.browsing(section: section).isEmpty)
        }
        let assignments = state.displays, playlists = state.playlists
        try disk.save(state)
        var restored = try disk.load()
        precondition(restored.blockedTags == ["nature", "red"] && restored.wallpapers == state.wallpapers)
        precondition(restored.displays == assignments && restored.playlists == playlists)
        restored.blockedTags = []
        precondition(restored.browsing(section: "playlist:ordered").map(\.id) == ["unknown", "image", "video"])
        precondition(restored.item("video")?.dateAdded == date && restored.item("video")?.mediaFacts?.sourceDuration == 10)
        print("PASS: legacy metadata and blocked tags, media facts roundtrip, filter combinations/Unknown/reset, exact tags, buckets, color classification, playlist order, blocking and unblocking without assignment changes")
    }

}
