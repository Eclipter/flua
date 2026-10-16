import SwiftUI
import AppKit
import Combine

final class ViewState: ObservableObject {
    @Published var creatingPlaylist = false
    @Published var playlistName = ""
    @Published var deleting: Wallpaper?
    @Published var dragOver = false
    @Published var draftTitle = ""
    @Published var draftTags = ""
    @Published var browseKind = "all"
    @Published var browseSort = "name"
}


let accent = Color(red: 0.12, green: 0.55, blue: 1)

enum AppContext {
    static let library: Library = {
        let args = ProcessInfo.processInfo.arguments
        do {
            let root: URL
            if let i = args.firstIndex(of: "--data-dir"), args.indices.contains(i + 1) {
                root = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            } else {
                let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                root = LibraryPaths.resolve(applicationSupport: support)
            }
            return try Library(root: root)
        }
        catch {
            let alert = NSAlert()
            alert.messageText = "Flua could not open its library"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            exit(1)
        }
    }()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { AppContext.library.engine.stopAll() }
    func application(_ sender: NSApplication, openFiles filenames: [String]) { AppContext.library.importMedia(filenames.map { URL(fileURLWithPath: $0) }) }
}

@main struct FluaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject var library = AppContext.library
    var body: some Scene {
        Window("Flua", id: "library") {
            LibraryView().environmentObject(library).preferredColorScheme(.dark)
                .frame(minWidth: 1050, minHeight: 680)
                .task { await SmokeRunner.runIfRequested(library: library) }
        }
        .defaultSize(width: 1320, height: 840)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Create New Flua…") { library.createBackdrop() }.keyboardShortcut("n")
                Button("Import media or scene package…") { library.chooseMedia() }.keyboardShortcut("i")
            }
            CommandMenu("Playback") {
                Button(library.state.paused ? "Resume" : "Pause") { library.togglePause() }.keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Previous on every display") { library.advancePlaylists(force: true, backwards: true, allDisplays: true) }.keyboardShortcut(.leftArrow, modifiers: [.command])
                Button("Next on every display") { library.advancePlaylists(force: true, allDisplays: true) }.keyboardShortcut(.rightArrow, modifiers: [.command])
                Button("Stop wallpapers") { library.stop() }
            }
        }
        Settings { SettingsView().environmentObject(library).frame(width: 530).preferredColorScheme(.dark) }
        MenuBarExtra("Flua", systemImage: "camera.macro") { TrayView().environmentObject(library) }
    }
}

struct TrayView: View {
    @EnvironmentObject var library: Library
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Button("Open Flua") { openWindow(id: "library"); NSApp.activate(ignoringOtherApps: true) }
        Divider()
        Button(library.state.paused ? "Resume wallpapers" : "Pause wallpapers") { library.togglePause() }
        Button("Next on every display") { library.advancePlaylists(force: true, allDisplays: true) }
        Button("Stop wallpapers") { library.stop() }
        Divider()
        SettingsLink { Text("Settings…") }
        Button("Quit Flua") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

struct LibraryView: View {
    @StateObject private var ui = ViewState()
    @EnvironmentObject var library: Library
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 205)
            Divider().opacity(0.25)
            VStack(alignment: .leading, spacing: 0) {
                header
                if library.section == "discover" { discoverContent }
                else { libraryContent }
                footer
            }.background(Color(red: 0.062, green: 0.075, blue: 0.085))
            Divider().opacity(0.25)
            InspectorView().frame(width: 280)
        }
        .background(Color(red: 0.078, green: 0.088, blue: 0.098))
        .tint(accent)
        .overlay {
            if ui.dragOver { RoundedRectangle(cornerRadius: 18).stroke(accent, lineWidth: 3).padding(10).overlay(Text("Drop videos or images to import").font(.title2).padding(30).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))) }
        }
        .onDrop(of: [.fileURL], isTargeted: $ui.dragOver) { providers in
            for p in providers { _ = p.loadObject(ofClass: URL.self) { url, _ in if let url { DispatchQueue.main.async { library.importMedia([url]) } } } }
            return !providers.isEmpty
        }
        .alert("Flua", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button("OK") { library.error = nil }
        } message: { Text(library.error ?? "") }
        .alert("New playlist", isPresented: $ui.creatingPlaylist) {
            TextField("Playlist name", text: $ui.playlistName)
            Button("Create") { library.createPlaylist(ui.playlistName); ui.playlistName = "" }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Remove scene?", isPresented: Binding(get: { ui.deleting != nil }, set: { if !$0 { ui.deleting = nil } })) {
            Button("Remove", role: .destructive) { if let w = ui.deleting { library.remove(w) }; ui.deleting = nil }
            Button("Cancel", role: .cancel) { ui.deleting = nil }
        } message: { Text("The scene will be removed from playlists and stopped on any display. Imported files are kept in Flua’s media folder.") }
    }
    private var displayed: [Wallpaper] {
        var values = library.visible
        if library.section == "browse", ui.browseKind != "all" {
            values = values.filter { ui.browseKind == "animated" ? $0.kind != "image" : $0.kind == "image" }
        }
        if library.section == "browse" {
            if ui.browseSort == "name" { values.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending } }
            else if ui.browseSort == "favorites" { values.sort { $0.favorite && !$1.favorite } }
        }
        return values
    }
    private var libraryContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text(library.sectionTitle).font(.largeTitle.bold())
                    Text("\(displayed.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    if library.section.hasPrefix("playlist:") {
                        let id = String(library.section.dropFirst(9))
                        Menu {
                            Picker("Change wallpaper", selection: Binding(
                                get: { library.state.playlist(id)?.interval ?? library.state.interval },
                                set: { library.updatePlaylist(id, interval: $0) })) {
                                Text("Every minute").tag(60.0)
                                Text("Every 5 minutes").tag(300.0)
                                Text("Every 15 minutes").tag(900.0)
                                Text("Every hour").tag(3600.0)
                            }
                            Toggle("Shuffle", isOn: Binding(
                                get: { library.state.playlist(id)?.shuffle ?? library.state.shuffle },
                                set: { library.updatePlaylist(id, shuffle: $0) }))
                            Button("Duplicate Playlist") { library.duplicatePlaylist(id) }
                        } label: { Label("Playlist Options", systemImage: "ellipsis.circle") }
                        Button { library.startPlaylist(id) } label: { Label("Play", systemImage: "play.fill") }.buttonStyle(.borderedProminent)
                    }
                }
                if library.section == "browse" { browseToolbar }
                if displayed.isEmpty {
                    ContentUnavailableView("No Backdrops Available", systemImage: "photo.on.rectangle.angled", description: Text("Import a video or image, or adjust your search and filters."))
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 18)], spacing: 18) {
                        ForEach(displayed) { wallpaperCard($0) }
                    }
                }
            }.padding(28)
        }
    }
    private var discoverContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                Text("Discover").font(.largeTitle.bold())
                discoverShelf("Featured", wallpapers: Array(library.state.wallpapers.prefix(3)), large: true)
                discoverShelf("Animated", wallpapers: library.state.wallpapers.filter { $0.kind != "image" })
                if library.state.wallpapers.contains(where: { $0.file != nil }) {
                    discoverShelf("Your Backdrops", wallpapers: library.state.wallpapers.filter { $0.file != nil })
                }
            }.padding(28)
        }
        .background(LinearGradient(colors: [.purple.opacity(0.18), .blue.opacity(0.10), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
    }
    private func discoverShelf(_ title: String, wallpapers: [Wallpaper], large: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(title).font(.title3.bold()); Spacer(); Button("Show All") { library.section = "browse" }.buttonStyle(.plain).foregroundStyle(.secondary) }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 18) {
                    ForEach(wallpapers) { w in
                        wallpaperCard(w).frame(width: large ? 310 : 240, height: large ? 194 : 150)
                    }
                }
            }
        }
    }
    private var browseToolbar: some View {
        HStack {
            Picker("Motion", selection: $ui.browseKind) {
                Text("All").tag("all"); Text("Animated").tag("animated"); Text("Still").tag("still")
            }.pickerStyle(.segmented).frame(width: 260)
            Spacer()
            Picker("Sort By", selection: $ui.browseSort) {
                Text("Name").tag("name"); Text("Favorites First").tag("favorites")
            }.frame(width: 190)
        }
    }
    private func wallpaperCard(_ w: Wallpaper) -> some View {
        WallpaperCard(wallpaper: w, selected: library.selection == w.id)
            .onTapGesture { library.selection = w.id }
            .onTapGesture(count: 2) { library.selection = w.id; library.applySelected() }
            .contextMenu {
                Button("Play Backdrop") { library.selection = w.id; library.applySelected() }
                Button(w.favorite ? "Remove from Favorites" : "Add to Favorites") { library.favorite(w) }
                if w.kind == "video", let source = library.disk.url(for: w) {
                    Button("Edit…") { VideoEditorWindow.open(wallpaper: w, source: source, library: library) }
                }
                Menu("Add to Playlist") {
                    ForEach(library.state.playlists) { p in
                        Button((p.items.contains(w.id) ? "✓ " : "") + p.name) { library.toggleInPlaylist(w.id, p.id) }
                    }
                }
                if library.section.hasPrefix("playlist:") {
                    let id = String(library.section.dropFirst(9))
                    Button("Move Earlier") { library.moveInPlaylist(w.id, playlist: id, delta: -1) }
                    Button("Move Later") { library.moveInPlaylist(w.id, playlist: id, delta: 1) }
                }
                Divider()
                Button("Remove from Library…", role: .destructive) { ui.deleting = w }
            }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "drop.fill").font(.title2).foregroundStyle(accent)
                Text("Flua").font(.title3.weight(.semibold))
            }.padding(.top, 46).padding(.bottom, 10)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $library.query).textFieldStyle(.plain)
                    .onChange(of: library.query) { _, value in
                        if !value.isEmpty && library.section == "discover" { library.section = "browse" }
                    }
                if !library.query.isEmpty { Button { library.query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
            }.padding(9).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7)).padding(.bottom, 12)
            sideButton("Discover", symbol: "sparkles", section: "discover")
            sideButton("Browse", symbol: "rectangle.grid.2x2", section: "browse")
            Text("LIBRARY").font(.system(size: 10, weight: .semibold, design: .rounded)).tracking(2).foregroundStyle(.secondary)
                .padding(.top, 18)
            sideButton("All Backdrops", symbol: "books.vertical", section: "all")
            sideButton("Favorites", symbol: "heart", section: "favorites")
            sideButton("Your media", symbol: "film", section: "imports")
            HStack {
                Text("PLAYLISTS").font(.system(size: 10, weight: .semibold, design: .rounded)).tracking(2).foregroundStyle(.secondary)
                Spacer()
                Button { ui.creatingPlaylist = true } label: { Image(systemName: "plus") }.buttonStyle(.plain).help("Create playlist")
            }.padding(.top, 27).padding(.bottom, 4)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(library.state.playlists) { p in
                        sideButton(p.name, symbol: "music.note.list", section: "playlist:" + p.id)
                            .contextMenu { Button("Delete playlist", role: .destructive) { library.deletePlaylist(p.id) } }
                    }
                }
            }
            Spacer()
            Button { library.chooseMedia() } label: { Label("Import Scene…", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain).foregroundStyle(.secondary)
            SettingsLink { Label("Settings", systemImage: "gearshape").font(.callout).foregroundStyle(.secondary) }.buttonStyle(.plain).padding(.top, 8)
        }.padding(.horizontal, 18).padding(.bottom, 22)
    }
    private func sideButton(_ title: String, symbol: String, section: String) -> some View {
        Button { library.section = section; if section == "discover" { library.query = "" } } label: {
            Label(title, systemImage: symbol).font(.system(size: 13, weight: library.section == section ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10).padding(.horizontal, 10)
                .foregroundStyle(library.section == section ? accent : .white.opacity(0.65))
                .background(library.section == section ? accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }
    private var header: some View {
        HStack(spacing: 12) {
            Text("Flua").font(.headline)
            Spacer()
            Button { library.chooseMedia() } label: { Label(library.importing ? "Importing…" : "Import", systemImage: "square.and.arrow.down") }.disabled(library.importing)
            Button { library.createBackdrop() } label: { Label("Create", systemImage: "plus") }.buttonStyle(.borderedProminent)
        }.padding(.horizontal, 28).padding(.top, 36).padding(.bottom, 14).background(.black.opacity(0.12))
    }
    private var footer: some View {
        HStack(spacing: 9) {
            Circle().fill(library.state.paused ? Color.orange : accent).frame(width: 5, height: 5)
            Text(library.activity).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Picker("Display Mode", selection: Binding(get: { library.playbackMode }, set: { library.setPlaybackMode($0) })) {
                Text("Mirrored").tag("mirrored")
                Text("Per Display").tag("perDisplay")
            }.labelsHidden().pickerStyle(.segmented).frame(width: 170)
            Button { library.advancePlaylists(force: true, backwards: true) } label: { Image(systemName: "backward.end.fill") }.help("Previous in playlist")
            Button { library.advancePlaylists(force: true) } label: { Image(systemName: "forward.end.fill") }.help("Next in playlist")
            Button { library.togglePause() } label: { Image(systemName: library.state.paused ? "play.fill" : "pause.fill") }.help("Pause or resume")
            Button { library.stop() } label: { Image(systemName: "stop.fill") }.help("Stop on selected displays")
        }.buttonStyle(.plain).padding(14).padding(.horizontal, 14).background(.black.opacity(0.12))
    }
}

struct WallpaperCard: View {
    @EnvironmentObject var library: Library
    let wallpaper: Wallpaper
    let selected: Bool
    var body: some View {
        ZStack(alignment: .topTrailing) {
            GeometryReader { geo in
                if let image = library.thumbnails[wallpaper.id] {
                    Image(nsImage: image).resizable().scaledToFill().frame(width: geo.size.width, height: geo.size.height).clipped()
                } else {
                    Rectangle().fill(Color.white.opacity(0.03)).overlay(Image(systemName: wallpaper.kind == "video" ? "film" : "photo").foregroundStyle(.secondary))
                }
            }
            LinearGradient(colors: [.clear, .black.opacity(0.78)], startPoint: .center, endPoint: .bottom)
            Button { library.favorite(wallpaper) } label: {
                Image(systemName: wallpaper.favorite ? "heart.fill" : "heart").font(.system(size: 12)).padding(8).background(.black.opacity(0.35), in: Circle())
            }.buttonStyle(.plain).padding(9)
            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(wallpaper.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Text(wallpaper.kind == "image" ? "Still" : "Animated").font(.system(size: 9)).foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer()
                    Image(systemName: wallpaper.kind == "image" ? "photo" : "play.fill").font(.caption2).foregroundStyle(.white.opacity(0.8))
                }.padding(12)
            }
        }
        .aspectRatio(16/10, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? accent : .white.opacity(0.08), lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
    }
}

struct SurfacePreview: NSViewRepresentable {
    let wallpaper: Wallpaper
    let url: URL?
    func makeNSView(context: Context) -> MediaSurface {
        let view = MediaSurface(frame: NSRect(x: 0, y: 0, width: 256, height: 160))
        view.configure(wallpaper, url: url)
        context.coordinator.current = wallpaper
        return view
    }
    func updateNSView(_ view: MediaSurface, context: Context) {
        if context.coordinator.current != wallpaper {
            if context.coordinator.current?.id == wallpaper.id { view.updateParameters(wallpaper) }
            else { view.configure(wallpaper, url: url) }
            context.coordinator.current = wallpaper
        }
    }
    static func dismantleNSView(_ view: MediaSurface, coordinator: Coordinator) { view.cleanup() }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var current: Wallpaper? }
}

struct InspectorView: View {
    @StateObject private var ui = ViewState()
    @EnvironmentObject var library: Library
    var body: some View {
        ScrollView {
            if let w = library.selected {
                VStack(alignment: .leading, spacing: 20) {
                    Text("SCENE DETAILS").font(.system(size: 9, weight: .semibold)).tracking(2).foregroundStyle(.secondary).padding(.top, 42)
                    SurfacePreview(wallpaper: w, url: library.disk.url(for: w)).id(w.id).aspectRatio(16/10, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 7) {
                        Text(w.title).font(.system(size: 21, weight: .medium, design: .serif))
                        Text(w.file == nil ? "An original animated scene, rendered on your Mac." : "Imported \(w.kind). Stored locally, ready whenever you are.").font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("DISPLAY").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                        Picker("Display Mode", selection: Binding(get: { library.playbackMode }, set: { library.setPlaybackMode($0) })) {
                            Text("Mirrored").tag("mirrored")
                            Text("Per Display").tag("perDisplay")
                        }.pickerStyle(.segmented)
                        if library.playbackMode == "perDisplay" {
                            Picker("Display", selection: $library.display) {
                                ForEach(library.screens, id: \.self) { screen in Text(screen.localizedName).tag(displayID(screen)) }
                            }.labelsHidden().frame(maxWidth: .infinity)
                        }
                        Button { library.applySelected() } label: { Label("Play Backdrop", systemImage: "play.fill").frame(maxWidth: .infinity).padding(.vertical, 7) }.buttonStyle(.borderedProminent)
                    }
                    Divider().opacity(0.3)
                    if w.kind == "video", let source = library.disk.url(for: w) {
                        Button { VideoEditorWindow.open(wallpaper: w, source: source, library: library) } label: {
                            Label("Edit and export video…", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity)
                        }
                        Button("Export scene package…") { library.choosePackageExport(w) }
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        Text("MAKE IT YOURS").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                        if w.kind != "image" { slider("Speed", value: binding(\.speed, w), range: 0.25...2, suffix: String(format: "%.2f×", w.speed)) }
                        slider("Dim", value: binding(\.dimming, w), range: 0...0.85, suffix: "\(Int(w.dimming * 100))%")
                        if w.kind == "video" { slider("Volume", value: binding(\.volume, w), range: 0...1, suffix: "\(Int(w.volume * 100))%") }
                        if w.file != nil { Toggle("Fit entire image", isOn: binding(\.fit, w)).font(.caption) }
                    }
                    Divider().opacity(0.3)
                    VStack(alignment: .leading, spacing: 9) {
                        Text("ORGANIZE").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                        TextField("Scene name", text: $ui.draftTitle).onSubmit { var v = library.selected ?? w; if !ui.draftTitle.trimmingCharacters(in: .whitespaces).isEmpty { v.title = ui.draftTitle; library.edit(v) } }
                        TextField("Tags, separated by commas", text: $ui.draftTags).onSubmit { var v = library.selected ?? w; v.tags = ui.draftTags; library.edit(v) }
                        Text("Press Return to save text edits.").font(.system(size: 9)).foregroundStyle(.tertiary)
                        Menu {
                            ForEach(library.state.playlists) { p in Button((p.items.contains(w.id) ? "✓ " : "") + p.name) { library.toggleInPlaylist(w.id, p.id) } }
                        } label: { Label("Add to playlist", systemImage: "text.badge.plus") }.frame(maxWidth: .infinity)
                    }.textFieldStyle(.roundedBorder)
                    Text("Desktop playback • No subscription").font(.system(size: 9)).foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.top, 10)
                }.padding(20)
                .onAppear { ui.draftTitle = w.title; ui.draftTags = w.tags }
                .onChange(of: w.id) { _, _ in ui.draftTitle = w.title; ui.draftTags = w.tags }
            } else { ContentUnavailableView("Select a scene", systemImage: "sparkles").padding(.top, 100) }
        }
    }
    private func binding<T>(_ key: WritableKeyPath<Wallpaper, T>, _ original: Wallpaper) -> Binding<T> {
        Binding(get: { (library.state.item(original.id) ?? original)[keyPath: key] }, set: { newValue in var v = library.state.item(original.id) ?? original; v[keyPath: key] = newValue; library.edit(v) })
    }
    private func slider(_ name: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        VStack(spacing: 5) { HStack { Text(name); Spacer(); Text(suffix).foregroundStyle(.secondary).monospacedDigit() }.font(.system(size: 11)); Slider(value: value, in: range) }
    }
}

struct SettingsView: View {
    @EnvironmentObject var library: Library
    var body: some View {
        Form {
            Section("Playback") {
                Picker("Display mode", selection: Binding(get: { library.playbackMode }, set: { library.setPlaybackMode($0) })) {
                    Text("Mirrored").tag("mirrored")
                    Text("Per Display").tag("perDisplay")
                }
                Toggle("Pause behind fullscreen apps", isOn: $library.state.pauseOnFullscreen)
                Toggle("Pause while running on battery", isOn: $library.state.pauseOnBattery)
                Toggle("Pause in Low Power Mode", isOn: Binding(get: { library.state.pauseOnLowPower ?? false }, set: { library.state.pauseOnLowPower = $0; library.settingChanged() }))
                Text("Wallpaper playback also pauses when the display sleeps or the session locks.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Playlists") {
                Picker("Change scene every", selection: $library.state.interval) {
                    Text("30 seconds").tag(30.0); Text("1 minute").tag(60.0); Text("5 minutes").tag(300.0); Text("15 minutes").tag(900.0); Text("30 minutes").tag(1800.0); Text("1 hour").tag(3600.0)
                }
                Toggle("Shuffle playlists", isOn: $library.state.shuffle)
            }
            Section("General") {
                Toggle("Open at login", isOn: Binding(get: { library.loginEnabled() }, set: { library.setLogin($0) }))
                Button("Show media folder in Finder") { NSWorkspace.shared.open(library.disk.assets) }
                Text("Flua stores its own copies of imported media. Closing the window keeps wallpapers running; quitting restores the underlying wallpaper.").font(.caption).foregroundStyle(.secondary)
            }
            Section("About") {
                Text("Flua 0.1.0 • Independent native wallpaper app").font(.callout)
                Text("Discover, browse, create, edit, playlists and per-display playback are built in. Everything in your library remains local.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).padding(8)
            .onChange(of: library.state.pauseOnFullscreen) { _, _ in library.settingChanged() }
            .onChange(of: library.state.pauseOnBattery) { _, _ in library.settingChanged() }
            .onChange(of: library.state.interval) { _, _ in library.save() }
            .onChange(of: library.state.shuffle) { _, _ in library.save() }
    }
}
