import Foundation
import AVFoundation
import CoreGraphics
import CoreVideo
import Dispatch

// Standalone `swiftc` executables do not synthesize `Bundle.module`; provide a
// test-only stand-in so the rendering types Library.swift references can
// type-check. This stand-in is never exercised by the test below (no scene
// thumbnail is generated while clearing filters).
extension Bundle {
    static var module: Bundle { Bundle.main }
}

@main struct ClearFiltersSortTests {
    @MainActor
    static func main() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FluaClearFiltersSortTest-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let support = dir.appendingPathComponent("ApplicationSupport", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let root = LibraryPaths.resolve(applicationSupport: support)
        try await importReferenceMovieTests(dir.appendingPathComponent("video-import", isDirectory: true))

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
        blockedPlaylistState.playlists[0].interval = 0
        try blockedPlaylistDisk.save(blockedPlaylistState)
        let blockedPlaylistLibrary = try Library(root: blockedPlaylistRoot, systemPlaybackEnabled: false)
        blockedPlaylistLibrary.tick?.invalidate()
        blockedPlaylistLibrary.display = displayIDs[0]
        blockedPlaylistLibrary.blockTags("nature")
        let savedSlowMornings = blockedPlaylistLibrary.state.playlists[0]
        blockedPlaylistLibrary.startPlaylist("ambient")
        precondition(blockedPlaylistLibrary.state.displays[displayIDs[0]]?.desktop.wallpaperID == "ocean")
        precondition(blockedPlaylistLibrary.state.playlists[0] == savedSlowMornings)
        blockedPlaylistLibrary.advancePlaylists(force: false)
        precondition(blockedPlaylistLibrary.state.displays[displayIDs[0]]?.desktop.wallpaperID == "cosmos")
        blockedPlaylistLibrary.advancePlaylists(force: true, backwards: true)
        precondition(blockedPlaylistLibrary.state.displays[displayIDs[0]]?.desktop.wallpaperID == "ocean")
        blockedPlaylistLibrary.state.assign("aurora", display: displayIDs[0], playlistID: "ambient")
        blockedPlaylistLibrary.advancePlaylists(force: true)
        precondition(blockedPlaylistLibrary.state.displays[displayIDs[0]]?.desktop.wallpaperID == "ocean")
        blockedPlaylistLibrary.advancePlaylists(force: true, backwards: true)
        precondition(blockedPlaylistLibrary.state.displays[displayIDs[0]]?.desktop.wallpaperID == "ember")
        blockedPlaylistLibrary.state.shuffle = true
        blockedPlaylistLibrary.blockTags("stars, blue, water, calm, ambient, green")
        blockedPlaylistLibrary.startPlaylist("ambient")
        precondition(blockedPlaylistLibrary.state.displays[displayIDs[0]]?.desktop.wallpaperID == "ember")
        blockedPlaylistLibrary.advancePlaylists(force: true)
        precondition(blockedPlaylistLibrary.state.displays[displayIDs[0]]?.desktop.wallpaperID == "ember")
        blockedPlaylistLibrary.advancePlaylists(force: true, backwards: true)
        precondition(blockedPlaylistLibrary.state.displays[displayIDs[0]]?.desktop.wallpaperID == "ember")
        blockedPlaylistLibrary.blockTags("warm, abstract, orange")
        let allBlockedAssignments = blockedPlaylistLibrary.state.displays
        blockedPlaylistLibrary.advancePlaylists(force: true)
        precondition(blockedPlaylistLibrary.error?.contains("no playable wallpapers") == true)
        precondition(blockedPlaylistLibrary.state.displays == allBlockedAssignments)
        blockedPlaylistLibrary.error = nil
        blockedPlaylistLibrary.advancePlaylists(force: false)
        precondition(blockedPlaylistLibrary.error?.contains("no playable wallpapers") == true)
        precondition(blockedPlaylistLibrary.state.displays == allBlockedAssignments)
        blockedPlaylistLibrary.error = nil
        blockedPlaylistLibrary.startPlaylist("ambient")
        precondition(blockedPlaylistLibrary.error?.contains("no playable wallpapers") == true)
        precondition(blockedPlaylistLibrary.state.displays == allBlockedAssignments)
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
        precondition(surfaceLibrary.state.displays[displayIDs[0]]?.desktop == preservedDesktop, "Lock Screen playlist start replaced Desktop")
        precondition(surfaceLibrary.state.displays[displayIDs[0]]?.lockScreen?.wallpaperID == "aurora")
        surfaceLibrary.advancePlaylists(force: true)
        precondition(surfaceLibrary.state.displays[displayIDs[0]]?.lockScreen?.wallpaperID == "ocean")
        precondition(surfaceLibrary.state.displays[displayIDs[0]]?.desktop == preservedDesktop)
        surfaceLibrary.advancePlaylists(force: true, backwards: true)
        precondition(surfaceLibrary.state.displays[displayIDs[0]]?.lockScreen?.wallpaperID == "aurora")
        surfaceLibrary.surface = .desktop
        surfaceLibrary.startPlaylist("ambient")
        let preservedLock = surfaceLibrary.state.displays[displayIDs[0]]?.lockScreen
        surfaceLibrary.advancePlaylists(force: true)
        precondition(surfaceLibrary.state.displays[displayIDs[0]]?.desktop.wallpaperID == "ocean")
        precondition(surfaceLibrary.state.displays[displayIDs[0]]?.lockScreen == preservedLock)
        surfaceLibrary.advancePlaylists(force: false)
        precondition(surfaceLibrary.state.displays[displayIDs[0]]?.desktop.wallpaperID == "cosmos")
        precondition(surfaceLibrary.state.displays[displayIDs[0]]?.lockScreen?.wallpaperID == "ocean", "automatic advancement ignored independent Lock Screen playlist")
        surfaceLibrary.state.setSurfacesLinked(true, display: displayIDs[0])
        surfaceLibrary.advancePlaylists(force: false)
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
        precondition(launched.state.displays == launchState.displays, "launch advanced an overdue saved playlist")
        launched.advancePlaylists(force: true)
        precondition(launched.state.displays[displayIDs[0]]?.desktop.wallpaperID == "cosmos")
        launched.state.assign("cosmos", display: displayIDs[0], playlistID: launchPlaylist.id, now: Date(timeIntervalSince1970: 0))
        launched.advancePlaylists(force: false)
        precondition(launched.state.displays[displayIDs[0]]?.desktop.wallpaperID == "aurora", "explicit playback did not resume automatic advancement")
        print("PASS: opening a library preserves overdue playlists until explicit playback resumes advancement")
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
        library.surface = .desktop
        library.advancePlaylists(force: true)
        library.surface = .lockScreen
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
