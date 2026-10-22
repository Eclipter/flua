import Foundation

// Standalone `swiftc` executables do not synthesize `Bundle.module`; provide a
// test-only stand-in so the rendering types Library.swift references can
// type-check. This stand-in is never exercised by the test below (no scene
// thumbnail is generated while clearing filters).
extension Bundle {
    static var module: Bundle { Bundle.main }
}

@main struct ClearFiltersSortTests {
    @MainActor
    static func main() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FluaClearFiltersSortTest-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let support = dir.appendingPathComponent("ApplicationSupport", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let root = LibraryPaths.resolve(applicationSupport: support)

        let library = try Library(root: root, systemPlaybackEnabled: false)
        let originalState = library.state
        let originalSavedState = try LibraryDisk(root: root).load()

        library.setPlaybackMode("perDisplay")
        library.surface = .desktop
        library.setSurfaceMode(.still)
        library.surface = .lockScreen
        library.setSurfaceMode(.animated)
        library.surface = .desktop

        var wallpaperDraft = library.selected!
        wallpaperDraft.fit = true
        wallpaperDraft.speed = 1.5
        wallpaperDraft.dimming = 0.3
        library.editConfiguration(wallpaperDraft)
        precondition(library.selected?.fit == true)
        precondition(library.selected?.speed == 1.5)
        precondition(library.selected?.dimming == 0.3)
        precondition(library.state.wallpapers == originalState.wallpapers)
        precondition(library.state.displays == originalState.displays)
        precondition(library.state.displayMode == originalState.displayMode, "configuration edits changed saved display mode before Set Wallpapers")
        let savedStateBeforeApply = try LibraryDisk(root: root).load()
        precondition(savedStateBeforeApply.wallpapers == originalSavedState.wallpapers)
        precondition(savedStateBeforeApply.displays == originalSavedState.displays)
        precondition(savedStateBeforeApply.displayMode == originalSavedState.displayMode, "configuration edits reached disk before Set Wallpapers")

        let displayIDs = library.screens.map(displayID)
        precondition(!displayIDs.isEmpty, "configuration apply regression requires a connected display")
        let selectedID = library.selected!.id
        library.display = displayIDs[0]
        library.applySelected()
        precondition(library.state.item(selectedID)?.fit == true)
        precondition(library.state.item(selectedID)?.speed == 1.5)
        precondition(library.state.item(selectedID)?.dimming == 0.3)
        precondition(library.state.displays[displayIDs[0]]?.desktop.wallpaperID == selectedID)
        precondition(library.state.displays[displayIDs[0]]?.desktop.mode == .still)
        precondition(library.state.displays[displayIDs[0]]?.lockScreen == nil)
        for id in displayIDs.dropFirst() {
            precondition(library.state.displays[id] == nil, "Per Display Apply changed an unselected display: \(id)")
        }
        let committedState = try LibraryDisk(root: root).load()
        precondition(committedState.item(selectedID)?.fit == true)
        for id in displayIDs {
            precondition(committedState.displays[id]?.desktop.wallpaperID == (id == displayIDs[0] ? selectedID : nil))
            precondition(committedState.displays[id]?.lockScreen == nil)
        }

        library.state.assign("ember", display: displayIDs[0], surface: .desktop)
        library.state.setMode(.still, display: displayIDs[0], surface: .desktop)
        library.surface = .lockScreen
        library.selection = "ocean"
        library.setSurfaceMode(.still)
        library.applySelected()
        precondition(library.state.displays[displayIDs[0]]?.desktop.wallpaperID == "ember")
        precondition(library.state.displays[displayIDs[0]]?.lockScreen?.wallpaperID == "ocean")
        precondition(library.state.displays[displayIDs[0]]?.lockScreen?.mode == .still)

        library.surface = .desktop
        library.setSurfacesLinked(true)
        library.selection = "aurora"
        library.applySelected()
        precondition(library.state.displays[displayIDs[0]]?.desktop.wallpaperID == "aurora")
        precondition(library.state.displays[displayIDs[0]]?.lockScreen == library.state.displays[displayIDs[0]]?.desktop)

        library.setPlaybackMode("mirrored")
        library.setSurfacesLinked(false)
        library.selection = "cosmos"
        library.applySelected()
        for id in displayIDs {
            precondition(library.state.displays[id]?.desktop.wallpaperID == "cosmos")
        }
        library.setPlaybackMode("perDisplay")
        library.display = displayIDs[0]
        library.surface = .desktop
        library.applySelected()
        let beforeMissingTarget = library.state.displays
        library.display = "not-connected"
        library.applySelected()
        precondition(library.state.displays == beforeMissingTarget, "Per Display Apply fell back to a connected display")
        library.display = displayIDs[0]

        let firstDisplay = displayIDs[0]
        let otherDisplay = displayIDs.dropFirst().first ?? firstDisplay
        library.state.playlists.append(Playlist(id: "target-probe", name: "Target probe", items: ["ember", "cosmos"]))
        library.save()
        library.updatePlaylist("ambient", shuffle: false)
        library.display = firstDisplay
        library.startPlaylist("ambient")
        precondition(library.state.displays[firstDisplay]?.desktop.wallpaperID == "aurora")
        library.setPlaybackMode("mirrored")
        precondition(library.state.displayMode == "perDisplay")
        precondition(library.playbackMode == "mirrored")
        library.advancePlaylists(force: true)
        precondition(library.state.displayMode == "perDisplay")
        precondition(library.state.displays[firstDisplay]?.desktop.wallpaperID == "ocean")
        if otherDisplay != firstDisplay {
            precondition(library.state.displays[otherDisplay]?.desktop.wallpaperID == "cosmos")
        }
        library.display = otherDisplay
        library.startPlaylist("target-probe")
        precondition(library.state.displayMode == "perDisplay")
        precondition(library.playbackMode == "mirrored")
        if otherDisplay != firstDisplay {
            precondition(library.state.displays[firstDisplay]?.desktop.wallpaperID == "ocean")
            precondition(library.state.displays[otherDisplay]?.desktop.wallpaperID == "ember")
            precondition(library.state.displays[otherDisplay]?.desktop.playlistID == "target-probe")
        } else {
            precondition(library.state.displays[firstDisplay]?.desktop.wallpaperID == "ember")
            precondition(library.state.displays[firstDisplay]?.desktop.playlistID == "target-probe")
        }

        library.applySelected()
        library.display = otherDisplay
        library.setPlaybackMode("perDisplay")
        library.startPlaylist("target-probe")
        precondition(library.state.displayMode == "mirrored")
        precondition(library.playbackMode == "perDisplay")
        for id in displayIDs {
            precondition(library.state.displays[id]?.desktop.wallpaperID == "ember")
            precondition(library.state.displays[id]?.desktop.playlistID == "target-probe")
        }

        library.applySelected()
        library.setPlaybackMode("perDisplay")
        library.display = firstDisplay
        library.applySelected()
        library.state.shuffle = false
        library.startPlaylist("ambient")
        library.surface = .lockScreen
        library.setSurfaceMode(.still)
        library.advancePlaylists(force: true)
        let currentDesktop = library.state.displays[firstDisplay]!.desktop
        precondition(library.surfaceSummary(.desktop).contains("Quiet tides"), "draft summary used old playlist position")
        library.selection = "cosmos"
        library.applySelected()
        precondition(library.state.displays[firstDisplay]?.desktop == currentDesktop, "applying Lock Screen settings rewound desktop playlist")
        library.setSurfaceMode(.animated)
        library.remove(library.state.item("ocean")!)
        library.selection = "ember"
        library.applySelected()
        precondition(library.state.displays[firstDisplay]?.desktop.wallpaperID == nil, "applying settings restored removed wallpaper")
        library.surface = .desktop
        print("PASS: applying pending configuration preserves playlist advancement and removed assignments")

        library.browseSort = "recent"
        library.filter.tags = ["nature"]
        library.query = "something"
        library.clearFilters()
        precondition(library.browseSort == "name")
        precondition(library.filter.activeCount == 0)
        precondition(library.query.isEmpty)
        for sort in ["favorites", "recent"] {
            library.browseSort = sort
            library.clearFilters()
            precondition(library.browseSort == "name", "clearFilters did not reset \(sort) sort to name; got \(library.browseSort)")
            precondition(library.filter.activeCount == 0, "clearFilters did not reset filter after \(sort)")
            precondition(library.query == "", "clearFilters did not reset query after \(sort)")
        }
        library.state.assign("aurora", display: firstDisplay)
        library.state.nativePlayback[firstDisplay] = true
        library.state.assign("aurora", display: "disconnected")
        library.state.nativePlayback["disconnected"] = true
        library.remove(library.state.item("aurora")!)
        precondition(library.state.nativeCleanupDisplays.contains(firstDisplay))
        let removedState = try LibraryDisk(root: root).load()
        precondition(removedState.nativeCleanupDisplays.contains(firstDisplay), "Removal cleanup must survive an interrupted refresh")
        precondition(removedState.nativeCleanupDisplays.contains("disconnected"), "Disconnected displays must retain pending cleanup")
        print("PASS: active wallpaper removal persists pending native cleanup")
        print("PASS: clearFilters resets filters, query, and sort type to default (name) with only sorting changed (favorites/recent)")
    }
}
