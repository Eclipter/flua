import Foundation
import AVFoundation
import CoreGraphics
import CoreVideo
import Dispatch
import AppKit
import ImageIO
import UniformTypeIdentifiers

extension Bundle {
    static var module: Bundle { Bundle.main }
}

@main struct MutationRollbackTests {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FluaMutationRollback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Library(root: root, systemPlaybackEnabled: false)
        library.tick?.invalidate()
        try await Task.sleep(for: .milliseconds(250))
        await library.finishCatalogWrites()
        precondition(!library.screens.isEmpty, "assignment rollback tests require one connected display")
        library.state.playlists = [Playlist(id: "rollback", name: "Rollback", items: ["aurora", "ocean"], shuffle: false)]
        library.state.assign("aurora", display: "saved-display", playlistID: "rollback")
        library.state.nativePlayback["saved-display"] = true
        for screen in library.screens {
            let id = displayID(screen)
            library.state.assign("aurora", display: id, playlistID: "rollback")
            library.state.nativePlayback[id] = true
        }
        precondition(library.save())
        await library.finishCatalogWrites()

        library.selection = "aurora"
        library.section = "favorites"
        library.thumbnails["aurora"] = NSImage(size: NSSize(width: 1, height: 1))
        library.disk.thumbnails["aurora"] = "preserve"
        try rejectManifestWrite(library, "wallpaper removal") { library.remove(library.state.item("aurora")!) }
        precondition(library.thumbnails["aurora"] != nil && library.disk.thumbnails["aurora"] == "preserve",
                     "failed removal discarded thumbnail cleanup state")
        precondition(library.selection == "aurora", "failed removal changed selection")
        precondition(library.state.nativeCleanupDisplays.isEmpty, "failed removal kept uncommitted cleanup intent")

        let originalSection = library.section
        try rejectManifestWrite(library, "playlist creation") { library.createPlaylist("New") }
        precondition(library.section == originalSection, "failed playlist creation changed the selected section")
        try rejectManifestWrite(library, "playlist update") { library.updatePlaylist("rollback", interval: 60, shuffle: true) }
        try rejectManifestWrite(library, "playlist duplication") { library.duplicatePlaylist("rollback") }
        precondition(library.section == originalSection, "failed playlist duplication changed the selected section")
        try rejectManifestWrite(library, "playlist membership toggle") { library.toggleInPlaylist("aurora", "rollback") }
        try rejectManifestWrite(library, "playlist reorder") { library.moveInPlaylist("aurora", playlist: "rollback", delta: 1) }
        try rejectManifestWrite(library, "playlist deletion") { library.deletePlaylist("rollback") }
        precondition(library.section == originalSection, "failed playlist deletion changed the selected section")
        try rejectManifestWrite(library, "bulk playlist assignment") { library.addToPlaylist(["cosmos"], playlistID: "rollback") }
        try rejectManifestWrite(library, "playlist pause") { library.togglePlaylistPause() }

        library.selection = "ocean"
        try rejectManifestWrite(library, "wallpaper assignment") { library.applySelected() }
        try rejectManifestWrite(library, "playlist assignment") { library.startPlaylist("rollback") }
        try rejectManifestWrite(library, "playlist advancement") { library.advancePlaylists(force: true) }
        print("PASS: failed removal, playlist and assignment saves roll back in memory, preserve follow-up state, and reload consistently")
    }

    @MainActor
    static func rejectManifestWrite(_ library: Library, _ name: String, mutation: () -> Void) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let expectedState = try encoder.encode(library.state)
        let originalManifest = try Data(contentsOf: library.disk.manifest)
        try FileManager.default.removeItem(at: library.disk.manifest)
        try FileManager.default.createDirectory(at: library.disk.manifest, withIntermediateDirectories: false)
        try Data("block".utf8).write(to: library.disk.manifest.appendingPathComponent("blocker"))

        mutation()
        let memoryAfterMutation = try encoder.encode(library.state)
        precondition(memoryAfterMutation == expectedState, "\(name) left memory ahead of the failed manifest commit")

        try FileManager.default.removeItem(at: library.disk.manifest)
        try originalManifest.write(to: library.disk.manifest, options: .atomic)
        let reloaded = try LibraryDisk(root: library.disk.root).load()
        let diskAfterMutation = try encoder.encode(reloaded)
        precondition(diskAfterMutation == expectedState, "\(name) changed the saved manifest after failure")
    }
}
