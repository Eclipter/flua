import AppKit
import AVFoundation
import Combine
import ServiceManagement
import UniformTypeIdentifiers

final class Library: ObservableObject {
    @Published var state: LibraryState
    @Published var selection: String? = "aurora"
    @Published var section: String = "discover"
    @Published var query = ""
    @Published var filter = LibraryFilter()
    @Published var browseSort = "name"
    @Published var surface: WallpaperSurface = .desktop
    @Published var display = "all"
    @Published var screens = NSScreen.screens
    @Published var error: String?
    @Published var importing = false
    @Published var nativeSetupBusy = false
    @Published var activity = "Choose a scene, then apply it to your desktop."
    @Published var thumbnails: [String: NSImage] = [:]
    let disk: LibraryDisk
    let engine = DesktopEngine()
    var tick: Timer?
    private var screenObserver: NSObjectProtocol?
    private var saveBlocked = false
    private var nativeRefreshTask: Task<Void, Never>?
    private var stoppedNativeDisplays = Set<String>()
    private var pendingNativeAssignmentDisplays = Set<String>()
    private var pendingNativeEdits = Set<String>()
    var importTasks = Set<UUID>()
    var onChange: (() -> Void)?

    init(root: URL) throws {
        disk = try LibraryDisk(root: root)
        do { state = try disk.load() }
        catch { state = .initial; saveBlocked = true; self.error = error.localizedDescription }
        stoppedNativeDisplays = Set(state.nativePlayback.filter { !$0.value }.keys)
        selection = state.wallpapers.first(where: { !state.isBlocked($0) })?.id
        display = initialDisplaySelection(mode: state.displayMode, displayIDs: screens.map(displayID))
        engine.onError = { [weak self] in self?.error = $0 }
        syncEngine()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let previousDisplays = self.screens.map(displayID)
            self.screens = NSScreen.screens
            let reconnected = self.state.nativeRestorationDisplays(connected: self.screens.map(displayID), previouslyConnected: previousDisplays)
            if self.display != "all" && !self.screens.contains(where: { displayID($0) == self.display }) {
                self.display = self.playbackMode == "perDisplay" ? self.screens.first.map(displayID) ?? "all" : "all"
            }
            for key in self.engine.activeKeys where !self.screens.contains(where: { displayID($0) == key }) { self.engine.stop(display: key) }
            if self.restoreAssignments() { self.save() }
            if !reconnected.isEmpty {
                Task { @MainActor [weak self] in self?.restoreNativeAssignments(displays: reconnected) }
            }
        }
        tick = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.advancePlaylists(force: false) }
        RunLoop.main.add(tick!, forMode: .common)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.restoreAssignments() { self.save() }
            self.restoreNativeAssignments()
            self.makeThumbnails()
            self.backfillMetadata()
        }
    }
    var selected: Wallpaper? { state.item(selection) }
    var visible: [Wallpaper] { state.browsing(section: section, query: query, filter: filter, sort: browseSort) }
    var eligible: [Wallpaper] { state.browsing(section: "all", query: query, filter: filter) }
    func filterTag(_ tag: String) {
        filter.tags.formUnion(normalizedTags(tag))
        section = "browse"
    }
    func clearFilters() { filter = LibraryFilter(); query = "" }
    func blockTags(_ text: String) {
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
        case "discover": return "Discover"
        case "browse": return "Browse"
        case "favorites": return "Favorites"
        case "imports": return "Your media"
        case "all": return "All Wallpapers"
        default:
            if section.hasPrefix("playlist:") { return state.playlist(String(section.dropFirst(9)))?.name ?? "Playlist" }
            return "Library"
        }
    }
    var playbackMode: String { resolvedDisplayMode(state.displayMode) }
    var targets: [NSScreen] {
        if playbackMode == "mirrored" { return screens }
        return screens.filter { displayID($0) == display }
    }
    func setPlaybackMode(_ mode: String) {
        let previousMode = playbackMode
        let previousAssignments = state.displays
        let preferredDisplay = display == "all" ? nil : display
        state.displayMode = mode
        display = mode == "mirrored" ? "all" : screens.first.map(displayID) ?? "all"
        if mode == "mirrored" { _ = restoreAssignments(preferredDisplay: preferredDisplay) }
        let changed = state.nativeAssignmentChanges(from: previousAssignments, displays: screens.map(displayID))
        save()
        scheduleNativeAssignmentRefresh(for: previousMode == playbackMode ? changed : screens.map(displayID))
    }
    var targetAssignments: [DisplayAssignment] {
        targets.map { state.displays[displayID($0)] ?? DisplayAssignment() }
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
        let ids = targets.map(displayID)
        let previousAssignments = state.displays
        for id in ids { state.setMode(mode, display: id, surface: surface) }
        refreshTargetDesktops()
        let changed = state.nativeAssignmentChanges(from: previousAssignments, displays: ids)
        save()
        scheduleNativeAssignmentRefresh(for: changed)
    }
    func setSurfacesLinked(_ linked: Bool) {
        let ids = targets.map(displayID)
        let previousAssignments = state.displays
        for id in ids { state.setSurfacesLinked(linked, display: id) }
        save()
        let changed = state.nativeAssignmentChanges(from: previousAssignments, displays: ids)
        scheduleNativeAssignmentRefresh(for: changed)
    }
    func saveSelectedSurface() {
        guard let wallpaper = selected else { return }
        let ids = targets.map(displayID)
        let previousAssignments = state.displays
        for id in ids { state.assign(wallpaper.id, display: id, surface: surface) }
        refreshTargetDesktops()
        save()
        let changed = state.nativeAssignmentChanges(from: previousAssignments, displays: ids)
        scheduleNativeAssignmentRefresh(for: changed)
        let nativeTargets = playbackMode == "mirrored" ? screens.map(displayID) : ids
        let syncsActiveNative = nativeRoutingAvailable && !state.nativeRestorationDisplays(connected: nativeTargets).isEmpty
        let surfaceName = surface == .desktop ? "Desktop" : "Lock Screen"
        activity = syncsActiveNative
            ? "Saved \(wallpaper.title) for the \(surfaceName). Active native displays stay in sync with saved choices."
            : "Saved \(wallpaper.title) for the \(surfaceName). Apply Saved Wallpapers to start native playback."
    }
    private func refreshTargetDesktops() {
        for screen in targets where (surface == .desktop || state.displays[displayID(screen)]?.surfacesLinked == true)
            && !(nativeRoutingAvailable && state.nativePlayback[displayID(screen)] == true) {
            if let wallpaper = state.item(state.displays[displayID(screen)]?.desktop.wallpaperID) { play(wallpaper, on: screen) }
        }
    }
    func save() {
        guard !saveBlocked else { error = LibraryError.invalidLibrary.localizedDescription; return }
        do { try disk.save(state) } catch { self.error = error.localizedDescription }
        onChange?()
    }
    func syncEngine() {
        engine.manuallyPaused = state.paused
        engine.pauseOnBattery = state.pauseOnBattery
        engine.pauseOnLowPower = state.pauseOnLowPower ?? false
        engine.pauseOnFullscreen = state.pauseOnFullscreen
        engine.updatePowerState()
    }
    func settingChanged() { syncEngine(); save() }
    func applySelected() {
        guard let w = selected else { return }
        let now = Date()
        for screen in targets { state.assign(w.id, display: displayID(screen), now: now) }
        if playbackMode == "mirrored" { _ = state.synchronizeMirrored(displayIDs: targets.map(displayID)) }
        for screen in targets { play(w, on: screen) }
        activity = "Playing \(w.title) on \(targets.count == screens.count ? "all displays" : targets.first?.localizedName ?? "display")."
        save()
    }
    func startPlaylist(_ id: String) {
        guard let p = state.playlist(id), let w = p.items.compactMap({ state.item($0) }).first else { error = "Add at least one scene to this playlist first."; return }
        let now = Date()
        for screen in targets { state.assign(w.id, display: displayID(screen), playlistID: id, now: now) }
        if playbackMode == "mirrored" { _ = state.synchronizeMirrored(displayIDs: targets.map(displayID)) }
        for screen in targets { play(w, on: screen) }
        activity = "Playlist: \(p.name)"
        save()
    }
    @discardableResult func restoreAssignments(preferredDisplay: String? = nil) -> Bool {
        let previousDisplays = state.displays
        if playbackMode == "mirrored" {
            _ = state.synchronizeMirrored(displayIDs: screens.map(displayID), preferredSource: preferredDisplay)
        }
        for screen in screens {
            let key = displayID(screen)
            guard !stoppedNativeDisplays.contains(key),
                  !(nativeRoutingAvailable && state.nativePlayback[key] == true), let w = state.item(state.displays[key]?.desktop.wallpaperID) else { continue }
            if w.file != nil && !(disk.url(for: w).map { FileManager.default.fileExists(atPath: $0.path) } ?? false) {
                error = "Media for \(w.title) is missing. Reimport the file."
                continue
            }
            play(w, on: screen, rememberBackend: false)
        }
        if engine.activeCount > 0 { activity = "Restored wallpapers on \(engine.activeCount) display(s)." }
        return state.displays != previousDisplays
    }
    func advancePlaylists(force: Bool, backwards: Bool = false, allDisplays: Bool = false) {
        guard !nativeSetupBusy, !state.paused || force else { return }
        if playbackMode == "mirrored", nativeRoutingAvailable, screens.contains(where: { state.nativePlayback[displayID($0)] == true }) { return }
        if !force && screens.allSatisfy({ stoppedNativeDisplays.contains(displayID($0)) }) { return }
        var didChange = false
        if playbackMode == "mirrored" {
            if let w = state.advanceMirrored(displayIDs: screens.map(displayID), force: force, backwards: backwards) {
                for screen in screens { play(w, on: screen, rememberBackend: force) }
                didChange = true
            }
        } else {
            for screen in screens {
                let key = displayID(screen)
                if nativeRoutingAvailable && state.nativePlayback[key] == true { continue }
                if !force && stoppedNativeDisplays.contains(key) { continue }
                if force && !allDisplays && display != key { continue }
                if let w = state.advance(display: key, force: force, backwards: backwards) {
                    play(w, on: screen, rememberBackend: force)
                    didChange = true
                }
            }
        }
        if didChange { save() }
    }
    func stop() {
        guard !nativeSetupBusy else { return }
        let ids = targets.map(displayID)
        pendingNativeAssignmentDisplays.subtract(ids)
        if NativeWallpaper.available && NativeWallpaper.catalogURL.resolvingSymlinksInPath() == disk.catalog.resolvingSymlinksInPath() {
            let mirrored = playbackMode == "mirrored"
            let root = disk.root
            nativeSetupBusy = true
            Task { @MainActor in
                defer { nativeSetupBusy = false }
                do {
                    let nativeStopped = try await Task.detached { try NativeWallpaper.stop(displays: ids, mirrored: mirrored, root: root) }.value
                    for id in ids {
                        engine.stop(display: id)
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
        for screen in targets {
            let id = displayID(screen)
            engine.stop(display: id)
            if state.nativePlayback[id] != nil {
                state.nativePlayback[id] = false
                stoppedNativeDisplays.insert(id)
            } else { state.stop(display: id) }
        }
        activity = "Wallpaper stopped. Your system wallpaper is visible."
        save()
    }
    func togglePause() {
        state.paused.toggle()
        settingChanged()
        activity = state.paused ? "Playback paused." : "Playback resumed."
    }
    private var nativeRoutingAvailable: Bool {
        NativeWallpaper.available && NativeWallpaper.catalogURL.resolvingSymlinksInPath() == disk.catalog.resolvingSymlinksInPath()
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
        applySavedNativeAssignments(displays: ids)
    }
    @MainActor func applySavedNativeAssignments() {
        let connected = screens.map(displayID)
        let displays = state.nativeApplicationDisplays(targeted: targets.map(displayID), connected: connected)
        applySavedNativeAssignments(displays: displays)
    }
    @MainActor private func applySavedNativeAssignments(displays: [String]) {
        guard !nativeSetupBusy else { return }
        guard NativeWallpaper.available else { error = NativeWallpaper.explanation; return }
        guard !saveBlocked else { error = LibraryError.invalidLibrary.localizedDescription; return }
        guard NativeWallpaper.catalogURL.resolvingSymlinksInPath() == disk.catalog.resolvingSymlinksInPath() else {
            error = "This build uses a different library. Rebuild it with FLUA_CATALOG_PATH set to this library’s catalog.json."
            return
        }
        do { try disk.save(state) } catch { self.error = error.localizedDescription; return }
        let assignments: [String: NativeWallpaperStore.Assignment]
        do { assignments = try savedNativeAssignments(for: displays) }
        catch { self.error = error.localizedDescription; return }
        guard !assignments.isEmpty || displays.contains(where: { state.nativePlayback[$0] == true }) else {
            error = "Save a wallpaper choice for the targeted displays first."
            return
        }
        pendingNativeAssignmentDisplays.subtract(displays)
        let mirrored = playbackMode == "mirrored" && Set(displays) == Set(screens.map(displayID))
        nativeSetupBusy = true
        let root = disk.root
        Task {
            defer { nativeSetupBusy = false }
            do {
                try await Task.detached { try NativeWallpaper.apply(assignments, targeting: displays, mirrored: mirrored, root: root) }.value
                rememberNativeAssignments(assignments, displays: displays)
                activity = assignments.isEmpty
                    ? "Previous system wallpapers restored; no saved native choices remain for the targeted displays."
                    : "Applied saved wallpaper choices to \(assignments.count) display(s). Native playback continues after Flua quits."
            } catch { self.error = error.localizedDescription }
        }
    }
    private func savedNativeAssignments(for displays: [String]) throws -> [String: NativeWallpaperStore.Assignment] {
        let hasSavedChoice = displays.contains { id in
            guard let assignment = state.displays[id] else { return false }
            return assignment.desktop.wallpaperID != nil || assignment.lockScreen?.wallpaperID != nil
        }
        guard hasSavedChoice else { return [:] }
        return try NativeWallpaperStore.assignments(from: state, displays: displays, root: disk.root, provider: NativeWallpaper.identifier)
    }
    private func rememberNativeAssignments(_ assignments: [String: NativeWallpaperStore.Assignment], displays: [String]) {
        for id in displays {
            let active = assignments[id] != nil
            state.nativePlayback[id] = active
            if active { stoppedNativeDisplays.remove(id) } else { stoppedNativeDisplays.insert(id) }
        }
        for (id, assignment) in assignments where assignment.desktop != nil { engine.stop(display: id) }
        save()
    }
    @MainActor func removeNativeProvider() {
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
                for id in state.nativePlayback.keys {
                    state.nativePlayback[id] = false
                    stoppedNativeDisplays.insert(id)
                    engine.stop(display: id)
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
        engine.update(updated)
        for screen in screens where state.displays[displayID(screen)]?.desktop.wallpaperID == updated.id && state.displays[displayID(screen)]?.desktop.mode == .still {
            if !(nativeRoutingAvailable && state.nativePlayback[displayID(screen)] == true) {
                play(updated, on: screen, rememberBackend: false)
            }
        }
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
        let refreshDisplays = state.nativeAssignmentRefreshDisplays(changed: displays, connected: connected, mirrored: playbackMode == "mirrored")
        guard !refreshDisplays.isEmpty else { return }
        pendingNativeAssignmentDisplays.formUnion(refreshDisplays)
        scheduleNativeRefresh()
    }
    private func scheduleNativeRefresh() {
        nativeRefreshTask?.cancel()
        nativeRefreshTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            guard let self, !self.saveBlocked, NativeWallpaper.available,
                  NativeWallpaper.catalogURL.resolvingSymlinksInPath() == self.disk.catalog.resolvingSymlinksInPath() else { return }
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
                    let mirrored = self.playbackMode == "mirrored" && Set(displays) == Set(self.screens.map(displayID))
                    try await Task.detached { try NativeWallpaper.apply(assignments, targeting: displays, mirrored: mirrored, root: root) }.value
                    self.rememberNativeAssignments(assignments, displays: displays)
                }
                try await Task.detached {
                    for item in items { try NativeWallpaper.refresh(item, root: root) }
                }.value
            } catch { self.error = error.localizedDescription }
        }
    }
    private func play(_ wallpaper: Wallpaper, on screen: NSScreen, rememberBackend: Bool = true) {
        if rememberBackend { state.nativePlayback.removeValue(forKey: displayID(screen)) }
        stoppedNativeDisplays.remove(displayID(screen))
        let mode = state.displays[displayID(screen)]?.desktop.mode ?? .animated
        let url = disk.url(for: wallpaper)
        guard mode == .still, wallpaper.kind != "image" else {
            engine.apply(wallpaper, url: url, to: screen, mode: mode)
            return
        }
        let stamp = stillStamp(for: wallpaper)
        if let file = disk.retainedStill(id: wallpaper.id, stamp: stamp), let image = NSImage(contentsOf: file) {
            engine.apply(wallpaper, url: url, to: screen, mode: .still, stillImage: image)
            return
        }
        if wallpaper.file == nil {
            let image = AmbientSceneView.thumbnail(scene: wallpaper.kind, size: NSSize(width: 1920, height: 1080))
            let stored = pngData(image).flatMap { try? disk.writeStill(id: wallpaper.id, stamp: stamp, data: $0) }.flatMap { NSImage(contentsOf: $0) }
            engine.apply(wallpaper, url: nil, to: screen, mode: .still, stillImage: stored ?? image)
            return
        }
        engine.apply(wallpaper, url: url, to: screen, mode: .still)
        let id = wallpaper.id
        let display = displayID(screen)
        Task { @MainActor [weak self] in
            guard let self, let source = self.disk.url(for: wallpaper),
                  let data = try? await VideoTools.thumbnail(source: source, time: stillFrameTime(edit: wallpaper.videoEdit, duration: wallpaper.mediaFacts?.sourceDuration)),
                  self.state.displays[display]?.desktop.mode == .still,
                  self.state.displays[display]?.desktop.wallpaperID == id,
                  let current = self.state.item(id), stillStamp(for: current) == stamp,
                  let written = try? self.disk.writeStill(id: id, stamp: stamp, data: data),
                  let image = NSImage(contentsOf: written) else { return }
            self.engine.showStill(image, wallpaper: id, display: display)
        }
    }
    private func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
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
        for screen in screens where state.displays[displayID(screen)]?.desktop.wallpaperID == w.id { engine.stop(display: displayID(screen)) }
        state.remove(w.id)
        save()
        let changed = state.nativeAssignmentChanges(from: previousAssignments, displays: screens.map(displayID))
        scheduleNativeAssignmentRefresh(for: changed)
        // Retain the imported file so accidental removal never destroys the user's media.
        thumbnails.removeValue(forKey: w.id)
        selection = state.wallpapers.first(where: { !state.isBlocked($0) })?.id
    }
    func chooseMedia() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .image, .json, .folder, .zip] + (UTType(filenameExtension: "bdpkg").map { [$0] } ?? [])
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Import videos, images, video manifest folders, .zip, or .bdpkg packages. Flua stores its own copies."
        panel.begin { [weak self] response in if response == .OK { self?.importMedia(panel.urls) } }
    }
    func createWallpaper() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a video to create a Flua wallpaper. The source file will not be changed."
        panel.begin { [weak self] response in
            if response == .OK { self?.importMedia(panel.urls, openEditor: true) }
        }
    }
    func importMedia(_ urls: [URL], openEditor: Bool = false) {
        guard !saveBlocked else { error = LibraryError.invalidLibrary.localizedDescription; return }
        let taskID = UUID()
        importTasks.insert(taskID)
        importing = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            var failures: [String] = []
            var added = 0
            var firstAdded: Wallpaper?
            for url in urls {
                do {
                    let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    let isPackage = isDirectory || ["zip", "json", "bdpkg"].contains(url.pathExtension.lowercased())
                    let package: ScenePackageContents?
                    if isPackage {
                        package = try await Task.detached(priority: .userInitiated) { try ScenePackage.inspect(url) }.value
                    } else { package = nil }
                    defer { package?.cleanup() }
                    let mediaURL = package?.assetURL ?? url
                    let type = UTType(filenameExtension: mediaURL.pathExtension)
                    let kind: String
                    if type?.conforms(to: .image) == true, NSImage(contentsOf: mediaURL) != nil { kind = "image" }
                    else {
                        let asset = AVURLAsset(url: mediaURL)
                        let tracks = try await asset.loadTracks(withMediaType: .video)
                        guard !tracks.isEmpty else { throw LibraryError.unreadableMedia(url.lastPathComponent) }
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
                    if firstAdded == nil { firstAdded = w }
                    self.selection = self.state.isBlocked(w) ? nil : id
                    if self.section.hasPrefix("playlist:"), let i = self.state.playlists.firstIndex(where: { $0.id == String(self.section.dropFirst(9)) }) { self.state.playlists[i].items.append(id) }
                    self.generateThumbnail(w)
                    added += 1
                } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            self.importTasks.remove(taskID)
            self.importing = !self.importTasks.isEmpty
            self.activity = "Imported \(added) file(s)."
            self.save()
            if openEditor, let w = firstAdded, w.kind == "video", let source = self.disk.url(for: w) {
                VideoEditorWindow.open(wallpaper: w, source: source, library: self)
            }
            if !failures.isEmpty { self.error = failures.joined(separator: "\n") }
        }
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
