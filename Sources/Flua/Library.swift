import AppKit
import AVFoundation
import Combine
import ServiceManagement
import UniformTypeIdentifiers

final class Library: ObservableObject {
    @Published var state: LibraryState
    @Published private var configurationDraft = ConfigurationDraft()
    @Published private var wallpaperDrafts: [String: Wallpaper] = [:]
    @Published var selection: String? = "aurora"
    @Published var section: String = "all"
    @Published var query = ""
    @Published var filter = LibraryFilter()
    @Published var browseSort = "name"
    @Published var surface: WallpaperSurface = .desktop
    @Published var display = "all"
    @Published var screens = NSScreen.screens
    @Published var error: String?
    @Published var importing = false
    @Published var importNotice: String?
    private(set) var lastImportIDs: [String] = []
    @Published var nativeSetupBusy = false
    @Published var activity = "Choose a wallpaper to preview and set on your desktop."
    @Published var thumbnails: [String: NSImage] = [:]
    let disk: LibraryDisk
    private let systemPlaybackEnabled: Bool
    var tick: Timer?
    private var screenObserver: NSObjectProtocol?
    private var saveBlocked = false
    private var nativeRefreshTask: Task<Void, Never>?
    private var automaticPlaylistPlaybackEnabled = false
    private var stoppedNativeDisplays = Set<String>()
    private var pendingNativeAssignmentDisplays = Set<String>()
    private var pendingNativeEdits = Set<String>()
    var importTasks = Set<UUID>()
    var onChange: (() -> Void)?

    init(root: URL, systemPlaybackEnabled: Bool = true) throws {
        self.systemPlaybackEnabled = systemPlaybackEnabled
        disk = try LibraryDisk(root: root)
        do { state = try disk.load() }
        catch { state = .initial; saveBlocked = true; self.error = error.localizedDescription }
        stoppedNativeDisplays = Set(state.nativePlayback.filter { !$0.value }.keys)
        selection = state.wallpapers.first(where: { !state.isBlocked($0) })?.id
        display = initialDisplaySelection(mode: state.displayMode, displayIDs: screens.map(displayID))
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let previousDisplays = self.screens.map(displayID)
            self.screens = NSScreen.screens
            let reconnected = self.state.nativeRestorationDisplays(connected: self.screens.map(displayID), previouslyConnected: previousDisplays)
            if self.display != "all" && !self.screens.contains(where: { displayID($0) == self.display }) {
                self.display = self.playbackMode == "perDisplay" ? self.screens.first.map(displayID) ?? "all" : "all"
            }
            if self.restoreAssignments() { self.save() }
            if !reconnected.isEmpty {
                Task { @MainActor [weak self] in self?.restoreNativeAssignments(displays: reconnected) }
            }
        }
        tick = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.advancePlaylists(force: false) }
        }
        RunLoop.main.add(tick!, forMode: .common)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.restoreAssignments() { self.save() }
            self.makeThumbnails()
            self.backfillMetadata()
        }
    }
    var selected: Wallpaper? { selection.flatMap { previewWallpaper($0) } }
    func previewWallpaper(_ id: String) -> Wallpaper? {
        guard var value = state.item(id) else { return nil }
        if let draft = wallpaperDrafts[id] {
            value.fit = draft.fit
            value.speed = draft.speed
            value.dimming = draft.dimming
        }
        return value
    }
    func editConfiguration(_ value: Wallpaper) {
        wallpaperDrafts[value.id] = value
    }
    private var configuredState: LibraryState { configurationDraft.applying(to: state) }
    var visible: [Wallpaper] {
        var collection = state
        if importNotice != nil, section == "all" {
            collection.wallpapers = state.wallpapers.filter { !state.isBlocked($0) || lastImportIDs.contains($0.id) }
            collection.blockedTags = []
        }
        return collection.browsing(section: section, query: query, filter: filter, sort: browseSort)
    }
    var eligible: [Wallpaper] { state.browsing(section: "all", query: query, filter: filter) }
    func filterTag(_ tag: String) {
        importNotice = nil
        filter.tags.formUnion(normalizedTags(tag))
        section = "all"
    }
    func clearFilters() { filter = LibraryFilter(); query = ""; browseSort = "name" }
    func blockTags(_ text: String) {
        importNotice = nil
        state.blockedTags = normalizedTags((state.blockedTags + normalizedTags(text)).joined(separator: ","))
        clearBlockedSelection()
        save()
    }
    func unblockTag(_ tag: String) {
        state.blockedTags.removeAll { normalizedTags($0) == normalizedTags(tag) }
        save()
    }
    private func clearBlockedSelection() {
        if let w = selected, state.isBlocked(w) { selection = nil }
    }
    var sectionTitle: String {
        switch section {
        case "discover": return "Wallpapers"
        case "browse": return "Wallpapers"
        case "favorites": return "Favorites"
        case "imports": return "Wallpapers"
        case "all": return "Wallpapers"
        default:
            if section.hasPrefix("playlist:") { return state.playlist(String(section.dropFirst(9)))?.name ?? "Playlist" }
            return "Library"
        }
    }
    var playbackMode: String { resolvedDisplayMode(configuredState.displayMode) }
    var targets: [NSScreen] {
        if playbackMode == "mirrored" { return screens }
        return screens.filter { displayID($0) == display || (display == "all" && $0 == screens.first) }
    }
    private var playbackTargets: [NSScreen] {
        if resolvedDisplayMode(state.displayMode) == "mirrored" { return screens }
        return screens.filter { displayID($0) == display || (display == "all" && $0 == screens.first) }
    }
    var hasActivePlaylist: Bool {
        !nativeSetupBusy && playbackTargets.contains { screen in
            let id = displayID(screen)
            return state.nativePlayback[id] != false
                && state.playlist(state.displays[id]?.selection(for: surface)?.playlistID) != nil
        }
    }
    func setPlaybackMode(_ mode: String) {
        configurationDraft.changes.append(.displayMode(mode, displays: screens.map(displayID), preferredSource: display == "all" ? nil : display))
    }
    var targetAssignments: [DisplayAssignment] {
        targets.map { configuredState.displays[displayID($0)] ?? DisplayAssignment() }
    }
    var surfacesLinked: Bool { !targetAssignments.isEmpty && targetAssignments.allSatisfy(\.surfacesLinked) }
    var surfaceMode: WallpaperMode? {
        let modes = targetAssignments.map { $0.selection(for: surface)?.mode ?? .animated }
        guard let first = modes.first, modes.allSatisfy({ $0 == first }) else { return nil }
        return first
    }
    func surfaceSummary(_ surface: WallpaperSurface) -> String {
        let summaries = targetAssignments.map { assignment in
            let selection = assignment.selection(for: surface) ?? SurfaceAssignment()
            let title = state.item(selection.wallpaperID)?.title ?? "Unassigned"
            return "\(title) · \(selection.mode == .still ? "Still" : "Animated")"
        }
        guard let first = summaries.first else { return "No display" }
        return summaries.allSatisfy { $0 == first } ? first : "Mixed assignments"
    }
    func setSurfaceMode(_ mode: WallpaperMode) {
        configurationDraft.changes.append(.surfaceMode(mode, displays: targets.map(displayID), surface: surface))
    }
    func setSurfacesLinked(_ linked: Bool) {
        configurationDraft.changes.append(.surfacesLinked(linked, displays: targets.map(displayID)))
        // Linked surfaces have no independent Lock Screen target.
        if linked && surface == .lockScreen { surface = .desktop }
    }
    func save() {
        guard !saveBlocked else { error = LibraryError.invalidLibrary.localizedDescription; return }
        do { try disk.save(state) } catch { self.error = error.localizedDescription }
        onChange?()
    }
    func settingChanged() { save() }
    @MainActor func applySelected() {
        guard !nativeSetupBusy, let w = selected else { return }
        state = configuredState
        for index in state.wallpapers.indices {
            if let value = previewWallpaper(state.wallpapers[index].id) {
                state.wallpapers[index].fit = value.fit
                state.wallpapers[index].speed = value.speed
                state.wallpapers[index].dimming = value.dimming
            }
        }
        configurationDraft = ConfigurationDraft()
        wallpaperDrafts.removeAll()
        let ids = playbackTargets.map(displayID)
        for id in ids { state.assign(w.id, display: id, surface: surface) }
        save()
        applySavedNativeAssignments(displays: ids, surface: surface)
    }
    @MainActor func startPlaylist(_ id: String) {
        guard !nativeSetupBusy else { return }
        guard let p = state.playlist(id) else { error = "This playlist is unavailable."; return }
        guard let w = state.playableItems(in: p).first else { error = "This playlist has no playable wallpapers. Unblock a wallpaper or add another one."; return }
        let now = Date()
        let ids = playbackTargets.map(displayID)
        for id in ids { state.assign(w.id, display: id, surface: surface, playlistID: p.id, now: now) }
        activity = "Playlist: \(p.name)"
        save()
        applySavedNativeAssignments(displays: ids, surface: surface)
    }
    @discardableResult func restoreAssignments(preferredDisplay: String? = nil) -> Bool {
        let previousDisplays = state.displays
        if resolvedDisplayMode(state.displayMode) == "mirrored" {
            _ = state.synchronizeMirrored(displayIDs: screens.map(displayID), preferredSource: preferredDisplay)
        }
        return state.displays != previousDisplays
    }
    @MainActor func advancePlaylists(force: Bool, backwards: Bool = false, allDisplays: Bool = false) {
        guard !nativeSetupBusy, force || automaticPlaylistPlaybackEnabled, !state.paused || force else { return }
        let now = Date()
        let displayIDs = screens.map(displayID)
        let manual = force
        let targets = manual
            ? (allDisplays ? displayIDs : playbackTargets.map(displayID))
            : displayIDs
        let surfaces = manual ? [surface] : WallpaperSurface.allCases
        for key in targets {
            if !force && stoppedNativeDisplays.contains(key) { continue }
            for targetSurface in surfaces {
                guard targetSurface != .lockScreen || !surfaces.contains(.desktop) || state.displays[key]?.surfacesLinked != true,
                      let assignment = state.displays[key]?.selection(for: targetSurface),
                      let playlist = state.playlist(assignment.playlistID),
                      force || now.timeIntervalSince(assignment.changedAt) >= (playlist.interval ?? state.interval) else { continue }
                guard state.playableItems(in: playlist).isEmpty else { continue }
                error = "A playlist has no playable wallpapers. Unblock a wallpaper or add another one."
            }
        }
        var next = state
        let changed = next.advancePlaylists(displayIDs: displayIDs, targetDisplayIDs: targets,
            stoppedDisplayIDs: stoppedNativeDisplays, surfaces: surfaces,
            mirrored: resolvedDisplayMode(state.displayMode) == "mirrored", now: now,
            force: force, backwards: backwards)
        if !changed.isEmpty {
            state = next
            save()
            applySavedNativeAssignments(displays: displayIDs.filter { changed[$0] != nil })
        }
    }
    func stop() {
        guard !nativeSetupBusy else { return }
        let ids = playbackTargets.map(displayID)
        pendingNativeAssignmentDisplays.subtract(ids)
        if nativeRoutingAvailable {
            let mirrored = resolvedDisplayMode(state.displayMode) == "mirrored"
            let root = disk.root
            nativeSetupBusy = true
            Task { @MainActor in
                defer { nativeSetupBusy = false }
                do {
                    let nativeStopped = try await Task.detached { try NativeWallpaper.stop(displays: ids, mirrored: mirrored, root: root) }.value
                    state.nativeCleanupDisplays.subtract(ids)
                    for id in ids {
                        if !nativeStopped && !stoppedNativeDisplays.contains(id) {
                            if state.nativePlayback[id] != nil {
                                state.nativePlayback[id] = false
                                stoppedNativeDisplays.insert(id)
                            } else { state.stop(display: id) }
                        }
                    }
                    if nativeStopped {
                        stoppedNativeDisplays.formUnion(ids)
                        for id in ids { state.nativePlayback[id] = false }
                        save()
                        activity = "Wallpapers stopped. Previous system wallpapers restored; saved choices retained."
                    } else {
                        activity = "Wallpaper stopped. Your system wallpaper is visible."
                        save()
                    }
                } catch { self.error = error.localizedDescription }
            }
            return
        }
        for screen in playbackTargets {
            let id = displayID(screen)
            if state.nativePlayback[id] != nil {
                state.nativePlayback[id] = false
                stoppedNativeDisplays.insert(id)
            } else { state.stop(display: id) }
        }
        activity = "Wallpaper stopped. Your system wallpaper is visible."
        save()
    }
    func togglePlaylistPause() {
        state.paused.toggle()
        settingChanged()
        activity = state.paused ? "Playlists paused. Wallpapers keep playing." : "Playlists resumed."
    }
    private var nativeRoutingAvailable: Bool {
        systemPlaybackEnabled && NativeWallpaper.available && NativeWallpaper.catalogURL.resolvingSymlinksInPath() == disk.catalog.resolvingSymlinksInPath()
    }
    @MainActor private func restoreNativeAssignments(displays: [String]? = nil) {
        guard !saveBlocked, nativeRoutingAvailable else { return }
        let ids = state.nativeRestorationDisplays(connected: screens.map(displayID)).filter { displays?.contains($0) ?? true }
        guard !ids.isEmpty else { return }
        if nativeSetupBusy {
            Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                self?.restoreNativeAssignments(displays: ids)
            }
            return
        }
        let cleanup = ids.filter { state.nativeCleanupDisplays.contains($0) }
        if !cleanup.isEmpty {
            applySavedNativeAssignments(displays: cleanup, reloadUnchanged: false, clearingUnassigned: true)
            let remaining = ids.filter { !cleanup.contains($0) }
            if !remaining.isEmpty { restoreNativeAssignments(displays: remaining) }
        } else {
            applySavedNativeAssignments(displays: ids, reloadUnchanged: false)
        }
    }
    @MainActor func applySavedNativeAssignments() {
        let connected = screens.map(displayID)
        let displays = state.nativeApplicationDisplays(targeted: playbackTargets.map(displayID), connected: connected)
        applySavedNativeAssignments(displays: displays)
    }
    @MainActor private func applySavedNativeAssignments(displays: [String], reloadUnchanged: Bool = true, surface: WallpaperSurface? = nil, clearingUnassigned: Bool = false) {
        guard !nativeSetupBusy else { return }
        guard !saveBlocked else { error = LibraryError.invalidLibrary.localizedDescription; return }
        if systemPlaybackEnabled {
            guard NativeWallpaper.available else { error = NativeWallpaper.explanation; return }
            guard NativeWallpaper.catalogURL.resolvingSymlinksInPath() == disk.catalog.resolvingSymlinksInPath() else {
                error = "This build uses a different library. Rebuild it with FLUA_CATALOG_PATH set to this library’s catalog.json."
                return
            }
        }
        do { try disk.save(state) } catch { self.error = error.localizedDescription; return }
        let assignments: [String: NativeWallpaperStore.Assignment]
        do { assignments = try savedNativeAssignments(for: displays, surface: surface) }
        catch { self.error = error.localizedDescription; return }
        guard !assignments.isEmpty || displays.contains(where: { state.nativePlayback[$0] == true }) else {
            error = "Save a wallpaper choice for the targeted displays first."
            return
        }
        // Isolated smoke runs validate real descriptors without touching the system wallpaper store.
        guard systemPlaybackEnabled else {
            automaticPlaylistPlaybackEnabled = true
            activity = "Validated saved wallpaper choices. System playback is disabled for verification."
            return
        }
        pendingNativeAssignmentDisplays.subtract(displays)
        let mirrored = resolvedDisplayMode(state.displayMode) == "mirrored" && Set(displays) == Set(screens.map(displayID))
        nativeSetupBusy = true
        let root = disk.root
        Task {
            defer { nativeSetupBusy = false }
            do {
                try await Task.detached { try NativeWallpaper.apply(assignments, targeting: displays, mirrored: mirrored, root: root, reloadUnchanged: reloadUnchanged, clearingUnassigned: clearingUnassigned) }.value
                if clearingUnassigned { state.nativeCleanupDisplays.subtract(displays) }
                rememberNativeAssignments(assignments, displays: displays)
                activity = assignments.isEmpty
                    ? "Previous system wallpapers restored; no saved native choices remain for the targeted displays."
                    : "Applied saved wallpaper choices to \(assignments.count) display(s). Native playback continues after Flua quits."
            } catch { self.error = error.localizedDescription }
        }
    }
    private func savedNativeAssignments(for displays: [String], surface: WallpaperSurface? = nil) throws -> [String: NativeWallpaperStore.Assignment] {
        let hasSavedChoice = displays.contains { id in
            guard let assignment = state.displays[id] else { return false }
            return assignment.desktop.wallpaperID != nil || assignment.lockScreen?.wallpaperID != nil
        }
        guard hasSavedChoice else { return [:] }
        return try NativeWallpaperStore.assignments(from: state, displays: displays, root: disk.root, provider: NativeWallpaper.identifier, surface: surface)
    }
    private func rememberNativeAssignments(_ assignments: [String: NativeWallpaperStore.Assignment], displays: [String]) {
        automaticPlaylistPlaybackEnabled = true
        for id in displays {
            let active = assignments[id] != nil
            state.nativePlayback[id] = active
            if active { stoppedNativeDisplays.remove(id) } else { stoppedNativeDisplays.insert(id) }
        }
        save()
    }
    @MainActor func removeNativeProvider() {
        guard systemPlaybackEnabled else { return }
        guard !nativeSetupBusy else { return }
        guard !saveBlocked else { error = LibraryError.invalidLibrary.localizedDescription; return }
        guard NativeWallpaper.catalogURL.resolvingSymlinksInPath() == disk.catalog.resolvingSymlinksInPath() else {
            error = "This build uses a different library. Open the library used to set up native playback."
            return
        }
        nativeRefreshTask?.cancel()
        pendingNativeAssignmentDisplays.removeAll()
        pendingNativeEdits.removeAll()
        nativeSetupBusy = true
        let root = disk.root
        Task {
            defer { nativeSetupBusy = false }
            do {
                try await Task.detached { try NativeWallpaper.remove(root: root) }.value
                state.nativeCleanupDisplays.removeAll()
                for id in state.nativePlayback.keys {
                    state.nativePlayback[id] = false
                    stoppedNativeDisplays.insert(id)
                }
                save()
                activity = "Native provider removed. Previous system wallpapers restored; your library is preserved."
            } catch { self.error = error.localizedDescription }
        }
    }
    func edit(_ value: Wallpaper) {
        guard let i = state.wallpapers.firstIndex(where: { $0.id == value.id }) else { return }
        let previous = providerCatalog(from: state).items.first { $0.id == value.id }
        var updated = value
        updated.mediaFacts = state.wallpapers[i].mediaFacts
        updated.dateAdded = state.wallpapers[i].dateAdded
        if updated.metadata == nil { updated.metadata = state.wallpapers[i].metadata }
        if updated.metadata?.color == nil { updated.metadata?.color = state.wallpapers[i].metadata?.color }
        if updated.metadata?.motion == nil { updated.metadata?.motion = state.wallpapers[i].metadata?.motion }
        state.wallpapers[i] = updated
        clearBlockedSelection()
        save()
        let current = providerCatalog(from: state).items.first { $0.id == value.id }
        if let previous, let current,
           previous.fit != current.fit || previous.speed != current.speed || previous.dimming != current.dimming ||
           previous.trimStart != current.trimStart || previous.trimEnd != current.trimEnd || previous.still != current.still {
            pendingNativeEdits.insert(value.id)
            scheduleNativeRefresh()
        }
    }
    private func scheduleNativeAssignmentRefresh(for displays: [String]) {
        guard nativeRoutingAvailable, !displays.isEmpty else { return }
        let connected = screens.map(displayID)
        let refreshDisplays = state.nativeAssignmentRefreshDisplays(changed: displays, connected: connected, mirrored: resolvedDisplayMode(state.displayMode) == "mirrored")
        guard !refreshDisplays.isEmpty else { return }
        pendingNativeAssignmentDisplays.formUnion(refreshDisplays)
        scheduleNativeRefresh()
    }
    private func scheduleNativeRefresh() {
        nativeRefreshTask?.cancel()
        nativeRefreshTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            guard let self, !self.saveBlocked, self.nativeRoutingAvailable else { return }
            if self.nativeSetupBusy { self.scheduleNativeRefresh(); return }
            let queuedDisplays = self.pendingNativeAssignmentDisplays
            self.pendingNativeAssignmentDisplays.removeAll()
            let connected = self.screens.map(displayID).filter { queuedDisplays.contains($0) }
            let displays = self.state.nativeRestorationDisplays(connected: connected)
            let ids = self.pendingNativeEdits
            self.pendingNativeEdits.subtract(ids)
            let items = providerCatalog(from: self.state).items.filter { ids.contains($0.id) }
            guard !displays.isEmpty || !items.isEmpty else { return }
            let root = self.disk.root
            self.nativeSetupBusy = true
            defer {
                self.nativeSetupBusy = false
                if !self.pendingNativeEdits.isEmpty || !self.pendingNativeAssignmentDisplays.isEmpty { self.scheduleNativeRefresh() }
            }
            do {
                if !displays.isEmpty {
                    let assignments = try self.savedNativeAssignments(for: displays)
                    let mirrored = resolvedDisplayMode(self.state.displayMode) == "mirrored" && Set(displays) == Set(self.screens.map(displayID))
                    try await Task.detached { try NativeWallpaper.apply(assignments, targeting: displays, mirrored: mirrored, root: root, clearingUnassigned: true) }.value
                    self.state.nativeCleanupDisplays.subtract(displays)
                    self.rememberNativeAssignments(assignments, displays: displays)
                }
                try await Task.detached {
                    for item in items { try NativeWallpaper.refresh(item, root: root) }
                }.value
            } catch { self.error = error.localizedDescription }
        }
    }
    func favorite(_ w: Wallpaper) { var value = w; value.favorite.toggle(); edit(value) }
    func createPlaylist(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let p = Playlist(name: trimmed)
        state.playlists.append(p)
        section = "playlist:" + p.id
        save()
    }
    func updatePlaylist(_ id: String, interval: Double? = nil, shuffle: Bool? = nil) {
        guard let i = state.playlists.firstIndex(where: { $0.id == id }) else { return }
        if let interval { state.playlists[i].interval = interval }
        if let shuffle { state.playlists[i].shuffle = shuffle }
        save()
    }
    func duplicatePlaylist(_ id: String) {
        guard let source = state.playlist(id) else { return }
        let copy = Playlist(name: source.name + " Copy", items: source.items,
                            interval: source.interval, shuffle: source.shuffle)
        state.playlists.append(copy)
        section = "playlist:" + copy.id
        save()
    }
    func toggleInPlaylist(_ wallpaper: String, _ playlist: String) {
        guard let i = state.playlists.firstIndex(where: { $0.id == playlist }) else { return }
        if state.playlists[i].items.contains(wallpaper) { state.playlists[i].items.removeAll { $0 == wallpaper } }
        else { state.playlists[i].items.append(wallpaper) }
        save()
    }
    func moveInPlaylist(_ wallpaper: String, playlist: String, delta: Int) {
        guard let p = state.playlists.firstIndex(where: { $0.id == playlist }), let index = state.playlists[p].items.firstIndex(of: wallpaper) else { return }
        let destination = index + delta
        guard state.playlists[p].items.indices.contains(destination) else { return }
        state.playlists[p].items.swapAt(index, destination)
        save()
    }
    func deletePlaylist(_ id: String) {
        state.removePlaylist(id)
        section = "all"
        save()
    }
    func remove(_ w: Wallpaper) {
        let previousAssignments = state.displays
        state.remove(w.id)
        let displayIDs = Set(previousAssignments.keys).union(state.displays.keys)
        let changed = state.nativeAssignmentChanges(from: previousAssignments, displays: Array(displayIDs))
        state.nativeCleanupDisplays.formUnion(changed.filter { state.nativePlayback[$0] == true })
        save()
        scheduleNativeAssignmentRefresh(for: changed)
        // Retain the imported file so accidental removal never destroys the user's media.
        thumbnails.removeValue(forKey: w.id)
        selection = state.wallpapers.first(where: { !state.isBlocked($0) })?.id
    }
    private weak var activeOpenPanel: NSOpenPanel?

    func chooseMedia(playlistID: String? = nil) {
        if let existing = activeOpenPanel, existing.isVisible {
            existing.orderFront(nil)
            return
        }
        let panel = NSOpenPanel()
        activeOpenPanel = panel
        panel.allowedContentTypes = [.movie, .image, .json, .folder, .zip] + (UTType(filenameExtension: "bdpkg").map { [$0] } ?? [])
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = true
        panel.title = "Add Wallpaper"
        panel.prompt = "Add"
        panel.message = "Choose images, videos or supported wallpaper packages. Source files are preserved."
        panel.begin { [weak self] response in
            if self?.activeOpenPanel === panel { self?.activeOpenPanel = nil }
            if response == .OK { self?.importMedia(panel.urls, playlistID: playlistID) }
        }
    }
    @MainActor func importDroppedFiles(_ providers: [NSItemProvider]) async {
        var urls: [URL] = []
        for provider in providers {
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
            }
            if let url { urls.append(url) }
        }
        if !urls.isEmpty { importMedia(urls) }
    }
    func importMedia(_ urls: [URL], playlistID: String? = nil) {
        guard !saveBlocked else { error = LibraryError.invalidLibrary.localizedDescription; return }
        let taskID = UUID()
        importTasks.insert(taskID)
        importing = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            var failures: [String] = []
            var addedIDs: [String] = []
            for url in urls {
                do {
                    let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    let isPackage = isDirectory || ["zip", "json", "bdpkg"].contains(url.pathExtension.lowercased())
                    let package: ScenePackageContents?
                    if isPackage {
                        package = try await Task.detached(priority: .userInitiated) { try ScenePackage.inspect(url) }.value
                    } else { package = nil }
                    defer { package?.cleanup() }
                    let mediaURL = package?.assetURL ?? url.resolvingSymlinksInPath()
                    guard (try? mediaURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                        throw LibraryError.unreadableMedia(url.lastPathComponent)
                    }
                    let type = UTType(filenameExtension: mediaURL.pathExtension)
                    let kind: String
                    if type?.conforms(to: .image) == true, NSImage(contentsOf: mediaURL) != nil { kind = "image" }
                    else {
                        let asset = AVURLAsset(url: mediaURL, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
                        let tracks = try await asset.loadTracks(withMediaType: .video)
                        guard !tracks.isEmpty else { throw LibraryError.unreadableMedia(url.lastPathComponent) }
                        for track in tracks where !(try await track.load(.isSelfContained)) {
                            throw LibraryError.unreadableMedia(url.lastPathComponent)
                        }
                        kind = "video"
                    }
                    let id = UUID().uuidString
                    let file = id + "." + mediaURL.pathExtension.lowercased()
                    let dest = self.disk.assets.appendingPathComponent(file)
                    try await Task.detached(priority: .userInitiated) { try FileManager.default.copyItem(at: mediaURL, to: dest) }.value
                    var w = Wallpaper(id: id, title: package?.title ?? url.deletingPathExtension().lastPathComponent, kind: kind, file: file)
                    if let package {
                        w.tags = package.tags
                        let manifest = package.manifest
                        w.metadata = SceneMetadata(details: manifest["details"] as? String ?? "",
                                                   category: manifest["categoryIdentifier"] as? String ?? "",
                                                   creditTitle: manifest["linkTitle"] as? String ?? "",
                                                   creditURL: manifest["linkURL"] as? String ?? "",
                                                   color: manifest["color"] as? String,
                                                   motion: manifest["motionIntensity"] as? String)
                        if let timestamp = manifest["thumbnailTimestamp"] as? Double, timestamp.isFinite, timestamp >= 0 {
                            w.videoEdit = VideoEdit(thumbnail: timestamp)
                        }
                    }
                    let thumbnail = w.videoEdit?.thumbnail ?? 0
                    let inspection = await Task.detached(priority: .utility) {
                        await MediaInspection.load(url: dest, kind: kind, thumbnail: thumbnail)
                    }.value
                    w.mediaFacts = inspection.facts
                    w.dateAdded = Date()
                    if w.metadata == nil { w.metadata = SceneMetadata() }
                    if w.metadata?.color == nil { w.metadata?.color = inspection.color }
                    self.state.wallpapers.append(w)
                    if let playlistID, let i = self.state.playlists.firstIndex(where: { $0.id == playlistID }) { self.state.playlists[i].items.append(id) }
                    self.generateThumbnail(w)
                    addedIDs.append(id)
                } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            self.importTasks.remove(taskID)
            self.importing = !self.importTasks.isEmpty
            if !addedIDs.isEmpty {
                self.lastImportIDs = addedIDs
                self.clearFilters()
                self.section = "all"
                self.browseSort = "recent"
                self.selection = addedIDs.last
                self.importNotice = "Added \(addedIDs.count) wallpaper(s)."
            }
            self.activity = "Added \(addedIDs.count) wallpaper(s)."
            self.save()
            if !failures.isEmpty { self.error = failures.joined(separator: "\n") }
        }
    }
    func undoImport() {
        for id in lastImportIDs {
            if let wallpaper = state.item(id) { remove(wallpaper) }
        }
        lastImportIDs = []
        importNotice = nil
    }
    func addToPlaylist(_ ids: Set<String>, playlistID: String) {
        guard let index = state.playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        for wallpaper in state.wallpapers where ids.contains(wallpaper.id) && !state.playlists[index].items.contains(wallpaper.id) {
            state.playlists[index].items.append(wallpaper.id)
        }
        save()
    }
    func backfillMetadata() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            for wallpaper in self.state.wallpapers {
                if wallpaper.file == nil {
                    if let curated = LibraryState.initial.item(wallpaper.id), curated.kind == wallpaper.kind,
                       let i = self.state.wallpapers.firstIndex(where: { $0.id == wallpaper.id }) {
                        var metadata = self.state.wallpapers[i].metadata ?? SceneMetadata()
                        if metadata.category.isEmpty { metadata.category = curated.category }
                        if metadata.color == nil { metadata.color = curated.color }
                        if metadata.motion == nil { metadata.motion = curated.motion }
                        if self.state.wallpapers[i].metadata != metadata { self.state.wallpapers[i].metadata = metadata; self.save() }
                    }
                    continue
                }
                let facts = wallpaper.mediaFacts
                guard facts?.bytes == nil || facts?.hasDimensions != true || (wallpaper.kind == "video" && facts?.sourceDuration == nil) else { continue }
                guard let url = self.disk.url(for: wallpaper) else { continue }
                let inspection = await Task.detached(priority: .utility) {
                    await MediaInspection.load(url: url, kind: wallpaper.kind, thumbnail: wallpaper.videoEdit?.thumbnail ?? 0)
                }.value
                guard let i = self.state.wallpapers.firstIndex(where: { $0.id == wallpaper.id }) else { continue }
                var measured = inspection.facts
                let previous = self.state.wallpapers[i].mediaFacts
                measured.width = measured.width ?? previous?.width
                measured.height = measured.height ?? previous?.height
                measured.bytes = measured.bytes ?? previous?.bytes
                measured.sourceDuration = measured.sourceDuration ?? previous?.sourceDuration
                guard measured != MediaFacts() else { continue }
                self.state.wallpapers[i].mediaFacts = measured
                if self.state.wallpapers[i].metadata == nil { self.state.wallpapers[i].metadata = SceneMetadata() }
                if self.state.wallpapers[i].metadata?.color == nil { self.state.wallpapers[i].metadata?.color = inspection.color }
                self.save()
            }
        }
    }
    func makeThumbnails() { for w in state.wallpapers { generateThumbnail(w) } }
    func generateThumbnail(_ w: Wallpaper) {
        if w.file == nil { thumbnails[w.id] = AmbientSceneView.thumbnail(scene: w.kind, size: NSSize(width: 480, height: 270)); return }
        guard let url = disk.url(for: w) else { return }
        Task { @MainActor [weak self] in
            if w.kind == "image" {
                self?.thumbnails[w.id] = NSImage(contentsOf: url)
            } else {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 480, height: 270)
                let timestamp = CMTime(seconds: w.videoEdit?.thumbnail ?? 0, preferredTimescale: 600)
                if let result = try? await generator.image(at: timestamp), self?.state.item(w.id)?.videoEdit?.thumbnail == w.videoEdit?.thumbnail { self?.thumbnails[w.id] = NSImage(cgImage: result.image, size: .zero) }
            }
        }
    }
    func setShowsMenuBar(_ shown: Bool) {
        guard shown != state.showsMenuBar else { return }
        state.setShowsMenuBar(shown)
        save()
        applyPresence()
    }
    func setHidesDockIcon(_ hidden: Bool) {
        guard state.showsMenuBar, hidden != state.hidesDockIcon else { return }
        state.setHidesDockIcon(hidden)
        save()
        applyPresence()
    }
    func applyPresence() {
        let policy: NSApplication.ActivationPolicy = state.hidesDockIcon ? .accessory : .regular
        guard NSApp.activationPolicy() != policy else { return }
        // Accessory removes the Dock icon; the menu bar icon is what keeps Flua reachable.
        let wasActive = NSRunningApplication.current.isActive
        let keyWindow = NSApp.keyWindow
        let mainWindow = NSApp.mainWindow
        let windows = NSApp.windows.filter { $0.isVisible && $0.level == .normal && !$0.ignoresMouseEvents }
        var resignObserver: NSObjectProtocol?
        if wasActive {
            // Changing activation policy causes macOS to asynchronously deactivate the application.
            // Reactivate on didResignActive so the active window remains in front.
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                if let obs = resignObserver {
                    NotificationCenter.default.removeObserver(obs)
                    resignObserver = nil
                }
                DispatchQueue.main.async {
                    NSApp.activate(ignoringOtherApps: true)
                    for window in windows { window.orderFrontRegardless() }
                    (keyWindow ?? mainWindow)?.makeKeyAndOrderFront(nil)
                }
            }
        }
        NSApp.setActivationPolicy(policy)
        if wasActive {
            NSApp.activate(ignoringOtherApps: true)
            for window in windows { window.orderFrontRegardless() }
            (keyWindow ?? mainWindow)?.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let obs = resignObserver {
                    NotificationCenter.default.removeObserver(obs)
                    resignObserver = nil
                }
            }
        }
    }
    func loginEnabled() -> Bool { SMAppService.mainApp.status == .enabled }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            objectWillChange.send()
        } catch { self.error = "Login item: \(error.localizedDescription)" }
    }
    deinit { tick?.invalidate(); if let o = screenObserver { NotificationCenter.default.removeObserver(o) } }
}
