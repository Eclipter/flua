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
    @Published var display = "all"
    @Published var screens = NSScreen.screens
    @Published var error: String?
    @Published var importing = false
    @Published var activity = "Choose a scene, then apply it to your desktop."
    @Published var thumbnails: [String: NSImage] = [:]
    let disk: LibraryDisk
    let engine = DesktopEngine()
    var tick: Timer?
    private var screenObserver: NSObjectProtocol?
    private var saveBlocked = false
    var importTasks = Set<UUID>()
    var onChange: (() -> Void)?

    init(root: URL) throws {
        disk = try LibraryDisk(root: root)
        do { state = try disk.load() }
        catch { state = .initial; saveBlocked = true; self.error = error.localizedDescription }
        selection = state.wallpapers.first?.id
        display = initialDisplaySelection(mode: state.displayMode, displayIDs: screens.map(displayID))
        engine.onError = { [weak self] in self?.error = $0 }
        syncEngine()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.screens = NSScreen.screens
            if self.display != "all" && !self.screens.contains(where: { displayID($0) == self.display }) {
                self.display = self.playbackMode == "perDisplay" ? self.screens.first.map(displayID) ?? "all" : "all"
            }
            for key in self.engine.activeKeys where !self.screens.contains(where: { displayID($0) == key }) { self.engine.stop(display: key) }
            if self.restoreAssignments() { self.save() }
        }
        tick = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.advancePlaylists(force: false) }
        RunLoop.main.add(tick!, forMode: .common)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.restoreAssignments() { self.save() }
            self.makeThumbnails()
        }
    }
    var selected: Wallpaper? { state.item(selection) }
    var visible: [Wallpaper] {
        let filtered = state.wallpapers.filter { w in
            let matches: Bool
            if section == "favorites" { matches = w.favorite }
            else if section == "imports" { matches = w.file != nil }
            else if section.hasPrefix("playlist:") { matches = state.playlist(String(section.dropFirst(9)))?.items.contains(w.id) ?? false }
            else { matches = true }
            return matches && (query.isEmpty || (w.title + " " + w.tags + " " + w.kind).localizedCaseInsensitiveContains(query))
        }
        if section.hasPrefix("playlist:"), let playlist = state.playlist(String(section.dropFirst(9))) {
            return playlist.items.compactMap { id in filtered.first { $0.id == id } }
        }
        return filtered
    }
    var sectionTitle: String {
        if section == "browse" { return "Browse" }
        if section == "favorites" { return "Favorites" }
        if section == "imports" { return "Your media" }
        if section.hasPrefix("playlist:") { return state.playlist(String(section.dropFirst(9)))?.name ?? "Playlist" }
        return "Library"
    }
    var playbackMode: String { resolvedDisplayMode(state.displayMode) }
    var targets: [NSScreen] {
        if playbackMode == "mirrored" { return screens }
        return screens.filter { displayID($0) == display }
    }
    func setPlaybackMode(_ mode: String) {
        let preferredDisplay = display == "all" ? nil : display
        state.displayMode = mode
        display = mode == "mirrored" ? "all" : screens.first.map(displayID) ?? "all"
        if mode == "mirrored" { _ = restoreAssignments(preferredDisplay: preferredDisplay) }
        save()
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
        for screen in targets {
            state.displays[displayID(screen)] = DisplayAssignment(wallpaperID: w.id)
            engine.apply(w, url: disk.url(for: w), to: screen)
        }
        activity = "Playing \(w.title) on \(targets.count == screens.count ? "all displays" : targets.first?.localizedName ?? "display")."
        save()
    }
    func startPlaylist(_ id: String) {
        guard let p = state.playlist(id), let w = p.items.compactMap({ state.item($0) }).first else { error = "Add at least one scene to this playlist first."; return }
        for screen in targets {
            state.displays[displayID(screen)] = DisplayAssignment(wallpaperID: w.id, playlistID: id)
            engine.apply(w, url: disk.url(for: w), to: screen)
        }
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
            guard let w = state.item(state.displays[key]?.wallpaperID) else { continue }
            if w.file != nil && !(disk.url(for: w).map { FileManager.default.fileExists(atPath: $0.path) } ?? false) {
                error = "Media for \(w.title) is missing. Reimport the file."
                continue
            }
            engine.apply(w, url: disk.url(for: w), to: screen)
        }
        if engine.activeCount > 0 { activity = "Restored wallpapers on \(engine.activeCount) display(s)." }
        return state.displays != previousDisplays
    }
    func advancePlaylists(force: Bool, backwards: Bool = false, allDisplays: Bool = false) {
        guard !state.paused || force else { return }
        var didChange = false
        if playbackMode == "mirrored" {
            if let w = state.advanceMirrored(displayIDs: screens.map(displayID), force: force, backwards: backwards) {
                for screen in screens { engine.apply(w, url: disk.url(for: w), to: screen) }
                didChange = true
            }
        } else {
            for screen in screens {
                let key = displayID(screen)
                if force && !allDisplays && display != key { continue }
                if let w = state.advance(display: key, force: force, backwards: backwards) {
                    engine.apply(w, url: disk.url(for: w), to: screen)
                    didChange = true
                }
            }
        }
        if didChange { save() }
    }
    func stop() {
        for screen in targets { engine.stop(display: displayID(screen)); state.displays.removeValue(forKey: displayID(screen)) }
        activity = "Wallpaper stopped. Your system wallpaper is visible."
        save()
    }
    func togglePause() {
        state.paused.toggle()
        settingChanged()
        activity = state.paused ? "Playback paused." : "Playback resumed."
    }
    func edit(_ value: Wallpaper) {
        guard let i = state.wallpapers.firstIndex(where: { $0.id == value.id }) else { return }
        state.wallpapers[i] = value
        engine.update(value)
        save()
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
        state.playlists.removeAll { $0.id == id }
        for key in Array(state.displays.keys) where state.displays[key]?.playlistID == id { state.displays[key]?.playlistID = nil }
        section = "all"
        save()
    }
    func remove(_ w: Wallpaper) {
        for screen in screens where state.displays[displayID(screen)]?.wallpaperID == w.id { engine.stop(display: displayID(screen)) }
        state.remove(w.id)
        save()
        // Retain the imported file so accidental removal never destroys the user's media.
        thumbnails.removeValue(forKey: w.id)
        selection = state.wallpapers.first?.id
    }
    func chooseMedia() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .image, .json, .folder, .zip]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Import videos, images, video manifest folders, or .zip packages. Flua stores its own copies."
        panel.begin { [weak self] response in if response == .OK { self?.importMedia(panel.urls) } }
    }
    func createBackdrop() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a video to create a Flua backdrop. The source file will not be changed."
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
                    let isPackage = isDirectory || ["zip", "json"].contains(url.pathExtension.lowercased())
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
                                                   creditURL: manifest["linkURL"] as? String ?? "")
                        if let timestamp = manifest["thumbnailTimestamp"] as? Double, timestamp.isFinite, timestamp >= 0 {
                            w.videoEdit = VideoEdit(thumbnail: timestamp)
                        }
                    }
                    self.state.wallpapers.append(w)
                    if firstAdded == nil { firstAdded = w }
                    self.selection = id
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
