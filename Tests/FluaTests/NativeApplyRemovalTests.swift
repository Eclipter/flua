import AppKit
import Foundation

extension Bundle { static var module: Bundle { Bundle.main } }

@main struct NativeApplyRemovalTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flua-apply-removal-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        NativeWallpaper.catalogURL = root.appendingPathComponent("catalog.json")
        let library = try Library(root: root)
        library.tick?.invalidate()
        let source = URL(fileURLWithPath: "Resources/AppIcon.png")
        guard let importTask = library.importMedia([source]) else { preconditionFailure("Could not start import") }
        await importTask.value
        let imported = library.lastImportIDs
        let notice = library.importNotice
        precondition(imported.count == 1 && notice != nil, "Import fixture failed")
        let wallpaper = library.state.item("aurora")!
        precondition(!library.screens.isEmpty, "A display is required for this test")
        library.selection = wallpaper.id
        library.applySelected()
        let deadline = Date().addingTimeInterval(10)
        var started = false
        while !started && Date() < deadline {
            started = NativeWallpaper.hasStarted()
            if !started { try await Task.sleep(for: .milliseconds(5)) }
        }
        precondition(started && library.nativeSetupBusy, "Apply did not reach the delayed native boundary")
        library.remove(wallpaper)
        let retained = library.state.item(wallpaper.id) != nil
        let reported = library.error != nil
        library.undoImport()
        precondition(library.lastImportIDs == imported && library.importNotice == notice && library.state.item(imported[0]) != nil, "Undo must remain available after native work")
        NativeWallpaper.release.signal()
        await library.finishNativeWork()
        precondition(retained && reported, "Removal must be rejected while native Apply is active")
        precondition(library.state.nativePlayback.values.contains(true), "Apply did not record active playback")
        for id in library.screens.map(displayID) where library.state.nativePlayback[id] == true {
            precondition(library.state.displays[id]?.desktop.wallpaperID == wallpaper.id || library.state.nativeCleanupDisplays.contains(id), "Active playback lacks an assignment or cleanup request")
        }
        let saved = try LibraryDisk(root: root).load()
        precondition(saved.item(wallpaper.id) != nil && saved.nativePlayback == library.state.nativePlayback)
        library.undoImport()
        precondition(library.lastImportIDs.isEmpty && library.state.item(imported[0]) == nil, "Undo did not resume after Apply")
        library.remove(wallpaper)
        precondition(library.state.item(wallpaper.id) == nil, "Removal did not resume after Apply")
        print("PASS: removal is rejected during native Apply and leaves a saved assignment")
    }
}
