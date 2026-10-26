import Foundation
import AVFoundation
import CoreGraphics
import CoreVideo
import Dispatch
import AppKit
import ImageIO
import UniformTypeIdentifiers

// Standalone `swiftc` executables do not synthesize `Bundle.module`; provide a
// test-only stand-in so the rendering types Library.swift references can
// type-check. This stand-in is never exercised by the test below (no scene
// thumbnail is generated while clearing filters).
extension Bundle {
    static var module: Bundle { Bundle.main }
}

@main struct ClearFiltersSortTests {
    @MainActor
    static func waitForNativePublication(_ library: Library) async {
        let deadline = Date().addingTimeInterval(20)
        while library.nativeSetupBusy && Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        precondition(!library.nativeSetupBusy, "Native catalog publication timed out")
    }

    @MainActor
    static func saveCommitTests(_ root: URL) async throws {
        let library = try Library(root: root, systemPlaybackEnabled: false)
        library.tick?.invalidate()
        for screen in library.screens { library.state.assign("aurora", display: displayID(screen)) }
        precondition(library.save())
        await library.finishCatalogWrites()
        let original = library.state.item("aurora")!
        let selection = library.selection
        var edited = original
        edited.title = "Committed despite catalog failure"
        try FileManager.default.removeItem(at: library.disk.catalog)
        try FileManager.default.createDirectory(at: library.disk.catalog, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: library.disk.catalog.appendingPathComponent("blocker"))
        precondition(library.edit(edited), "catalog failure rolled back a committed edit")
        await library.finishCatalogWrites()
        precondition(library.state.item(edited.id) == edited)
        let reloaded = try LibraryDisk(root: root).load()
        precondition(reloaded.item(edited.id) == edited, "memory and reloaded library disagree")
        precondition(library.selection == selection)
        precondition(library.error?.contains("Library saved") == true, "catalog failure was not reported separately")
        let activity = library.activity
        library.applySavedNativeAssignments()
        await waitForNativePublication(library)
        precondition(library.activity == activity, "native application proceeded without a current catalog")
        try FileManager.default.removeItem(at: library.disk.catalog)
        precondition(library.save(), "catalog retry failed")
        await library.finishCatalogWrites()
        let catalog = try JSONDecoder().decode(ProviderCatalog.self, from: Data(contentsOf: library.disk.catalog))
        precondition(catalog.items.first { $0.id == edited.id }?.title == edited.title)

        let committedManifest = try Data(contentsOf: library.disk.manifest)
        try FileManager.default.removeItem(at: library.disk.manifest)
        try FileManager.default.createDirectory(at: library.disk.manifest, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: library.disk.manifest.appendingPathComponent("blocker"))
        var rejected = edited
        rejected.title = "Must not commit"
        precondition(!library.edit(rejected), "manifest failure was treated as committed")
        precondition(library.state.item(edited.id) == edited)
        precondition(library.selection == selection)
        precondition(library.error != nil)
        let unchangedCatalog = try JSONDecoder().decode(ProviderCatalog.self, from: Data(contentsOf: library.disk.catalog))
        precondition(unchangedCatalog == catalog, "manifest failure changed the catalog")
        try FileManager.default.removeItem(at: library.disk.manifest)
        try committedManifest.write(to: library.disk.manifest, options: .atomic)
        let restored = try LibraryDisk(root: root).load()
        precondition(restored.item(edited.id) == library.state.item(edited.id))
        print("PASS: catalog failure commits memory and disk, retries publication, and manifest failure rolls back edits")
    }

    @MainActor
    static func largeCatalogSaveTests(_ root: URL) async throws {
        let library = try Library(root: root, systemPlaybackEnabled: false)
        library.tick?.invalidate()
        // Let startup publish its own thumbnails before replacing this disposable library.
        try await Task.sleep(for: .milliseconds(250))
        await library.finishCatalogWrites()
        let image = AmbientSceneView.thumbnail(scene: "aurora", size: NSSize(width: 480, height: 270))
        let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let jpeg = NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [.compressionFactor: 0.8])!
        let thumbnail = "data:image/jpeg;base64," + jpeg.base64EncodedString()
        library.state.wallpapers = (0..<1000).map {
            Wallpaper(id: "scene-\($0)", title: "Scene \($0)", kind: "aurora")
        }
        library.disk.thumbnails = Dictionary(uniqueKeysWithValues: library.state.wallpapers.map { ($0.id, thumbnail) })
        let clock = ContinuousClock()
        var start = clock.now
        precondition(library.save())
        let firstSave = start.duration(to: clock.now)
        var ticks = 0
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                ticks += 1
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        await library.finishCatalogWrites()
        heartbeat.cancel()
        precondition(ticks > 0, "UI executor made no progress during changed catalog encoding")
        let catalog = try Data(contentsOf: library.disk.catalog)
        let identity = try FileManager.default.attributesOfItem(atPath: library.disk.catalog.path) as NSDictionary
        library.state.wallpapers[0].favorite.toggle()
        start = clock.now
        precondition(library.save())
        let favoriteSave = start.duration(to: clock.now)
        await library.finishCatalogWrites()
        let favoriteCatalog = try Data(contentsOf: library.disk.catalog)
        precondition(favoriteCatalog == catalog, "favorite changed catalog contents")
        let afterFavorite = try FileManager.default.attributesOfItem(atPath: library.disk.catalog.path) as NSDictionary
        precondition(afterFavorite == identity, "favorite rewrote catalog")
        print("BENCHMARK: Library.save 1000 real aurora thumbnails, JPEG \(jpeg.count) bytes, catalog \(catalog.count) bytes; changed save \(firstSave), favorite save \(favoriteSave), main actor ticks \(ticks)")
    }

    @MainActor
    static func catalogDrainTests(_ root: URL) async throws {
        let library = try Library(root: root, systemPlaybackEnabled: false)
        library.tick?.invalidate()
        await library.finishCatalogWrites()
        let releaseWriter = DispatchSemaphore(value: 0)
        let secondReached = DispatchSemaphore(value: 0)
        let releaseSecond = DispatchSemaphore(value: 0)
        var drained = false
        library.disk.publishCatalog(library.state) { _ in releaseWriter.wait() }
        Task { @MainActor in
            library.disk.publishCatalog(library.state) { _ in
                secondReached.signal()
                releaseSecond.wait()
            }
            library.state.wallpapers[0].title = "Committed while draining"
            precondition(library.save())
            releaseWriter.signal()
        }
        let controller = Task { @MainActor in
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    secondReached.wait()
                    continuation.resume()
                }
            }
            try? await Task.sleep(for: .milliseconds(20))
            precondition(!drained, "drain returned with the newer save still blocked")
            releaseSecond.signal()
        }
        await library.finishCatalogWrites()
        drained = true
        await controller.value
        let catalog = try JSONDecoder().decode(ProviderCatalog.self, from: Data(contentsOf: library.disk.catalog))
        precondition(catalog.items.first?.title == "Committed while draining", "drain dropped a save queued during suspension")
        print("PASS: catalog drain includes saves committed while waiting")
    }

    @MainActor
    static func stopRoutingFailureTests(_ root: URL) throws {
        let files = FileManager.default
        let testBundle = URL(fileURLWithPath: files.currentDirectoryPath).appendingPathComponent("build/tests", isDirectory: true)
        precondition(Bundle.main.bundleURL.resolvingSymlinksInPath() == testBundle.resolvingSymlinksInPath(),
            "Stop routing fixtures must stay inside this worktree’s standalone test directory")
        let contents = Bundle.main.bundleURL.appendingPathComponent("Contents", isDirectory: true)
        precondition(!files.fileExists(atPath: contents.path), "Stop routing fixtures require a standalone test bundle")
        defer { try? files.removeItem(at: contents) }
        let library = try Library(root: root)
        library.tick?.invalidate()
        let ids = library.screens.map(displayID)
        precondition(!ids.isEmpty, "Stop routing regression requires a connected display")
        for id in ids {
            library.state.assign("aurora", display: id)
            library.state.nativePlayback[id] = true
        }
        try library.disk.save(library.state)
        let before = library.state
        let saved = try Data(contentsOf: library.disk.catalog)
        let activity = library.activity
        precondition(!NativeWallpaper.available)
        library.stop()
        precondition(library.error == NativeWallpaper.explanation, "Unavailable provider must report Stop failure")
        precondition(library.state.displays == before.displays && library.state.nativePlayback == before.nativePlayback)
        precondition(library.activity == activity, "Failed Stop must not report success")
        let savedAfterUnavailable = try Data(contentsOf: library.disk.catalog)
        precondition(savedAfterUnavailable == saved)

        try files.createDirectory(at: NativeWallpaper.extensionURL, withIntermediateDirectories: true)
        try files.createDirectory(at: NativeWallpaper.guardURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: NativeWallpaper.guardURL)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: NativeWallpaper.guardURL.path)
        precondition(NativeWallpaper.available, "Catalog mismatch regression requires an available provider fixture")
        precondition(NativeWallpaper.catalogURL.resolvingSymlinksInPath() != library.disk.catalog.resolvingSymlinksInPath())
        library.error = nil
        library.stop()
        precondition(library.error?.contains("different library") == true, "Mismatched catalog must report Stop failure")
        precondition(library.state.displays == before.displays && library.state.nativePlayback == before.nativePlayback)
        precondition(library.activity == activity)
        let savedAfterMismatch = try Data(contentsOf: library.disk.catalog)
        precondition(savedAfterMismatch == saved)

        let isolated = try Library(root: root, systemPlaybackEnabled: false)
        isolated.tick?.invalidate()
        isolated.stop()
        precondition(isolated.error == nil, "Isolated Stop must bypass native routing safely")
        precondition(ids.allSatisfy { isolated.state.nativePlayback[$0] == false })
        precondition(isolated.activity.contains("stopped"))
        print("PASS: Stop preserves playback intent on unavailable providers and catalog mismatches; isolated Stop stays local")
    }

    @MainActor
    static func main() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FluaClearFiltersSortTest-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let support = dir.appendingPathComponent("ApplicationSupport", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let root = LibraryPaths.resolve(applicationSupport: support)
        try await saveCommitTests(dir.appendingPathComponent("save-commit", isDirectory: true))
        try await catalogDrainTests(dir.appendingPathComponent("catalog-drain", isDirectory: true))
        try await largeCatalogSaveTests(dir.appendingPathComponent("large-catalog", isDirectory: true))
        try await importImageDecoderTests(dir.appendingPathComponent("image-import", isDirectory: true))
        try await importReferenceMovieTests(dir.appendingPathComponent("video-import", isDirectory: true))
        try await sourceDownloadDuplicateTests(dir.appendingPathComponent("online-download-import", isDirectory: true))

        try stopRoutingFailureTests(dir.appendingPathComponent("stop-routing", isDirectory: true))

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
        let blockedPlaylistRoot = root.appendingPathComponent("BlockedPlaylist", isDirectory: true)
        let blockedPlaylistDisk = try LibraryDisk(root: blockedPlaylistRoot)
        var blockedPlaylistState = LibraryState.initial
        blockedPlaylistState.displayMode = "perDisplay"
        blockedPlaylistState.shuffle = false
        blockedPlaylistState.playlists[0].interval = 60
        try blockedPlaylistDisk.save(blockedPlaylistState)
        let blockedPlaylistLibrary = try Library(root: blockedPlaylistRoot, systemPlaybackEnabled: false)
        blockedPlaylistLibrary.tick?.invalidate()
        blockedPlaylistLibrary.display = displayIDs[0]
        blockedPlaylistLibrary.blockTags("nature")
        let savedSlowMornings = blockedPlaylistLibrary.state.playlists[0]
        blockedPlaylistLibrary.startPlaylist("ambient")
        await waitForNativePublication(blockedPlaylistLibrary)
        precondition(blockedPlaylistLibrary.state.displays[displayIDs[0]]?.desktop.wallpaperID == "ocean")
        precondition(blockedPlaylistLibrary.state.playlists[0] == savedSlowMornings)
        blockedPlaylistLibrary.state.assign("ocean", display: displayIDs[0], playlistID: "ambient", now: Date().addingTimeInterval(60))
        let notDueAssignments = blockedPlaylistLibrary.state.displays
        blockedPlaylistLibrary.advancePlaylists(force: false)
        await waitForNativePublication(blockedPlaylistLibrary)
        precondition(blockedPlaylistLibrary.state.displays == notDueAssignments, "not-due advancement changed assignments")
        precondition(blockedPlaylistLibrary.error == nil, "not-due advancement scanned eligibility")
        blockedPlaylistLibrary.state.assign("ocean", display: displayIDs[0], playlistID: "ambient", now: Date().addingTimeInterval(-60))
        blockedPlaylistLibrary.advancePlaylists(force: false)
        await waitForNativePublication(blockedPlaylistLibrary)
        precondition(blockedPlaylistLibrary.state.displays[displayIDs[0]]?.desktop.wallpaperID == "cosmos")
        blockedPlaylistLibrary.advancePlaylists(force: true, backwards: true)
        await waitForNativePublication(blockedPlaylistLibrary)
        precondition(blockedPlaylistLibrary.state.displays[displayIDs[0]]?.desktop.wallpaperID == "ocean")
        blockedPlaylistLibrary.state.assign("aurora", display: displayIDs[0], playlistID: "ambient")
        blockedPlaylistLibrary.advancePlaylists(force: true)
        await waitForNativePublication(blockedPlaylistLibrary)
        precondition(blockedPlaylistLibrary.state.displays[displayIDs[0]]?.desktop.wallpaperID == "ocean")
        blockedPlaylistLibrary.advancePlaylists(force: true, backwards: true)
        await waitForNativePublication(blockedPlaylistLibrary)
        precondition(blockedPlaylistLibrary.state.displays[displayIDs[0]]?.desktop.wallpaperID == "ember")
        blockedPlaylistLibrary.state.shuffle = true
        blockedPlaylistLibrary.blockTags("stars, blue, water, calm, ambient, green")
        blockedPlaylistLibrary.startPlaylist("ambient")
        await waitForNativePublication(blockedPlaylistLibrary)
        precondition(blockedPlaylistLibrary.state.displays[displayIDs[0]]?.desktop.wallpaperID == "ember")
        blockedPlaylistLibrary.advancePlaylists(force: true)
        await waitForNativePublication(blockedPlaylistLibrary)
        precondition(blockedPlaylistLibrary.state.displays[displayIDs[0]]?.desktop.wallpaperID == "ember")
        blockedPlaylistLibrary.advancePlaylists(force: true, backwards: true)
        await waitForNativePublication(blockedPlaylistLibrary)
        precondition(blockedPlaylistLibrary.state.displays[displayIDs[0]]?.desktop.wallpaperID == "ember")
        blockedPlaylistLibrary.blockTags("warm, abstract, orange")
        let allBlockedAssignments = blockedPlaylistLibrary.state.displays
        blockedPlaylistLibrary.advancePlaylists(force: true)
        await waitForNativePublication(blockedPlaylistLibrary)
        precondition(blockedPlaylistLibrary.error?.contains("no playable wallpapers") == true)
        precondition(blockedPlaylistLibrary.state.displays == allBlockedAssignments)
        blockedPlaylistLibrary.error = nil
        blockedPlaylistLibrary.advancePlaylists(force: false)
        await waitForNativePublication(blockedPlaylistLibrary)
        precondition(blockedPlaylistLibrary.error == nil, "not-due empty playlist reported an error")
        precondition(blockedPlaylistLibrary.state.displays == allBlockedAssignments)
        blockedPlaylistLibrary.advancePlaylists(force: true)
        await waitForNativePublication(blockedPlaylistLibrary)
        precondition(blockedPlaylistLibrary.error?.contains("no playable wallpapers") == true, "forced empty playlist did not report an error")
        precondition(blockedPlaylistLibrary.state.displays == allBlockedAssignments)
        blockedPlaylistLibrary.error = nil
        blockedPlaylistLibrary.startPlaylist("ambient")
        await waitForNativePublication(blockedPlaylistLibrary)
        precondition(blockedPlaylistLibrary.error?.contains("no playable wallpapers") == true)
        precondition(blockedPlaylistLibrary.state.displays == allBlockedAssignments)
        blockedPlaylistLibrary.error = nil
        blockedPlaylistLibrary.state.assign("ember", display: displayIDs[0], playlistID: "ambient", now: Date().addingTimeInterval(-60))
        let dueBlockedAssignments = blockedPlaylistLibrary.state.displays
        blockedPlaylistLibrary.advancePlaylists(force: false)
        await waitForNativePublication(blockedPlaylistLibrary)
        precondition(blockedPlaylistLibrary.error?.contains("no playable wallpapers") == true, "due empty playlist did not report an error")
        precondition(blockedPlaylistLibrary.state.displays == dueBlockedAssignments)
        precondition(blockedPlaylistLibrary.state.playlists[0] == savedSlowMornings)
        print("PASS: library playlist start, advancement, history, and empty eligibility skip blocked wallpapers without changing saved contents")

        let surfaceRoot = root.appendingPathComponent("SurfacePlaylists", isDirectory: true)
        let surfaceLibrary = try Library(root: surfaceRoot, systemPlaybackEnabled: false)
        surfaceLibrary.tick?.invalidate()
        surfaceLibrary.state.displayMode = "perDisplay"
        surfaceLibrary.display = displayIDs[0]
        surfaceLibrary.state.shuffle = false
        surfaceLibrary.state.playlists[0].interval = 0
        surfaceLibrary.state.assign("ember", display: displayIDs[0])
        let preservedDesktop = surfaceLibrary.state.displays[displayIDs[0]]?.desktop
        surfaceLibrary.surface = .lockScreen
        surfaceLibrary.startPlaylist("ambient")
        await waitForNativePublication(surfaceLibrary)
        precondition(surfaceLibrary.state.displays[displayIDs[0]]?.desktop == preservedDesktop, "Lock Screen playlist start replaced Desktop")
        precondition(surfaceLibrary.state.displays[displayIDs[0]]?.lockScreen?.wallpaperID == "aurora")
        surfaceLibrary.advancePlaylists(force: true)
        await waitForNativePublication(surfaceLibrary)
        precondition(surfaceLibrary.state.displays[displayIDs[0]]?.lockScreen?.wallpaperID == "ocean")
        precondition(surfaceLibrary.state.displays[displayIDs[0]]?.desktop == preservedDesktop)
        surfaceLibrary.advancePlaylists(force: true, backwards: true)
        await waitForNativePublication(surfaceLibrary)
        precondition(surfaceLibrary.state.displays[displayIDs[0]]?.lockScreen?.wallpaperID == "aurora")
        surfaceLibrary.surface = .desktop
        surfaceLibrary.startPlaylist("ambient")
        await waitForNativePublication(surfaceLibrary)
        let preservedLock = surfaceLibrary.state.displays[displayIDs[0]]?.lockScreen
        surfaceLibrary.advancePlaylists(force: true)
        await waitForNativePublication(surfaceLibrary)
        precondition(surfaceLibrary.state.displays[displayIDs[0]]?.desktop.wallpaperID == "ocean")
        precondition(surfaceLibrary.state.displays[displayIDs[0]]?.lockScreen == preservedLock)
        surfaceLibrary.advancePlaylists(force: false)
        await waitForNativePublication(surfaceLibrary)
        precondition(surfaceLibrary.state.displays[displayIDs[0]]?.desktop.wallpaperID == "cosmos")
        precondition(surfaceLibrary.state.displays[displayIDs[0]]?.lockScreen?.wallpaperID == "ocean", "automatic advancement ignored independent Lock Screen playlist")
        surfaceLibrary.state.setSurfacesLinked(true, display: displayIDs[0])
        surfaceLibrary.advancePlaylists(force: false)
        await waitForNativePublication(surfaceLibrary)
        let linkedAssignment = surfaceLibrary.state.displays[displayIDs[0]]!
        precondition(linkedAssignment.desktop.wallpaperID == "ember", "linked playlist advanced twice")
        precondition(linkedAssignment.lockScreen == linkedAssignment.desktop)
        let savedSurfaceState = try LibraryDisk(root: surfaceRoot).load()
        precondition(savedSurfaceState.displays == surfaceLibrary.state.displays)
        print("PASS: playlist controls honor the selected surface; automatic independent and linked advancement persists")

        let launchRoot = root.appendingPathComponent("PlaylistLaunch", isDirectory: true)
        let launchDisk = try LibraryDisk(root: launchRoot)
        var launchState = LibraryState.initial
        launchState.displayMode = "perDisplay"
        let launchPlaylist = Playlist(name: "Launch playlist", items: ["aurora", "cosmos"], interval: 1)
        launchState.playlists.append(launchPlaylist)
        launchState.assign("aurora", display: displayIDs[0], playlistID: launchPlaylist.id, now: Date(timeIntervalSince1970: 0))
        launchState.nativePlayback[displayIDs[0]] = true
        try launchDisk.save(launchState)
        let launched = try Library(root: launchRoot, systemPlaybackEnabled: false)
        launched.tick?.invalidate()
        launched.advancePlaylists(force: false)
        await waitForNativePublication(launched)
        precondition(launched.state.displays == launchState.displays, "launch advanced an overdue saved playlist")
        launched.advancePlaylists(force: true)
        await waitForNativePublication(launched)
        precondition(launched.state.displays[displayIDs[0]]?.desktop.wallpaperID == "cosmos")
        launched.state.assign("cosmos", display: displayIDs[0], playlistID: launchPlaylist.id, now: Date(timeIntervalSince1970: 0))
        launched.advancePlaylists(force: false)
        await waitForNativePublication(launched)
        precondition(launched.state.displays[displayIDs[0]]?.desktop.wallpaperID == "aurora", "explicit playback did not resume automatic advancement")
        print("PASS: opening a library preserves overdue playlists until explicit playback resumes advancement")
        let selectedID = library.selected!.id
        library.display = displayIDs[0]
        library.applySelected()
        await waitForNativePublication(library)
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
        await waitForNativePublication(library)
        precondition(library.state.displays[displayIDs[0]]?.desktop.wallpaperID == "ember")
        precondition(library.state.displays[displayIDs[0]]?.lockScreen?.wallpaperID == "ocean")
        precondition(library.state.displays[displayIDs[0]]?.lockScreen?.mode == .still)

        library.surface = .desktop
        library.setSurfacesLinked(true)
        library.selection = "aurora"
        library.applySelected()
        await waitForNativePublication(library)
        precondition(library.state.displays[displayIDs[0]]?.desktop.wallpaperID == "aurora")
        precondition(library.state.displays[displayIDs[0]]?.lockScreen == library.state.displays[displayIDs[0]]?.desktop)

        library.setPlaybackMode("mirrored")
        library.setSurfacesLinked(false)
        library.selection = "cosmos"
        library.applySelected()
        await waitForNativePublication(library)
        for id in displayIDs {
            precondition(library.state.displays[id]?.desktop.wallpaperID == "cosmos")
        }
        library.setPlaybackMode("perDisplay")
        library.display = displayIDs[0]
        library.surface = .desktop
        library.applySelected()
        await waitForNativePublication(library)
        let beforeMissingTarget = library.state.displays
        library.display = "not-connected"
        library.applySelected()
        await waitForNativePublication(library)
        precondition(library.state.displays == beforeMissingTarget, "Per Display Apply fell back to a connected display")
        library.display = displayIDs[0]

        let firstDisplay = displayIDs[0]
        let otherDisplay = displayIDs.dropFirst().first ?? firstDisplay
        library.state.playlists.append(Playlist(id: "target-probe", name: "Target probe", items: ["ember", "cosmos"]))
        library.save()
        library.updatePlaylist("ambient", shuffle: false)
        library.display = firstDisplay
        library.startPlaylist("ambient")
        await waitForNativePublication(library)
        precondition(library.state.displays[firstDisplay]?.desktop.wallpaperID == "aurora")
        library.setPlaybackMode("mirrored")
        precondition(library.state.displayMode == "perDisplay")
        precondition(library.playbackMode == "mirrored")
        library.advancePlaylists(force: true)
        await waitForNativePublication(library)
        precondition(library.state.displayMode == "perDisplay")
        precondition(library.state.displays[firstDisplay]?.desktop.wallpaperID == "ocean")
        if otherDisplay != firstDisplay {
            precondition(library.state.displays[otherDisplay]?.desktop.wallpaperID == "cosmos")
        }
        library.display = otherDisplay
        library.startPlaylist("target-probe")
        await waitForNativePublication(library)
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
        await waitForNativePublication(library)
        library.display = otherDisplay
        library.setPlaybackMode("perDisplay")
        library.startPlaylist("target-probe")
        await waitForNativePublication(library)
        precondition(library.state.displayMode == "mirrored")
        precondition(library.playbackMode == "perDisplay")
        for id in displayIDs {
            precondition(library.state.displays[id]?.desktop.wallpaperID == "ember")
            precondition(library.state.displays[id]?.desktop.playlistID == "target-probe")
        }

        library.applySelected()
        await waitForNativePublication(library)
        library.setPlaybackMode("perDisplay")
        library.display = firstDisplay
        library.applySelected()
        await waitForNativePublication(library)
        library.state.shuffle = false
        library.startPlaylist("ambient")
        await waitForNativePublication(library)
        library.surface = .lockScreen
        library.setSurfaceMode(.still)
        library.surface = .desktop
        library.advancePlaylists(force: true)
        await waitForNativePublication(library)
        library.surface = .lockScreen
        let currentDesktop = library.state.displays[firstDisplay]!.desktop
        precondition(library.surfaceSummary(.desktop).contains("Quiet tides"), "draft summary used old playlist position")
        library.selection = "cosmos"
        library.applySelected()
        await waitForNativePublication(library)
        precondition(library.state.displays[firstDisplay]?.desktop == currentDesktop, "applying Lock Screen settings rewound desktop playlist")
        library.setSurfaceMode(.animated)
        library.remove(library.state.item("ocean")!)
        library.selection = "ember"
        library.applySelected()
        await waitForNativePublication(library)
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

    @MainActor
    static func importImageDecoderTests(_ root: URL) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let svg = root.appendingPathComponent("unsupported.svg")
        let svgData = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\"><rect width=\"16\" height=\"16\" fill=\"red\"/></svg>".utf8)
        try svgData.write(to: svg)
        precondition(NSImage(contentsOf: svg) != nil, "SVG must reproduce AppKit's broader decoder support")
        let library = try Library(root: root.appendingPathComponent("Library", isDirectory: true), systemPlaybackEnabled: false)
        let originalCount = library.state.wallpapers.count
        library.importMedia([svg])
        await waitForImport(library)
        precondition(library.state.wallpapers.count == originalCount, "Import accepted unsupported SVG")
        precondition(library.error?.contains("Choose a supported image") == true)
        let rejectedSourceData = try Data(contentsOf: svg)
        precondition(rejectedSourceData == svgData, "Rejected import changed its source")
        let rejectedFiles = try FileManager.default.contentsOfDirectory(atPath: library.disk.assets.path)
        precondition(rejectedFiles.isEmpty, "Rejected SVG was copied into the library")

        let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let image = context.makeImage()!
        for type in [UTType.png, .jpeg, .tiff] {
            let source = root.appendingPathComponent("supported." + type.preferredFilenameExtension!)
            let destination = CGImageDestinationCreateWithURL(source as CFURL, type.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            precondition(CGImageDestinationFinalize(destination))
            let sourceData = try Data(contentsOf: source)
            library.error = nil
            library.importMedia([source])
            await waitForImport(library)
            precondition(library.error == nil, "Supported raster import failed")
            let imported = library.state.wallpapers.last!
            precondition(imported.kind == "image")
            let importedURL = library.disk.url(for: imported)!
            precondition(importedURL != source)
            let importedData = try Data(contentsOf: importedURL)
            let preservedSourceData = try Data(contentsOf: source)
            precondition(importedData == sourceData, "Import changed copied raster data")
            precondition(preservedSourceData == sourceData, "Import changed the original raster source")
        }
        precondition(library.state.wallpapers.count == originalCount + 3)
        print("PASS: image import rejects SVG, accepts PNG/JPEG/TIFF, and preserves source bytes")
    }

    @MainActor
    static func importReferenceMovieTests(_ root: URL) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("self-contained.mov")
        try await writeVideoFixture(source)
        let reference = root.appendingPathComponent("external-reference.mov")
        let movie = AVMovie(url: source, options: nil)
        try movie.makeMovieHeader(fileType: .mov).write(to: reference)

        let library = try Library(root: root.appendingPathComponent("Library", isDirectory: true), systemPlaybackEnabled: false)
        let originalCount = library.state.wallpapers.count
        library.importMedia([reference])
        await waitForImport(library)
        precondition(library.state.wallpapers.count == originalCount, "Import accepted a movie with external video references")
        let rejectedImportFiles = try FileManager.default.contentsOfDirectory(atPath: library.disk.assets.path)
        precondition(rejectedImportFiles.isEmpty,
                     "Import copied a movie with external video references")

        library.error = nil
        library.importMedia([source])
        await waitForImport(library)
        guard let imported = library.state.wallpapers.last, let importedURL = library.disk.url(for: imported) else {
            preconditionFailure("Import rejected a self-contained movie")
        }
        let movedSource = root.appendingPathComponent("moved-source.mov")
        try FileManager.default.moveItem(at: source, to: movedSource)
        let decodedFrame = try await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: importedURL,
                                   options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first, try await track.load(.isSelfContained) else { return false }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)])
            let outputProvider = reader.outputProvider(for: output)
            try reader.start()
            return try await outputProvider.next() != nil
        }.value
        precondition(decodedFrame, "Imported video stopped playing after its original source moved")
        print("PASS: video import rejects external references and preserves self-contained playback after the source moves")
    }

    @MainActor
    static func sourceDownloadDuplicateTests(_ root: URL) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let library = try Library(root: root.appendingPathComponent("Library", isDirectory: true), systemPlaybackEnabled: false)
        let attribution = WallpaperSourceAttribution(catalogItemID: "nasa-test-item", sourceName: "NASA SVS",
            sourceURL: "https://svs.gsfc.nasa.gov/12729/", creator: "NASA/JHUAPL", licenseName: "Public domain",
            licenseURL: "https://svs.gsfc.nasa.gov/help/", modificationNotice: nil)
        let existingFile = library.disk.assets.appendingPathComponent("already.mov")
        try Data("existing media".utf8).write(to: existingFile)
        var existing = Wallpaper(id: "existing", title: "Edited title", kind: "video", file: "already.mov",
            tags: "saved tags", favorite: true, metadata: SceneMetadata(details: "kept details"),
            dateAdded: Date(timeIntervalSince1970: 42), sourceAttribution: attribution)
        library.state.wallpapers = [existing]
        var duplicateCompleted = false
        let duplicateTask = library.importMedia([root.appendingPathComponent("unused.mov")], sourceAttribution: attribution) { ids, error in
            duplicateCompleted = ids.isEmpty && error?.contains("already in your library") == true
        }
        precondition(duplicateTask == nil && duplicateCompleted)
        precondition(library.state.wallpapers == [existing], "Duplicate catalog download changed its existing library item")

        try FileManager.default.removeItem(at: existingFile)
        let source = root.appendingPathComponent("replacement.mov")
        try await writeVideoFixture(source)
        let oldDate = existing.dateAdded
        existing.metadata?.details = "saved details"
        library.state.wallpapers = [existing]
        library.state.playlists = [Playlist(id: "kept", name: "Kept playlist", items: [existing.id])]
        library.importMedia([source], sourceAttribution: attribution, titleOverride: "Catalog title")
        await waitForImport(library)
        let repaired = library.state.wallpapers.filter { $0.sourceAttribution?.catalogItemID == attribution.catalogItemID }
        precondition(repaired.count == 1 && repaired[0].id == existing.id, "Re-download created a duplicate wallpaper")
        precondition(repaired[0].title == existing.title && repaired[0].tags == existing.tags && repaired[0].favorite,
                     "Re-download overwrote local wallpaper edits")
        precondition(repaired[0].dateAdded == oldDate
            && repaired[0].metadata?.details == existing.metadata?.details
            && repaired[0].metadata?.category == existing.metadata?.category
            && repaired[0].metadata?.creditTitle == existing.metadata?.creditTitle
            && repaired[0].metadata?.creditURL == existing.metadata?.creditURL,
            "Re-download overwrote saved metadata")
        precondition(library.lastImportIDs.isEmpty && library.importNotice == nil,
                     "Repair offered Undo for an existing wallpaper")
        library.undoImport()
        let afterUndo = library.state.wallpapers.filter { $0.sourceAttribution?.catalogItemID == attribution.catalogItemID }
        precondition(afterUndo.count == 1 && afterUndo[0].id == existing.id && afterUndo[0].title == existing.title
            && afterUndo[0].tags == existing.tags && afterUndo[0].favorite
            && library.state.playlist("kept")?.items == [existing.id],
            "Undo after repair removed the existing wallpaper or its saved edits and playlist membership")
        guard let repairedURL = library.disk.url(for: repaired[0]) else { preconditionFailure("Re-download has no local media path") }
        let asset = AVURLAsset(url: repairedURL,
            options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
        let repairedTracks = try await asset.loadTracks(withMediaType: .video)
        precondition(!repairedTracks.isEmpty, "Re-download was not playable media")
        let unsafeRoot = root.appendingPathComponent("UnsafeLibrary", isDirectory: true)
        let unsafeLibrary = try Library(root: unsafeRoot, systemPlaybackEnabled: false)
        var unsafeAttribution = attribution
        unsafeAttribution.catalogItemID = "nasa-unsafe-id"
        let outsideMedia = root.appendingPathComponent("escaped.mov")
        precondition(!FileManager.default.fileExists(atPath: outsideMedia.path))
        unsafeLibrary.state.wallpapers = [Wallpaper(id: "../../escaped", title: "Kept title", kind: "video",
            file: "missing.mov", tags: "kept tags", favorite: true, sourceAttribution: unsafeAttribution)]
        unsafeLibrary.importMedia([source], sourceAttribution: unsafeAttribution)
        await waitForImport(unsafeLibrary)
        guard let repairedUnsafe = unsafeLibrary.state.item("../../escaped"),
              let repairedUnsafeURL = unsafeLibrary.disk.url(for: repairedUnsafe) else {
            preconditionFailure("Repair lost the existing wallpaper ID or its safe media path")
        }
        precondition(repairedUnsafe.title == "Kept title" && repairedUnsafe.tags == "kept tags" && repairedUnsafe.favorite
            && repairedUnsafeURL.deletingLastPathComponent() == unsafeLibrary.disk.assets
            && repairedUnsafeURL.lastPathComponent == repairedUnsafe.file
            && FileManager.default.fileExists(atPath: repairedUnsafeURL.path)
            && !FileManager.default.fileExists(atPath: outsideMedia.path),
            "Repair escaped Media or changed the existing wallpaper record")
        print("PASS: catalog downloads preserve existing records, reject duplicates, and repair missing media without losing edits")
    }

    @MainActor
    static func waitForImport(_ library: Library) async {
        let deadline = Date().addingTimeInterval(20)
        while library.importing && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        precondition(!library.importing, "Video import timed out")
    }

    static func writeVideoFixture(_ url: URL) async throws {
        let width = 64
        let height = 64
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        let attributes = CVPixelBufferCreationAttributes(pixelFormatType: .init(rawValue: kCVPixelFormatType_32ARGB),
            size: CVImageSize(width: width, height: height), compatibility: [.cgBitmapContext])
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: attributes)
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<2 {
            guard let pool = receiver.pixelBufferPool else { throw LibraryError.unreadableMedia("video fixture") }
            let pixels = try pool.makeMutablePixelBuffer()
            pixels.withUnsafeBuffer { buffer in
                CVPixelBufferLockBaseAddress(buffer, [])
                defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
                if let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
                    context.setFillColor(CGColor(red: 0.2, green: 0.5 + Double(frame) * 0.1, blue: 0.8, alpha: 1))
                    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                }
            }
            try await receiver.append(CVReadOnlyPixelBuffer(pixels), with: CMTime(value: Int64(frame), timescale: 24))
        }
        receiver.finish()
        await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
        guard writer.status == .completed else { throw writer.error ?? LibraryError.unreadableMedia("video fixture") }
    }
}
