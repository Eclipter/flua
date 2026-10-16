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
    var mediaFacts: MediaFacts?
    var dateAdded: Date?
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
    var color: String?
    var motion: String?
}

struct Playlist: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var items: [String] = []
    var interval: Double?
    var shuffle: Bool?
}

enum WallpaperSurface: CaseIterable {
    case desktop, lockScreen
}

enum WallpaperMode: String, Codable {
    case animated, still
}

struct SurfaceAssignment: Codable, Equatable {
    var wallpaperID: String?
    var playlistID: String?
    var index: Int = 0
    var changedAt: Date = Date()
    var history: [String]?
    var mode: WallpaperMode = .animated

    var isEmpty: Bool { wallpaperID == nil && playlistID == nil && mode == .animated }

    private enum CodingKeys: String, CodingKey {
        case wallpaperID, playlistID, index, changedAt, history, mode
    }
}

extension SurfaceAssignment {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wallpaperID = try c.decodeIfPresent(String.self, forKey: .wallpaperID)
        playlistID = try c.decodeIfPresent(String.self, forKey: .playlistID)
        index = try c.decode(Int.self, forKey: .index)
        changedAt = try c.decode(Date.self, forKey: .changedAt)
        history = try c.decodeIfPresent([String].self, forKey: .history)
        mode = try c.decodeIfPresent(WallpaperMode.self, forKey: .mode) ?? .animated
    }
}

struct DisplayAssignment: Codable, Equatable {
    private(set) var desktop: SurfaceAssignment
    private(set) var lockScreen: SurfaceAssignment?
    private(set) var surfacesLinked: Bool

    init(desktop: SurfaceAssignment = SurfaceAssignment(), lockScreen: SurfaceAssignment? = nil, surfacesLinked: Bool = false) {
        self.desktop = desktop
        self.lockScreen = surfacesLinked ? desktop : lockScreen
        self.surfacesLinked = surfacesLinked
    }

    var isEmpty: Bool { desktop.isEmpty && (lockScreen?.isEmpty ?? true) && !surfacesLinked }

    func selection(for surface: WallpaperSurface) -> SurfaceAssignment? {
        surface == .desktop ? desktop : lockScreen
    }
    mutating func set(_ selection: SurfaceAssignment, for surface: WallpaperSurface) {
        if surfacesLinked {
            desktop = selection
            lockScreen = selection
        } else if surface == .desktop {
            desktop = selection
        } else {
            lockScreen = selection.isEmpty ? nil : selection
        }
    }
    mutating func setLinked(_ linked: Bool) {
        surfacesLinked = linked
        if linked { lockScreen = desktop }
    }

    private enum CodingKeys: String, CodingKey {
        case desktop, lockScreen, surfacesLinked
    }
}

extension DisplayAssignment {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Legacy flat assignments belong only to the desktop surface.
        desktop = c.contains(.desktop) ? try c.decode(SurfaceAssignment.self, forKey: .desktop) : try SurfaceAssignment(from: decoder)
        lockScreen = try c.decodeIfPresent(SurfaceAssignment.self, forKey: .lockScreen)
        surfacesLinked = try c.decodeIfPresent(Bool.self, forKey: .surfacesLinked) ?? false
        if surfacesLinked { lockScreen = desktop }
    }
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
    var blockedTags: [String] = []

    init() {}

    private enum CodingKeys: String, CodingKey {
        case wallpapers, playlists, displays, interval, shuffle, pauseOnBattery, pauseOnLowPower
        case pauseOnFullscreen, paused, displayMode, blockedTags
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wallpapers = try c.decode([Wallpaper].self, forKey: .wallpapers)
        playlists = try c.decode([Playlist].self, forKey: .playlists)
        displays = try c.decode([String: DisplayAssignment].self, forKey: .displays)
        interval = try c.decode(Double.self, forKey: .interval)
        shuffle = try c.decode(Bool.self, forKey: .shuffle)
        pauseOnBattery = try c.decode(Bool.self, forKey: .pauseOnBattery)
        pauseOnLowPower = try c.decodeIfPresent(Bool.self, forKey: .pauseOnLowPower)
        pauseOnFullscreen = try c.decode(Bool.self, forKey: .pauseOnFullscreen)
        paused = try c.decode(Bool.self, forKey: .paused)
        displayMode = try c.decodeIfPresent(String.self, forKey: .displayMode)
        blockedTags = normalizedTags((try c.decodeIfPresent([String].self, forKey: .blockedTags) ?? []).joined(separator: ","))
    }
    static var initial: LibraryState {
        var s = LibraryState()
        s.wallpapers = [
            Wallpaper(id: "aurora", title: "Northern lights", kind: "aurora", tags: "ambient, green, nature", metadata: SceneMetadata(category: "Nature", color: "Green", motion: "Low")),
            Wallpaper(id: "cosmos", title: "Deep space", kind: "cosmos", tags: "stars, blue, space", metadata: SceneMetadata(category: "Space", color: "Blue", motion: "Low")),
            Wallpaper(id: "ocean", title: "Quiet tides", kind: "ocean", tags: "water, calm, blue", metadata: SceneMetadata(category: "Nature", color: "Blue", motion: "Low")),
            Wallpaper(id: "ember", title: "Ember glow", kind: "ember", tags: "warm, abstract, orange", metadata: SceneMetadata(category: "Abstract", color: "Orange", motion: "Medium"))
        ]
        s.playlists = [Playlist(id: "ambient", name: "Slow mornings", items: ["aurora", "ocean", "cosmos", "ember"])]
        s.displayMode = "mirrored"
        return s
    }
    func item(_ id: String?) -> Wallpaper? { wallpapers.first { $0.id == id } }
    func playlist(_ id: String?) -> Playlist? { playlists.first { $0.id == id } }
    private mutating func store(_ assignment: DisplayAssignment, display: String) {
        displays[display] = assignment.isEmpty ? nil : assignment
    }
    private mutating func updateAssignment(display: String, surface: WallpaperSurface, _ change: (inout SurfaceAssignment) -> Void) {
        var assignment = displays[display] ?? DisplayAssignment()
        var selection = assignment.selection(for: surface) ?? SurfaceAssignment()
        change(&selection)
        assignment.set(selection, for: surface)
        store(assignment, display: display)
    }
    @discardableResult mutating func assign(_ wallpaperID: String, display: String, surface: WallpaperSurface = .desktop,
                                            playlistID: String? = nil, now: Date = Date()) -> Bool {
        guard item(wallpaperID) != nil,
              playlistID == nil || playlist(playlistID)?.items.contains(wallpaperID) == true else { return false }
        let ids = playlist(playlistID)?.items.filter { item($0) != nil } ?? []
        updateAssignment(display: display, surface: surface) {
            $0 = SurfaceAssignment(wallpaperID: wallpaperID, playlistID: playlistID,
                                   index: ids.firstIndex(of: wallpaperID) ?? 0, changedAt: now, mode: $0.mode)
        }
        return true
    }
    mutating func setMode(_ mode: WallpaperMode, display: String, surface: WallpaperSurface) {
        updateAssignment(display: display, surface: surface) { $0.mode = mode }
    }
    mutating func setSurfacesLinked(_ linked: Bool, display: String) {
        var assignment = displays[display] ?? DisplayAssignment()
        assignment.setLinked(linked)
        store(assignment, display: display)
    }
    mutating func stop(display: String, surface: WallpaperSurface = .desktop, now: Date = Date()) {
        updateAssignment(display: display, surface: surface) {
            $0 = SurfaceAssignment(changedAt: now, mode: $0.mode)
        }
    }
    mutating func removePlaylist(_ id: String) {
        playlists.removeAll { $0.id == id }
        for key in Array(displays.keys) {
            for surface in WallpaperSurface.allCases where displays[key]?.selection(for: surface)?.playlistID == id {
                updateAssignment(display: key, surface: surface) {
                    $0.playlistID = nil
                    $0.index = 0
                    $0.history = nil
                }
            }
        }
    }
    mutating func remove(_ id: String) {
        wallpapers.removeAll { $0.id == id }
        for i in playlists.indices { playlists[i].items.removeAll { $0 == id } }
        for key in Array(displays.keys) {
            guard var assignment = displays[key] else { continue }
            for surface in WallpaperSurface.allCases {
                if surface == .lockScreen && assignment.surfacesLinked { continue }
                guard var selection = assignment.selection(for: surface) else { continue }
                if selection.wallpaperID == id {
                    selection = SurfaceAssignment(mode: selection.mode)
                } else {
                    selection.history = selection.history.map { $0.filter { $0 != id } }
                    if let ids = playlist(selection.playlistID)?.items.filter({ item($0) != nil }),
                       let index = ids.firstIndex(of: selection.wallpaperID ?? "") { selection.index = index }
                }
                assignment.set(selection, for: surface)
            }
            store(assignment, display: key)
        }
    }
    mutating func advance(display: String, surface: WallpaperSurface = .desktop, now: Date = Date(), force: Bool = false, backwards: Bool = false) -> Wallpaper? {
        guard var a = displays[display]?.selection(for: surface), let p = playlist(a.playlistID) else { return nil }
        let ids = p.items.filter { item($0) != nil }
        guard !ids.isEmpty else { return nil }
        guard force || now.timeIntervalSince(a.changedAt) >= (p.interval ?? interval) else { return nil }
        let currentIndex = ids.firstIndex(of: a.wallpaperID ?? "") ?? ((a.index % ids.count) + ids.count) % ids.count
        if backwards {
            var history = (a.history ?? []).filter { ids.contains($0) }
            if let previous = history.popLast(), let index = ids.firstIndex(of: previous) { a.index = index }
            else { a.index = (currentIndex - 1 + ids.count) % ids.count }
            a.history = history
        } else {
            if let old = a.wallpaperID { a.history = Array(((a.history ?? []) + [old]).suffix(128)) }
            if (p.shuffle ?? shuffle) && ids.count > 1 {
                a.index = ids.indices.filter { ids[$0] != a.wallpaperID }.randomElement() ?? 0
            } else { a.index = (currentIndex + 1) % ids.count }
        }
        a.wallpaperID = ids[a.index]
        a.changedAt = now
        updateAssignment(display: display, surface: surface) { $0 = a }
        return item(a.wallpaperID)
    }
    mutating func advanceMirrored(displayIDs: [String], surface: WallpaperSurface = .desktop, now: Date = Date(), force: Bool = false, backwards: Bool = false) -> Wallpaper? {
        guard let source = displayIDs.first(where: { displays[$0]?.selection(for: surface)?.playlistID != nil }),
              advance(display: source, surface: surface, now: now, force: force, backwards: backwards) != nil else { return nil }
        return synchronizeMirrored(displayIDs: displayIDs, surface: surface, preferredSource: source)
    }
    mutating func synchronizeMirrored(displayIDs: [String], surface: WallpaperSurface = .desktop, preferredSource: String? = nil) -> Wallpaper? {
        let preferred = preferredSource.flatMap { displayIDs.contains($0) ? $0 : nil }
        let candidates = (preferred.map { [$0] } ?? []) + displayIDs
        guard let source = candidates.first(where: {
            guard let assignment = displays[$0] else { return false }
            return item(assignment.desktop.wallpaperID) != nil || item(assignment.lockScreen?.wallpaperID) != nil
                || (assignment.desktop.wallpaperID == nil && assignment.lockScreen?.wallpaperID == nil && !assignment.isEmpty)
        }), let assignment = displays[source] else { return nil }
        for id in displayIDs { displays[id] = assignment }
        return item(assignment.selection(for: surface)?.wallpaperID)
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

struct ProviderCatalog: Codable, Equatable {
    struct Item: Codable, Equatable {
        var id: String
        var title: String
        var kind: String
        var file: String
        var fit: String
    }
    var version = 1
    var items: [Item] = []
}

func providerCatalog(from state: LibraryState) -> ProviderCatalog {
    ProviderCatalog(items: state.wallpapers.compactMap { wallpaper in
        guard wallpaper.kind == "image" || wallpaper.kind == "video", !state.isBlocked(wallpaper),
              let name = wallpaper.file, name == (name as NSString).lastPathComponent, name != ".", name != ".." else { return nil }
        return .init(id: wallpaper.id, title: wallpaper.title, kind: wallpaper.kind, file: "Media/\(name)", fit: wallpaper.fit ? "fit" : "fill")
    })
}

final class LibraryDisk {
    let root: URL
    let assets: URL
    let manifest: URL
    let catalog: URL
    init(root: URL) throws {
        self.root = root
        assets = root.appendingPathComponent("Media", isDirectory: true)
        manifest = root.appendingPathComponent("library.json")
        catalog = root.appendingPathComponent("catalog.json")
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
        try encoder.encode(providerCatalog(from: state)).write(to: catalog, options: .atomic)
    }
    func url(for wallpaper: Wallpaper) -> URL? {
        guard let name = wallpaper.file,
              name == (name as NSString).lastPathComponent, name != ".", name != ".." else { return nil }
        return assets.appendingPathComponent(name)
    }
}

func normalizedTags(_ text: String) -> [String] {
    var seen = Set<String>()
    return text.split(separator: ",").compactMap { part in
        let tag = part.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased()
        return !tag.isEmpty && seen.insert(tag).inserted ? tag : nil
    }
}

struct MediaFacts: Codable, Equatable, Sendable {
    var width: Int?
    var height: Int?
    var bytes: Int64?
    var sourceDuration: Double?

    var hasDimensions: Bool { (width ?? 0) > 0 && (height ?? 0) > 0 }
    var resolution: String {
        guard hasDimensions else { return "Unknown" }
        let short = min(width!, height!), long = max(width!, height!)
        if short >= 2160 && long >= 3840 { return "4K+" }
        if short >= 1440 && long >= 2560 { return "1440p" }
        if short >= 1080 && long >= 1920 { return "1080p" }
        if short >= 720 && long >= 1280 { return "720p" }
        return "Below 720p"
    }
    var aspect: String {
        guard hasDimensions else { return "Unknown" }
        let ratio = Double(width!) / Double(height!)
        if ratio < 0.95 { return "Portrait" }
        if ratio <= 1.05 { return "Square" }
        return ratio >= 2 ? "Ultrawide" : "Standard"
    }
}

enum LibraryChoices {
    static let unknown = "Unknown"
    static let categories = ["Abstract", "Nature", "Space", "Urban", "Unknown"]
    static let colors = ["Red", "Orange", "Yellow", "Green", "Cyan", "Blue", "Purple", "Pink", "Neutral", "Unknown"]
    static let motions = ["Low", "Medium", "High", "Unknown"]
    static let resolutions = ["Below 720p", "720p", "1080p", "1440p", "4K+", "Unknown"]
    static let aspects = ["Portrait", "Square", "Standard", "Ultrawide", "Unknown"]

    static func classification(_ value: String?, choices: [String]) -> String {
        choices.first { $0.caseInsensitiveCompare(value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") == .orderedSame } ?? unknown
    }
}

extension Wallpaper {
    var category: String {
        let value = metadata?.category.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? LibraryChoices.unknown : value
    }
    var color: String { LibraryChoices.classification(metadata?.color, choices: LibraryChoices.colors) }
    var motion: String { LibraryChoices.classification(metadata?.motion, choices: LibraryChoices.motions) }
    var editedDuration: Double? {
        guard kind == "video", let duration = mediaFacts?.sourceDuration, duration.isFinite, duration > 0 else { return nil }
        let start = videoEdit?.start ?? 0, end = min(videoEdit?.end ?? duration, duration)
        guard start.isFinite, end.isFinite, start >= 0, end > start else { return nil }
        return end - start
    }
}

struct LibraryFilter: Equatable {
    var kind = "all"
    var categories = Set<String>()
    var colors = Set<String>()
    var motions = Set<String>()
    var resolutions = Set<String>()
    var aspects = Set<String>()
    var tags = Set<String>()

    var activeCount: Int {
        (kind == "all" ? 0 : 1) + categories.count + colors.count + motions.count + resolutions.count + aspects.count + tags.count
    }
    func matches(_ w: Wallpaper) -> Bool {
        func accepts(_ choices: Set<String>, _ value: String) -> Bool {
            choices.isEmpty || choices.contains { $0.caseInsensitiveCompare(value) == .orderedSame }
        }
        return (kind == "all" || (kind == "still" ? w.kind == "image" : w.kind != "image"))
            && accepts(categories, w.category) && accepts(colors, w.color) && accepts(motions, w.motion)
            && accepts(resolutions, w.mediaFacts?.resolution ?? "Unknown")
            && accepts(aspects, w.mediaFacts?.aspect ?? "Unknown")
            && (tags.isEmpty || !Set(normalizedTags(w.tags)).isDisjoint(with: normalizedTags(tags.sorted().joined(separator: ","))))
    }
}

extension LibraryState {
    func isBlocked(_ w: Wallpaper) -> Bool {
        !Set(normalizedTags(w.tags)).isDisjoint(with: normalizedTags(blockedTags.joined(separator: ",")))
    }
    func browsing(section: String, query: String = "", filter: LibraryFilter = LibraryFilter(), sort: String = "name") -> [Wallpaper] {
        let playlist = section.hasPrefix("playlist:") ? playlist(String(section.dropFirst(9))) : nil
        var values = wallpapers.filter { w in
            guard !isBlocked(w), filter.matches(w) else { return false }
            if section == "favorites" && !w.favorite { return false }
            if section == "imports" && w.file == nil { return false }
            if section.hasPrefix("playlist:") && !(playlist?.items.contains(w.id) ?? false) { return false }
            return query.isEmpty || (w.title + " " + w.tags + " " + w.kind).localizedCaseInsensitiveContains(query)
        }
        if let playlist { return playlist.items.compactMap { id in values.first { $0.id == id } } }
        if section == "browse" {
            values = values.sorted {
                if sort == "favorites", $0.favorite != $1.favorite { return $0.favorite }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }
        return values
    }
}

func classifiedColor(red: Double, green: Double, blue: Double) -> String {
    let high = max(red, green, blue), low = min(red, green, blue), delta = high - low
    guard high > 0.08, delta / high >= 0.18 else { return "Neutral" }
    var hue: Double
    if high == red { hue = (green - blue) / delta }
    else if high == green { hue = (blue - red) / delta + 2 }
    else { hue = (red - green) / delta + 4 }
    hue *= 60
    if hue < 0 { hue += 360 }
    switch hue {
    case 15..<45: return "Orange"
    case 45..<75: return "Yellow"
    case 75..<165: return "Green"
    case 165..<195: return "Cyan"
    case 195..<255: return "Blue"
    case 255..<285: return "Purple"
    case 285..<345: return "Pink"
    default: return "Red"
    }
}
