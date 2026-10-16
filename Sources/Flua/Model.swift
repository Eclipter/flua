import Foundation

func resolvedDisplayMode(_ mode: String?) -> String {
    mode ?? "perDisplay"
}

func initialDisplaySelection(mode: String?, displayIDs: [String]) -> String {
    resolvedDisplayMode(mode) == "perDisplay" ? displayIDs.first ?? "all" : "all"
}

struct Wallpaper: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var title: String
    var kind: String
    var file: String?
    var tags: String = ""
    var favorite: Bool = false
    var speed: Double = 1
    var volume: Double = 0
    var dimming: Double = 0
    var fit: Bool = false
    var videoEdit: VideoEdit?
    var metadata: SceneMetadata?
}

struct VideoEdit: Codable, Equatable {
    var start: Double = 0
    var end: Double?
    var thumbnail: Double = 0
    var includeAudio: Bool = true
    var quality: String = "high"
}

struct SceneMetadata: Codable, Equatable {
    var details: String = ""
    var category: String = ""
    var creditTitle: String = ""
    var creditURL: String = ""
}

struct Playlist: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var items: [String] = []
    var interval: Double?
    var shuffle: Bool?
}

struct DisplayAssignment: Codable, Equatable {
    var wallpaperID: String?
    var playlistID: String?
    var index: Int = 0
    var changedAt: Date = Date()
    var history: [String]?
}

struct LibraryState: Codable {
    var wallpapers: [Wallpaper] = []
    var playlists: [Playlist] = []
    var displays: [String: DisplayAssignment] = [:]
    var interval: Double = 300
    var shuffle: Bool = false
    var pauseOnBattery: Bool = false
    var pauseOnLowPower: Bool?
    var pauseOnFullscreen: Bool = true
    var paused: Bool = false
    var displayMode: String?
    static var initial: LibraryState {
        var s = LibraryState()
        s.wallpapers = [
            Wallpaper(id: "aurora", title: "Northern lights", kind: "aurora", tags: "ambient, green, nature"),
            Wallpaper(id: "cosmos", title: "Deep space", kind: "cosmos", tags: "stars, blue, space"),
            Wallpaper(id: "ocean", title: "Quiet tides", kind: "ocean", tags: "water, calm, blue"),
            Wallpaper(id: "ember", title: "Ember glow", kind: "ember", tags: "warm, abstract, orange")
        ]
        s.playlists = [Playlist(id: "ambient", name: "Slow mornings", items: ["aurora", "ocean", "cosmos", "ember"])]
        s.displayMode = "mirrored"
        return s
    }
    func item(_ id: String?) -> Wallpaper? { wallpapers.first { $0.id == id } }
    func playlist(_ id: String?) -> Playlist? { playlists.first { $0.id == id } }
    mutating func remove(_ id: String) {
        wallpapers.removeAll { $0.id == id }
        for i in playlists.indices { playlists[i].items.removeAll { $0 == id } }
        for key in Array(displays.keys) {
            if displays[key]?.wallpaperID == id { displays.removeValue(forKey: key) }
        }
    }
    mutating func advance(display: String, now: Date = Date(), force: Bool = false, backwards: Bool = false) -> Wallpaper? {
        guard var a = displays[display], let p = playlist(a.playlistID) else { return nil }
        let ids = p.items.filter { item($0) != nil }
        guard !ids.isEmpty else { return nil }
        guard force || now.timeIntervalSince(a.changedAt) >= (p.interval ?? interval) else { return nil }
        if backwards {
            var history = (a.history ?? []).filter { ids.contains($0) }
            if let previous = history.popLast(), let index = ids.firstIndex(of: previous) { a.index = index }
            else { a.index = ((ids.firstIndex(of: a.wallpaperID ?? "") ?? a.index) - 1 + ids.count) % ids.count }
            a.history = history
        } else {
        if let old = a.wallpaperID { a.history = Array(((a.history ?? []) + [old]).suffix(128)) }
        if (p.shuffle ?? shuffle) && ids.count > 1 {
            a.index = ids.indices.filter { ids[$0] != a.wallpaperID }.randomElement() ?? 0
        } else { a.index = ((ids.firstIndex(of: a.wallpaperID ?? "") ?? a.index) + 1) % ids.count }
        }
        a.wallpaperID = ids[a.index]
        a.changedAt = now
        displays[display] = a
        return item(a.wallpaperID)
    }
    mutating func advanceMirrored(displayIDs: [String], now: Date = Date(), force: Bool = false, backwards: Bool = false) -> Wallpaper? {
        guard let source = displayIDs.first(where: { displays[$0]?.playlistID != nil }),
              advance(display: source, now: now, force: force, backwards: backwards) != nil else { return nil }
        return synchronizeMirrored(displayIDs: displayIDs, preferredSource: source)
    }
    mutating func synchronizeMirrored(displayIDs: [String], preferredSource: String? = nil) -> Wallpaper? {
        let preferred = preferredSource.flatMap { displayIDs.contains($0) ? $0 : nil }
        let candidates = (preferred.map { [$0] } ?? []) + displayIDs
        guard let source = candidates.first(where: { item(displays[$0]?.wallpaperID) != nil }),
              let assignment = displays[source], let wallpaper = item(assignment.wallpaperID) else { return nil }
        for id in displayIDs { displays[id] = assignment }
        return wallpaper
    }
}

enum LibraryError: LocalizedError {
    case invalidLibrary
    case unreadableMedia(String)
    var errorDescription: String? {
        switch self {
        case .invalidLibrary: return "The saved library could not be read. It was left untouched."
        case .unreadableMedia(let name): return "Could not open \(name). Choose a supported image or video."
        }
    }
}

final class LibraryDisk {
    let root: URL
    let assets: URL
    let manifest: URL
    init(root: URL) throws {
        self.root = root
        assets = root.appendingPathComponent("Media", isDirectory: true)
        manifest = root.appendingPathComponent("library.json")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    }
    func load() throws -> LibraryState {
        guard FileManager.default.fileExists(atPath: manifest.path) else { return .initial }
        do { return try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: manifest)) }
        catch { throw LibraryError.invalidLibrary }
    }
    func save(_ state: LibraryState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: manifest, options: .atomic)
    }
    func url(for wallpaper: Wallpaper) -> URL? {
        guard let name = wallpaper.file,
              name == (name as NSString).lastPathComponent, name != ".", name != ".." else { return nil }
        return assets.appendingPathComponent(name)
    }
}
