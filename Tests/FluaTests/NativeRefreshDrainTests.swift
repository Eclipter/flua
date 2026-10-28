import AppKit
import Foundation

extension Bundle { static var module: Bundle { Bundle.main } }

@main struct NativeRefreshDrainTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flua-refresh-drain-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        NativeWallpaper.catalogURL = root.appendingPathComponent("catalog.json")
        let library = try Library(root: root)
        library.tick?.invalidate()
        await library.finishCatalogWrites()
        var wallpaper = Wallpaper(id: "video", title: "Video", kind: "video", file: "fixture.mov")
        wallpaper.videoEdit = VideoEdit(start: 1, end: 5, thumbnail: 2)
        library.state.wallpapers.append(wallpaper)
        precondition(library.save())
        await library.finishCatalogWrites()

        wallpaper.videoEdit = VideoEdit(start: 2, end: 4, thumbnail: 3)
        precondition(library.edit(wallpaper))
        var exited = false
        let shutdown = Task { @MainActor in
            await library.finishNativeWork()
            exited = true
        }
        let deadline = Date().addingTimeInterval(10)
        while !NativeWallpaper.hasStarted() && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        precondition(NativeWallpaper.item != nil, "shutdown did not flush the queued edit")
        let refreshed = NativeWallpaper.item!
        precondition(refreshed.trimStart == 2 && refreshed.trimEnd == 4 && refreshed.still == 3)
        precondition(!exited, "shutdown returned before the native refresh completed")
        NativeWallpaper.release.signal()
        await shutdown.value
        precondition(NativeWallpaper.completed && exited, "shutdown failed to wait for the native refresh")
        let saved = try JSONDecoder().decode(ProviderCatalog.self, from: Data(contentsOf: library.disk.catalog))
        let item = saved.items.first { $0.id == wallpaper.id }!
        precondition(item.trimStart == 2 && item.trimEnd == 4 && item.still == 3)
        print("PASS: quit drains queued video trim and cover refresh before exit")
    }
}
