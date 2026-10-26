import Foundation

func resolvedDisplayMode(_ mode: String?) -> String {
    mode ?? "perDisplay"
}

func initialDisplaySelection(mode: String?, displayIDs: [String]) -> String {
    resolvedDisplayMode(mode) == "perDisplay" ? displayIDs.first ?? "all" : "all"
}

struct Wallpaper: Codable, Identifiable, Equatable, Sendable {
    var id: String = UUID().uuidString
    var title: String
    var kind: String
    var file: String?
    var tags: String = ""
    var favorite: Bool = false
    var speed: Double = 1
    var dimming: Double = 0
    var fit: Bool = false
    var videoEdit: VideoEdit?
    var metadata: SceneMetadata?
    var mediaFacts: MediaFacts?
    var dateAdded: Date?
    var sourceAttribution: WallpaperSourceAttribution?
}

struct WallpaperSourceAttribution: Codable, Equatable, Sendable {
    static let maximumModificationNoticeCount = 4096
    static let videoExportNotice = "Re-encoded and exported without audio by Flua."

    var catalogItemID: String
    var sourceName: String
    var sourceURL: String
    var creator: String
    var licenseName: String
    var licenseURL: String
    var modificationNotice: String?

    var isValid: Bool {
        let source = URLComponents(string: sourceURL)
        let license = URLComponents(string: licenseURL)
        return !catalogItemID.isEmpty && catalogItemID.count <= 200
            && !sourceName.isEmpty && sourceName.count <= 200
            && source?.scheme?.lowercased() == "https" && source?.host != nil
            && source?.user == nil && source?.password == nil
            && !creator.isEmpty && creator.count <= 500 && !licenseName.isEmpty && licenseName.count <= 200
            && license?.scheme?.lowercased() == "https" && license?.host != nil
            && license?.user == nil && license?.password == nil
            && (modificationNotice?.count ?? 0) <= Self.maximumModificationNoticeCount
                + ((modificationNotice?.contains(Self.videoExportNotice) ?? false) ? Self.videoExportNotice.count + 1 : 0)
    }
}

struct PlaybackPolicy: Codable, Equatable, Sendable {
    var pauseOnBattery: Bool
    var pauseOnLowPower: Bool
    var pauseOnLowBattery: Bool = false
    var lowPowerThreshold: Int
    var pauseOnFullscreen: Bool

    var clampedForExport: PlaybackPolicy {
        PlaybackPolicy(pauseOnBattery: pauseOnBattery, pauseOnLowPower: pauseOnLowPower,
                       pauseOnLowBattery: pauseOnLowBattery, lowPowerThreshold: min(100, max(0, lowPowerThreshold)), pauseOnFullscreen: pauseOnFullscreen)
    }

    private enum CodingKeys: String, CodingKey {
        case pauseOnBattery, pauseOnLowPower, pauseOnLowBattery, lowPowerThreshold, pauseOnFullscreen
    }

    init(pauseOnBattery: Bool, pauseOnLowPower: Bool, pauseOnLowBattery: Bool = false,
         lowPowerThreshold: Int, pauseOnFullscreen: Bool) {
        self.pauseOnBattery = pauseOnBattery
        self.pauseOnLowPower = pauseOnLowPower
        self.pauseOnLowBattery = pauseOnLowBattery
        self.lowPowerThreshold = lowPowerThreshold
        self.pauseOnFullscreen = pauseOnFullscreen
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pauseOnBattery = try c.decode(Bool.self, forKey: .pauseOnBattery)
        pauseOnLowPower = try c.decode(Bool.self, forKey: .pauseOnLowPower)
        pauseOnLowBattery = try c.decodeIfPresent(Bool.self, forKey: .pauseOnLowBattery) ?? pauseOnLowPower
        lowPowerThreshold = try c.decode(Int.self, forKey: .lowPowerThreshold)
        pauseOnFullscreen = try c.decode(Bool.self, forKey: .pauseOnFullscreen)
    }

    func encode(to encoder: Encoder) throws {
        let policy = clampedForExport
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(policy.pauseOnBattery, forKey: .pauseOnBattery)
        try c.encode(policy.pauseOnLowPower, forKey: .pauseOnLowPower)
        try c.encode(policy.pauseOnLowBattery, forKey: .pauseOnLowBattery)
        try c.encode(policy.lowPowerThreshold, forKey: .lowPowerThreshold)
        try c.encode(policy.pauseOnFullscreen, forKey: .pauseOnFullscreen)
    }
}

struct VideoEdit: Codable, Equatable, Sendable {
    var start: Double = 0
    var end: Double?
    var thumbnail: Double = 0
    var quality: String = "high"
}

func formatPercentage(_ value: Double) -> String {
    (value * 100).formatted(.number.locale(Locale(identifier: "en_US_POSIX")).precision(.fractionLength(0...2)))
}

// Invalid entries restore the field without changing the stored value.
func applyNumericEntry(draft: String, current: Double, range: ClosedRange<Double>, parse: (String) -> Double?, format: (Double) -> String) -> (Double, String) {
    let value: Double
    if let number = parse(draft.trimmingCharacters(in: .whitespacesAndNewlines)), number.isFinite, range.contains(number) {
        value = number
    } else {
        value = current
    }
    return (value, format(value))
}

func stillFrameTime(edit: VideoEdit?, duration: Double?) -> Double {
    let thumb = edit?.thumbnail ?? 0
    let requested = thumb.isFinite && thumb >= 0 ? thumb : 0
    guard let duration, duration.isFinite, duration > 0 else { return requested }
    let last = max(0, duration - 1.0 / 600)
    let start = edit?.start ?? 0
    let end = edit?.end ?? duration
    guard start.isFinite, end.isFinite, start >= 0, start < duration, end - start >= 0.1 else { return min(requested, last) }
    let lower = min(start, last)
    let upper = min(max(lower, min(end, duration) - 1.0 / 600), last)
    return min(max(requested, lower), upper)
}

func stillStamp(for wallpaper: Wallpaper) -> String {
    if wallpaper.kind == "video" { return String(format: "video %.6f", stillFrameTime(edit: wallpaper.videoEdit, duration: wallpaper.mediaFacts?.sourceDuration)) }
    if wallpaper.kind == "image" { return "image" }
    return "scene \(wallpaper.kind)"
}

struct SceneMetadata: Codable, Equatable, Sendable {
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

enum WallpaperSurface: CaseIterable, Hashable {
    case desktop, lockScreen
}

enum WallpaperMode: String, Codable, Sendable {
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

// Replay configuration edits against live assignments so playback and removal remain current.
struct ConfigurationDraft {
    enum Change {
        case displayMode(String, displays: [String], preferredSource: String?)
        case surfaceMode(WallpaperMode, displays: [String], surface: WallpaperSurface)
        case surfacesLinked(Bool, displays: [String])
    }
    var changes: [Change] = []

    func applying(to state: LibraryState) -> LibraryState {
        var result = state
        for change in changes {
            switch change {
            case let .displayMode(mode, displays, preferredSource):
                result.displayMode = mode
                if mode == "mirrored" { _ = result.synchronizeMirrored(displayIDs: displays, preferredSource: preferredSource) }
            case let .surfaceMode(mode, displays, surface):
                for id in displays { result.setMode(mode, display: id, surface: surface) }
            case let .surfacesLinked(linked, displays):
                for id in displays { result.setSurfacesLinked(linked, display: id) }
            }
        }
        return result
    }
}

struct LibraryState: Codable {
    var wallpapers: [Wallpaper] = []
    var playlists: [Playlist] = []
    var displays: [String: DisplayAssignment] = [:]
    var interval: Double = 3600
    var shuffle: Bool = true
    var pauseOnBattery: Bool = false
    var pauseOnLowPower: Bool?
    var pauseOnLowBattery: Bool = false
    var lowPowerThreshold: Int = 20
    var pauseOnFullscreen: Bool = true
    var paused: Bool = false
    var displayMode: String?
    var accentColor: String?
    var theme: String?
    var nativePlayback: [String: Bool] = [:]
    var nativeCleanupDisplays: Set<String> = []
    var blockedTags: [String] = []
    var showInMenuBar: Bool?
    var hideFromDock: Bool?
    var showWindowOnStartup: Bool = true

    init() {}

    func nativeRestorationDisplays(connected: [String], previouslyConnected: [String] = []) -> [String] {
        let previous = Set(previouslyConnected)
        return connected.filter { nativePlayback[$0] == true && !previous.contains($0) }
    }

    func nativeAssignmentChanges(from previous: [String: DisplayAssignment], displays: [String]) -> [String] {
        displays.filter { id in
            let old = previous[id] ?? DisplayAssignment()
            let updated = self.displays[id] ?? DisplayAssignment()
            return WallpaperSurface.allCases.contains { surface in
                let before = old.selection(for: surface)
                let after = updated.selection(for: surface)
                return before?.wallpaperID != after?.wallpaperID
                    || (before?.wallpaperID != nil && before?.mode != after?.mode)
            }
        }
    }

    func nativeAssignmentRefreshDisplays(changed: [String], connected: [String], mirrored: Bool) -> [String] {
        let candidates = mirrored ? connected : changed
        guard !nativeRestorationDisplays(connected: candidates).isEmpty else { return [] }
        return nativeRestorationDisplays(connected: connected)
    }

    func nativeApplicationDisplays(targeted: [String], connected: [String]) -> [String] {
        let selected = Set(targeted).union(nativeRestorationDisplays(connected: connected))
        return connected.filter { selected.contains($0) }
    }

    var showsMenuBar: Bool { showInMenuBar != false }
    var hidesDockIcon: Bool { showsMenuBar && hideFromDock == true }

    mutating func setShowsMenuBar(_ shown: Bool) {
        showInMenuBar = shown ? nil : false
        if !shown { hideFromDock = nil }
    }

    mutating func setHidesDockIcon(_ hidden: Bool) {
        hideFromDock = showsMenuBar && hidden ? true : nil
    }

    private enum CodingKeys: String, CodingKey {
        case wallpapers, playlists, displays, interval, shuffle, pauseOnBattery, pauseOnLowPower, pauseOnLowBattery
        case lowPowerThreshold, pauseOnFullscreen, paused, displayMode, blockedTags, accentColor, theme, nativePlayback, nativeCleanupDisplays
        case showInMenuBar, hideFromDock, showWindowOnStartup
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
        pauseOnLowBattery = try c.decodeIfPresent(Bool.self, forKey: .pauseOnLowBattery) ?? (pauseOnLowPower ?? false)
        lowPowerThreshold = try c.decodeIfPresent(Int.self, forKey: .lowPowerThreshold) ?? 20
        pauseOnFullscreen = try c.decode(Bool.self, forKey: .pauseOnFullscreen)
        paused = try c.decode(Bool.self, forKey: .paused)
        displayMode = try c.decodeIfPresent(String.self, forKey: .displayMode)
        nativePlayback = try c.decodeIfPresent([String: Bool].self, forKey: .nativePlayback) ?? [:]
        nativeCleanupDisplays = try c.decodeIfPresent(Set<String>.self, forKey: .nativeCleanupDisplays) ?? []
        accentColor = try c.decodeIfPresent(String.self, forKey: .accentColor)
        theme = try c.decodeIfPresent(String.self, forKey: .theme)
        blockedTags = normalizedTags((try c.decodeIfPresent([String].self, forKey: .blockedTags) ?? []).joined(separator: ","))
        showInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showInMenuBar)
        hideFromDock = try c.decodeIfPresent(Bool.self, forKey: .hideFromDock)
        showWindowOnStartup = try c.decodeIfPresent(Bool.self, forKey: .showWindowOnStartup) ?? true
        if !showsMenuBar { hideFromDock = nil }
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
        s.interval = 3600
        s.shuffle = true
        s.pauseOnLowPower = true
        s.pauseOnLowBattery = true
        return s
    }
    func item(_ id: String?) -> Wallpaper? { wallpapers.first { $0.id == id } }
    func playlist(_ id: String?) -> Playlist? { playlists.first { $0.id == id } }
    func isPlayable(_ wallpaper: Wallpaper) -> Bool {
        guard !isBlocked(wallpaper) else { return false }
        if builtInSceneKinds.contains(wallpaper.kind) { return true }
        guard wallpaper.kind == "image" || wallpaper.kind == "video",
              let name = wallpaper.file, name == (name as NSString).lastPathComponent,
              name != ".", name != ".." else { return false }
        return true
    }
    func playableItems(in playlist: Playlist) -> [Wallpaper] {
        playlist.items.compactMap { item($0) }.filter { isPlayable($0) }
    }
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
        guard force || now.timeIntervalSince(a.changedAt) >= (p.interval ?? interval) else { return nil }
        let ids = p.items.filter { item($0) != nil }
        let eligible = Set(playableItems(in: p).map(\.id))
        guard !eligible.isEmpty else { return nil }
        let currentIndex = ids.firstIndex(of: a.wallpaperID ?? "") ?? ((a.index % ids.count) + ids.count) % ids.count
        if backwards {
            var history = (a.history ?? []).filter { eligible.contains($0) }
            if let previous = history.popLast(), let index = ids.firstIndex(of: previous) { a.index = index }
            else {
                let previous = (1...ids.count).map { (currentIndex - $0 + ids.count * 2) % ids.count }
                    .first { eligible.contains(ids[$0]) }!
                a.index = previous
            }
            a.history = history
        } else {
            if let old = a.wallpaperID { a.history = Array(((a.history ?? []) + [old]).suffix(128)) }
            if (p.shuffle ?? shuffle) && eligible.count > 1 {
                a.index = ids.indices.filter { eligible.contains(ids[$0]) && ids[$0] != a.wallpaperID }.randomElement()!
            } else {
                a.index = (1...ids.count).map { (currentIndex + $0) % ids.count }
                    .first { eligible.contains(ids[$0]) }!
            }
        }
        a.wallpaperID = ids[a.index]
        a.changedAt = now
        updateAssignment(display: display, surface: surface) { $0 = a }
        return item(a.wallpaperID)
    }
    mutating func advanceMirrored(displayIDs: [String], surface: WallpaperSurface = .desktop, now: Date = Date(), force: Bool = false, backwards: Bool = false) -> Wallpaper? {
        guard let source = displayIDs.first(where: { displays[$0]?.selection(for: surface)?.playlistID != nil }),
              advance(display: source, surface: surface, now: now, force: force, backwards: backwards) != nil else { return nil }
        synchronizeMirroredSurface(displayIDs: displayIDs, surface: surface, source: source)
        return item(displays[source]?.selection(for: surface)?.wallpaperID)
    }
    mutating func advancePlaylists(displayIDs: [String], targetDisplayIDs: [String], stoppedDisplayIDs: Set<String>,
                                   surfaces: [WallpaperSurface], mirrored: Bool, now: Date, force: Bool,
                                   backwards: Bool) -> [String: Set<WallpaperSurface>] {
        let targets = targetDisplayIDs.filter { displayIDs.contains($0) && (force || !stoppedDisplayIDs.contains($0)) }
        guard !targets.isEmpty else { return [:] }
        let previous = displays
        var changed: [String: Set<WallpaperSurface>] = [:]
        for surface in surfaces {
            let candidates = targets.filter { id in
                guard let assignment = displays[id] else { return false }
                return surface != .lockScreen || !surfaces.contains(.desktop) || !assignment.surfacesLinked
            }
            guard !candidates.isEmpty else { continue }
            if mirrored {
                _ = advanceMirrored(displayIDs: candidates, surface: surface, now: now, force: force, backwards: backwards)
            } else {
                for id in candidates {
                    _ = advance(display: id, surface: surface, now: now, force: force, backwards: backwards)
                }
            }
        }
        for id in targets {
            for surface in WallpaperSurface.allCases {
                if previous[id]?.selection(for: surface) != displays[id]?.selection(for: surface) {
                    changed[id, default: []].insert(surface)
                }
            }
        }
        return changed
    }
    private mutating func synchronizeMirroredSurface(displayIDs: [String], surface: WallpaperSurface, source: String) {
        guard let selection = displays[source]?.selection(for: surface) else { return }
        for id in displayIDs {
            var assignment = displays[id] ?? DisplayAssignment()
            assignment.set(selection, for: surface)
            store(assignment, display: id)
        }
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
        case .unreadableMedia(let name): return "Could not open \(name). Choose a supported image or a self-contained video."
        }
    }
}

struct ProviderCatalog: Codable, Equatable, Sendable {
    struct Item: Codable, Equatable, Sendable {
        var id: String
        var title: String
        var kind: String
        var file: String
        var fit: String
        var speed: Double = 1
        var dimming: Double = 0
        var trimStart: Double?
        var trimEnd: Double?
        var still: Double?
        var desktop: WallpaperMode = .animated
        var lockScreen: WallpaperMode = .animated
        var playbackPolicy: PlaybackPolicy?
        var thumbnail: String?
    }
    var version = 1
    var items: [Item] = []
    var playbackPolicy: PlaybackPolicy?
}

// shortcut: one mode per wallpaper per surface; conflicting displays publish animated until the host takes a choice per display.
func publishedSurfaceMode(_ surface: WallpaperSurface, wallpaper id: String, in state: LibraryState) -> WallpaperMode {
    let modes = Set(state.displays.values.compactMap { assignment -> WallpaperMode? in
        guard let selection = assignment.selection(for: surface), selection.wallpaperID == id else { return nil }
        return selection.mode
    })
    return modes.count == 1 ? modes.first! : .animated
}

let builtInSceneKinds: Set<String> = ["aurora", "cosmos", "ocean", "ember"]

func providerCatalog(from state: LibraryState) -> ProviderCatalog {
    let playbackPolicy = PlaybackPolicy(
        pauseOnBattery: state.pauseOnBattery,
        pauseOnLowPower: state.pauseOnLowPower ?? false,
        pauseOnLowBattery: state.pauseOnLowBattery,
        lowPowerThreshold: state.lowPowerThreshold,
        pauseOnFullscreen: state.pauseOnFullscreen
    ).clampedForExport
    return ProviderCatalog(items: state.wallpapers.compactMap { wallpaper in
        guard state.isPlayable(wallpaper) else { return nil }
        // The provider draws these scenes, so a choice needs no media file. Still is the desktop thumbnail time.
        if builtInSceneKinds.contains(wallpaper.kind) {
            return .init(id: wallpaper.id, title: wallpaper.title, kind: wallpaper.kind, file: "",
                         fit: wallpaper.fit ? "fit" : "fill", speed: wallpaper.speed, dimming: wallpaper.dimming, still: 7,
                         desktop: publishedSurfaceMode(.desktop, wallpaper: wallpaper.id, in: state),
                         lockScreen: publishedSurfaceMode(.lockScreen, wallpaper: wallpaper.id, in: state),
                         playbackPolicy: playbackPolicy)
        }
        guard wallpaper.kind == "image" || wallpaper.kind == "video",
              let name = wallpaper.file, name == (name as NSString).lastPathComponent, name != ".", name != ".." else { return nil }
        var trimStart: Double?
        var trimEnd: Double?
        if wallpaper.kind == "video", let edit = wallpaper.videoEdit, let end = edit.end, end > edit.start, edit.start >= 0 {
            trimStart = edit.start
            trimEnd = end
        }
        let still = wallpaper.kind == "video" ? stillFrameTime(edit: wallpaper.videoEdit, duration: wallpaper.mediaFacts?.sourceDuration) : nil
        return .init(id: wallpaper.id, title: wallpaper.title, kind: wallpaper.kind, file: "Media/\(name)",
                     fit: wallpaper.fit ? "fit" : "fill", speed: wallpaper.speed, dimming: wallpaper.dimming,
                     trimStart: trimStart, trimEnd: trimEnd, still: still,
                     desktop: publishedSurfaceMode(.desktop, wallpaper: wallpaper.id, in: state),
                     lockScreen: publishedSurfaceMode(.lockScreen, wallpaper: wallpaper.id, in: state),
                     playbackPolicy: playbackPolicy)
    }, playbackPolicy: playbackPolicy)
}

final class LibraryDisk {
    let root: URL
    let assets: URL
    let manifest: URL
    let catalog: URL
    var thumbnails: [String: String] = [:]
    private let catalogWriter = CatalogWriter()
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
    // The manifest commits the library; a derived catalog failure must not roll it back.
    @discardableResult func save(_ state: LibraryState) throws -> Error? {
        try saveManifest(state)
        do { try saveCatalog(state); return nil }
        catch { return error }
    }
    func saveManifest(_ state: LibraryState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: manifest, options: .atomic)
    }
    private func catalogSnapshot(_ state: LibraryState) -> ProviderCatalog {
        var value = providerCatalog(from: state)
        for index in value.items.indices {
            value.items[index].thumbnail = thumbnails[value.items[index].id]
        }
        return value
    }
    func saveCatalog(_ state: LibraryState) throws {
        try catalogWriter.save(catalogSnapshot(state), to: catalog)
    }
    func publishCatalog(_ state: LibraryState, completion: @escaping @Sendable (Error?) -> Void) {
        catalogWriter.publish(catalogSnapshot(state), to: catalog, completion: completion)
    }
    @MainActor func publishCatalog(_ state: LibraryState) async -> Error? {
        await withCheckedContinuation { continuation in
            publishCatalog(state) { continuation.resume(returning: $0) }
        }
    }
    @MainActor func finishCatalogWrites() async {
        await catalogWriter.finish()
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
    var source = "all"
    var categories = Set<String>()
    var colors = Set<String>()
    var motions = Set<String>()
    var resolutions = Set<String>()
    var aspects = Set<String>()
    var tags = Set<String>()

    var activeCount: Int {
        (source == "all" ? 0 : 1) + (kind == "all" ? 0 : 1) + categories.count + colors.count + motions.count + resolutions.count + aspects.count + tags.count
    }
    func matches(_ w: Wallpaper) -> Bool {
        func accepts(_ choices: Set<String>, _ value: String) -> Bool {
            choices.isEmpty || choices.contains { $0.caseInsensitiveCompare(value) == .orderedSame }
        }
        return (source == "all" || (source == "builtin" ? w.file == nil : w.file != nil))
            && (kind == "all" || (kind == "still" ? w.kind == "image" : w.kind != "image"))
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
        if playlist == nil {
            values = values.sorted {
                if sort == "recent", $0.dateAdded != $1.dateAdded { return ($0.dateAdded ?? .distantPast) > ($1.dateAdded ?? .distantPast) }
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

// All catalog encoding, cache access and writes share one queue, including synchronous fixtures.
private final class CatalogWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Flua.catalog", qos: .utility)
    private var published: ProviderCatalog?
    private var identity: NSDictionary?

    private func fileIdentity(_ url: URL) throws -> NSDictionary {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes as NSDictionary
    }
    private func write(_ value: ProviderCatalog, to url: URL) throws {
        if published == value, let identity, let current = try? fileIdentity(url), identity == current { return }
        // A failed publication must retry even when its input matches the last success.
        published = nil
        identity = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
        identity = try fileIdentity(url)
        published = value
    }
    func save(_ value: ProviderCatalog, to url: URL) throws {
        try queue.sync { try write(value, to: url) }
    }
    func publish(_ value: ProviderCatalog, to url: URL, completion: @escaping @Sendable (Error?) -> Void) {
        queue.async {
            do { try self.write(value, to: url); completion(nil) }
            catch { completion(error) }
        }
    }
    func finish() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }
}
