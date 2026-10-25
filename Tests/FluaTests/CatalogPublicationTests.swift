import Foundation
import AppKit

private final class Publications: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        values.append(value)
    }
    var recorded: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private func require(_ condition: Bool, _ message: String = "Catalog assertion failed") {
    precondition(condition, message)
}

@main struct CatalogPublicationTests {
    static func read(_ disk: LibraryDisk) throws -> ProviderCatalog {
        try JSONDecoder().decode(ProviderCatalog.self, from: Data(contentsOf: disk.catalog))
    }

    static func identity(_ url: URL) throws -> NSDictionary {
        try FileManager.default.attributesOfItem(atPath: url.path) as NSDictionary
    }

    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Flua-catalog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try LibraryDisk(root: root)
        var state = LibraryState.initial
        require(try disk.save(state) == nil)
        let bytes = try Data(contentsOf: disk.catalog)
        let originalIdentity = try identity(disk.catalog)
        require(await disk.publishCatalog(state) == nil)
        state.wallpapers[0].favorite.toggle()
        try disk.saveManifest(state)
        let manifest = try Data(contentsOf: disk.manifest)
        require(await disk.publishCatalog(state) == nil)
        require(try identity(disk.catalog) == originalIdentity, "Unchanged provider data rewrote the catalog")
        require(try Data(contentsOf: disk.catalog) == bytes)
        require(try disk.load().wallpapers[0].favorite == state.wallpapers[0].favorite)

        try FileManager.default.removeItem(at: disk.catalog)
        require(await disk.publishCatalog(state) == nil)
        require(try Data(contentsOf: disk.catalog) == bytes, "Deleted catalog was not restored")
        try Data("external replacement".utf8).write(to: disk.catalog, options: .atomic)
        require(await disk.publishCatalog(state) == nil)
        require(try Data(contentsOf: disk.catalog) == bytes, "Replaced catalog was mistaken for cached output")

        try FileManager.default.removeItem(at: disk.catalog)
        try FileManager.default.createDirectory(at: disk.catalog, withIntermediateDirectories: false)
        try Data("block atomic replacement".utf8).write(to: disk.catalog.appendingPathComponent("blocker"))
        require(await disk.publishCatalog(state) != nil, "Catalog failure was hidden")
        try FileManager.default.removeItem(at: disk.catalog)
        require(await disk.publishCatalog(state) == nil)
        require(try Data(contentsOf: disk.catalog) == bytes, "Identical input did not retry after failure")

        let publications = Publications()
        let firstID = state.wallpapers[0].id
        for title in ["A", "B"] {
            state.wallpapers[0].title = title
            disk.thumbnails[firstID] = title
            disk.publishCatalog(state) { error in
                require(!Thread.isMainThread, "Catalog completion ran on main")
                require(error == nil)
                let value = try! read(disk)
                require(value.items.first { $0.id == firstID }?.title == title)
                require(value.items.first { $0.id == firstID }?.thumbnail == title, "Thumbnail snapshot changed after enqueue")
                publications.append(title)
            }
        }
        disk.thumbnails[firstID] = "not enqueued"
        await disk.finishCatalogWrites()
        require(publications.recorded == ["A", "B"], "Publication order changed")
        require(try read(disk).items.first { $0.id == firstID }?.title == "B")
        require(try Data(contentsOf: disk.manifest) == manifest, "Catalog publication rewrote the manifest")
        try await benchmark(root.appendingPathComponent("benchmark"))
        print("PASS: catalog caching, replacement recovery, retry, ordered snapshots, and worker callbacks")
    }

    @MainActor static func benchmark(_ root: URL) async throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 480, pixelsHigh: 270,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 480 * 3, bitsPerPixel: 24)!
        var random: UInt32 = 42
        for index in 0..<(bitmap.bytesPerRow * bitmap.pixelsHigh) {
            random = random &* 1_664_525 &+ 1_013_904_223
            bitmap.bitmapData![index] = UInt8(truncatingIfNeeded: random >> 24)
        }
        let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.2])!
        let thumbnail = "data:image/jpeg;base64," + jpeg.base64EncodedString()
        let disk = try LibraryDisk(root: root)
        var state = LibraryState.initial
        state.wallpapers = (0..<1000).map { Wallpaper(id: "item-\($0)", title: "Wallpaper \($0)", kind: "image", file: "\($0).jpg") }
        for item in state.wallpapers { disk.thumbnails[item.id] = thumbnail }
        let clock = ContinuousClock()
        let start = clock.now
        disk.publishCatalog(state) { require($0 == nil) }
        let enqueue = start.duration(to: clock.now)
        var mainActorTicks = 0
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                mainActorTicks += 1
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        await disk.finishCatalogWrites()
        heartbeat.cancel()
        require(mainActorTicks > 0, "Main actor made no progress during publication")
        let size = try Data(contentsOf: disk.catalog).count
        require(try read(disk).items.count == 1000)
        print("BENCHMARK: 1000 rows, JPEG \(jpeg.count) bytes, catalog \(size) bytes; enqueue \(enqueue), publication \(start.duration(to: clock.now)), main actor ticks \(mainActorTicks)")
    }
}
