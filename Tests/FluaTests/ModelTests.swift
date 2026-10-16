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
        state.displays["display-A"] = DisplayAssignment(wallpaperID: "aurora", playlistID: "ambient", changedAt: Date(timeIntervalSince1970: 0))
        precondition(state.advance(display: "display-A", now: Date(timeIntervalSince1970: 299)) == nil)
        precondition(state.advance(display: "display-A", now: Date(timeIntervalSince1970: 300))?.id == "ocean")
        precondition(state.advance(display: "display-A", now: Date(timeIntervalSince1970: 301)) == nil)
        state.shuffle = true
        for _ in 0..<100 {
            let old = state.displays["display-A"]?.wallpaperID
            let next = state.advance(display: "display-A", force: true)
            precondition(next != nil && next?.id != old)
            precondition(state.advance(display: "display-A", force: true, backwards: true)?.id == old)
        }
        let oldSchema = Data("{\"id\":\"old\",\"title\":\"Old scene\",\"kind\":\"video\",\"tags\":\"\",\"favorite\":false,\"speed\":1,\"volume\":0,\"dimming\":0,\"fit\":false}".utf8)
        let oldWallpaper = try JSONDecoder().decode(Wallpaper.self, from: oldSchema)
        precondition(oldWallpaper.videoEdit == nil && oldWallpaper.metadata == nil)
        state.displays["display-B"] = DisplayAssignment(wallpaperID: "ember")
        state.remove("ember")
        precondition(state.displays["display-B"] == nil)
        precondition(state.playlists.allSatisfy { !$0.items.contains("ember") })
        let activeID = state.displays["display-A"]!.wallpaperID!
        state.remove(activeID)
        precondition(state.displays["display-A"] == nil)
        try disk.save(state)
        let restored = try disk.load()
        precondition(restored.wallpapers == state.wallpapers && restored.playlists == state.playlists && restored.displays == state.displays)
        precondition(disk.url(for: Wallpaper(title: "bad", kind: "video", file: "../../secret")) == nil)
        precondition(disk.url(for: Wallpaper(title: "good", kind: "video", file: "clip.mp4"))!.deletingLastPathComponent() == disk.assets)
        let invalid = Data("not valid json".utf8)
        try invalid.write(to: disk.manifest)
        do { _ = try disk.load(); preconditionFailure("Corrupt library accepted") } catch LibraryError.invalidLibrary {}
        let preserved = try Data(contentsOf: disk.manifest)
        precondition(preserved == invalid)
        state.playlists = [Playlist(id: "empty", name: "Empty")]
        state.displays["display-C"] = DisplayAssignment(playlistID: "empty")
        precondition(state.advance(display: "display-C", force: true) == nil)
        print("PASS: scheduling boundaries, 100 shuffle transitions, removal cleanup, persistence, path validation, corrupt-library preservation, empty playlists")
    }
}
