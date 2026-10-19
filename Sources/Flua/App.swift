import SwiftUI
import AppKit
import Combine

final class ViewState: ObservableObject {
    @Published var columnVisibility: NavigationSplitViewVisibility = .all
    @Published var transportHeight: CGFloat = 0
    @Published var creatingPlaylist = false
    @Published var playlistName = ""
    @Published var deleting: Wallpaper?
    @Published var dragOver = false
    @Published var draftTitle = ""
    @Published var draftTags = ""
    @Published var draftCategory = ""
    @Published var blockedTagDraft = ""
    @Published var confirmingNativeRemoval = false
}


extension Library {
    var accent: Color { accentOverride ?? AppAccent.system.color }
    // Apply only to accent controls; a container tint also restyles neutral buttons.
    var accentOverride: Color? {
        let choice = AppAccent(rawValue: state.accentColor ?? "") ?? .system
        return choice == .system ? nil : choice.color
    }
}

private struct FrostedSurface<S: Shape>: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let shape: S
    let clear: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        let base = content
            .background {
                if reduceTransparency {
                    shape.fill(Color(nsColor: .windowBackgroundColor))
                } else if clear {
                    shape.fill(scheme == .dark ? Color.white.opacity(0.14) : Color.white.opacity(0.35))
                } else {
                    shape.fill(.ultraThinMaterial)
                        .overlay {
                            shape.fill(scheme == .dark ? Color.black.opacity(0.2) : Color.white.opacity(0.3))
                        }
                }
            }
            .overlay {
                shape.stroke(LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.24 : 0.7), .white.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
        if clear {
            base
        } else {
            base.shadow(color: .black.opacity(scheme == .dark ? 0.16 : 0.06), radius: 12, y: 4)
        }
    }
}

struct FluaGlassButtonStyle: PrimitiveButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        Button(configuration).buttonStyle(.borderless)
            .foregroundStyle(configuration.role == .destructive ? Color.red : Color.primary)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .fluaGlass(in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .opacity(enabled ? 1 : 0.45)
    }
}

struct FluaGlassTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain).multilineTextAlignment(.leading)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .fluaGlass(clear: true, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct ClearInitialFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { FocusClearView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class FocusClearView: NSView {
    private var closeObserver: Any?
    private var becomeKeyObserver: Any?
    private var mouseMonitor: Any?

    override var canBecomeKeyView: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        cleanObservers()
        guard let window = self.window else { return }
        clearFocus(in: window)

        becomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            guard let self, let window else { return }
            self.clearFocus(in: window)
        }

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak window] _ in
            window?.makeFirstResponder(nil)
        }

        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            if let window = self?.window, event.window == window {
                DispatchQueue.main.async { [weak window] in
                    guard let window else { return }
                    if !(window.firstResponder is NSTextView) {
                        window.makeFirstResponder(nil)
                    }
                }
            }
            return event
        }
    }

    private func clearFocus(in window: NSWindow) {
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            if !(window.firstResponder is NSTextView) {
                window.makeFirstResponder(nil)
            }
        }
    }

    private func cleanObservers() {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
        if let becomeKeyObserver {
            NotificationCenter.default.removeObserver(becomeKeyObserver)
            self.becomeKeyObserver = nil
        }
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
    }

    deinit {
        cleanObservers()
    }
}

struct FluaSegmentedPicker<Value: Hashable>: View {
    @EnvironmentObject private var library: Library
    let title: String
    @Binding var selection: Value
    let choices: [(String, Value)]
    var showsLabel = true
    @FocusState private var focusedChoice: Value?

    var body: some View {
        LabeledContent {
            HStack(spacing: 2) {
                ForEach(choices, id: \.1) { label, value in
                    let isTabTarget = (selection == value) || (!choices.contains(where: { $0.1 == selection }) && choices.first?.1 == value)
                    Button {
                        selection = value
                        if NSApp.currentEvent?.type == .keyDown || NSApp.currentEvent?.type == .keyUp {
                            focusedChoice = value
                        } else {
                            focusedChoice = nil
                        }
                    } label: {
                        Text(label)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 6).padding(.vertical, 5)
                            .background {
                                if selection == value {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(.tint.opacity(0.15))
                                        .fluaGlass(clear: true, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focused($focusedChoice, equals: value)
                    .focusable(isTabTarget || focusedChoice == value)
                    .accessibilityLabel(title + ": " + label)
                    .accessibilityAddTraits(selection == value ? [.isSelected] : [])
                }
            }
            .font(.system(size: 13))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title)
            .padding(3)
            .fluaGlass(clear: true, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .onMoveCommand { direction in
                guard let index = choices.firstIndex(where: { $0.1 == (focusedChoice ?? selection) }) else { return }
                let next: Int
                switch direction {
                case .left: next = max(0, index - 1)
                case .right: next = min(choices.count - 1, index + 1)
                default: return
                }
                selection = choices[next].1
                focusedChoice = selection
            }
        } label: {
            if showsLabel { Text(title).fixedSize(horizontal: true, vertical: false) }
        }.tint(library.accent)
    }
}

struct LibraryColorOption: View {
    let color: String

    private var swatchColor: NSColor {
        let color: Color
        switch self.color {
        case "Red": color = .red
        case "Orange": color = .orange
        case "Yellow": color = .yellow
        case "Green": color = .green
        case "Cyan": color = .cyan
        case "Blue": color = .blue
        case "Purple": color = .purple
        case "Pink": color = .pink
        default: color = .gray
        }
        return NSColor(color)
    }

    private var swatch: NSImage {
        let nativeColor = swatchColor
        return NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            nativeColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    var body: some View {
        Label {
            Text(color)
        } icon: {
            Image(nsImage: swatch).renderingMode(.original)
        }
    }
}

extension View {
    func fluaGlass(clear: Bool = false, in shape: some Shape) -> some View {
        modifier(FrostedSurface(shape: shape, clear: clear))
    }
    func fluaProminentButton() -> some View {
        fluaGlassButton()
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.tint.opacity(0.16))
                    .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.tint.opacity(0.4), lineWidth: 1) }
                    .allowsHitTesting(false)
            }
    }
    func fluaGlassButton() -> some View {
        buttonStyle(FluaGlassButtonStyle())
    }
    func fluaGlassMenu() -> some View {
        menuStyle(.borderlessButton).buttonStyle(.borderless).toggleStyle(.automatic)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .fluaGlass(clear: true, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    func fluaMenuPicker() -> some View {
        pickerStyle(.menu).fluaGlassMenu()
    }
    func fluaGlassGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
    }
    func fluaGlassRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8, content: content)
    }
    func fluaClearInitialFocus() -> some View {
        background(ClearInitialFocus())
    }
    func fluaBackdrop(accent: Color) -> some View {
        background {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                RadialGradient(colors: [accent.opacity(0.16), .clear], center: .topLeading, startRadius: 0, endRadius: 700)
                RadialGradient(colors: [Color.orange.opacity(0.07), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 600)
            }.ignoresSafeArea()
        }
    }
}

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
    var openLibrary: (() -> Void)?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openLibrary?()
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--accessibility-audit") || arguments.contains("--preview-smoke") {
            if arguments.contains("--accessibility-audit") { NSApp.setActivationPolicy(.accessory) }
            return
        }
        AppContext.library.applyPresence()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.arguments.contains("--accessibility-audit") {
            for window in NSApp.windows { SmokeRunner.park(window) }
            Task { await SmokeRunner.runAuditIfRequested(library: AppContext.library) }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-smoke") {
            Task { await SmokeRunner.runPreviewSmokeIfRequested() }
            return
        }
        DispatchQueue.main.async { self.openLibrary?() }
        Task { await SmokeRunner.runIfRequested(library: AppContext.library) }
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) { AppContext.library.importMedia(filenames.map { URL(fileURLWithPath: $0) }) }
}

@main struct FluaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow
    @StateObject var library = AppContext.library
    var body: some Scene {
        let _ = appDelegate.openLibrary = {
            openWindow(id: "library")
            NSApp.activate()
        }
        Window("Flua", id: "library") {
            LibraryView().environmentObject(library)
                .frame(minWidth: 1050, minHeight: 680)
        }
        .defaultSize(width: 1320, height: 840)
        // Smoke tests start without an automatic window to exercise explicit launch handling.
        .defaultLaunchBehavior(ProcessInfo.processInfo.arguments.contains("--smoke-test") || ProcessInfo.processInfo.arguments.contains("--preview-smoke") ? .suppressed : .presented)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Create New Flua…") { library.createWallpaper() }.keyboardShortcut("n")
                Button("Import media or scene package…") { library.chooseMedia() }.keyboardShortcut("i")
            }
            CommandMenu("Playback") {
                Button(library.state.paused ? "Resume" : "Pause") { library.togglePause() }.keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Previous on every display") { library.advancePlaylists(force: true, backwards: true, allDisplays: true) }.keyboardShortcut(.leftArrow, modifiers: [.command])
                Button("Next on every display") { library.advancePlaylists(force: true, allDisplays: true) }.keyboardShortcut(.rightArrow, modifiers: [.command])
                Button("Stop wallpapers") { library.stop() }
            }
        }
        Settings { SettingsView().environmentObject(library).frame(width: 530) }
        MenuBarExtra(isInserted: Binding(get: { library.state.showsMenuBar }, set: { library.setShowsMenuBar($0) })) {
            TrayView().environmentObject(library)
        } label: {
            Image(nsImage: MenuBarIcon.sakura).accessibilityLabel("Flua")
        }
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
        NavigationSplitView(columnVisibility: $ui.columnVisibility) {
            sidebar
                .toolbar(removing: .sidebarToggle)
                .toolbar {
                    ToolbarItem(placement: ui.columnVisibility == .detailOnly ? .navigation : .automatic) {
                        Button {
                            withAnimation { ui.columnVisibility = ui.columnVisibility == .detailOnly ? .all : .detailOnly }
                        } label: {
                            Image(systemName: "sidebar.left")
                        }
                        .fluaGlassButton()
                        .help(ui.columnVisibility == .detailOnly ? "Show Sidebar" : "Hide Sidebar")
                        .accessibilityLabel(ui.columnVisibility == .detailOnly ? "Show Sidebar" : "Hide Sidebar")
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
        } detail: {
            GeometryReader { geometry in
                ScrollView {
                    Group {
                        if library.section == "discover" { discoverContent }
                        else { libraryContent }
                    }
                    .padding(.top, geometry.safeAreaInsets.top)
                    .padding(.bottom, ui.transportHeight)
                }
                .ignoresSafeArea(.container, edges: .top)
                .overlay(alignment: .bottom) {
                    transport(compact: geometry.size.width < 650)
                        .fluaGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .padding(12)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                            if abs(ui.transportHeight - $0) > 0.5 { ui.transportHeight = $0 }
                        }
                        .padding(.trailing, NSScroller.scrollerWidth(for: .regular, scrollerStyle: NSScroller.preferredScrollerStyle))
                }
            }
        }
        .inspector(isPresented: .constant(true)) {
            InspectorView().inspectorColumnWidth(min: 280, ideal: 304, max: 360)
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fluaBackdrop(accent: library.accent)
        .fluaClearInitialFocus()
        .toggleStyle(.switch)
        .textFieldStyle(FluaGlassTextFieldStyle())
        .overlay {
            if ui.dragOver {
                RoundedRectangle(cornerRadius: 16).strokeBorder(library.accent, lineWidth: 2).padding(16)
                    .overlay(Text("Drop videos or images to import").font(.title3).padding(16).fluaGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous)))
            }
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
    private var displayed: [Wallpaper] { library.visible }
    private var sectionSelection: Binding<String?> {
        Binding(get: { library.section }, set: { value in
            guard let value, value != library.section else { return }
            library.section = value
            if value == "discover" { library.query = "" }
        })
    }
    private var libraryContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            pageHeader
            browseToolbar
            if displayed.isEmpty {
                ContentUnavailableView("No Wallpapers Available", systemImage: "photo.on.rectangle.angled", description: Text("Import media or clear your search and filters. Hidden tags can be adjusted in Settings → Blocked tags."))
                    .frame(maxWidth: .infinity, minHeight: 320)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                    ForEach(displayed) { wallpaperCard($0) }
                }
            }
        }.padding(24)
    }
    private var discoverContent: some View {
        VStack(alignment: .leading, spacing: 32) {
            pageHeader
            browseToolbar
            if library.eligible.isEmpty {
                ContentUnavailableView("No Wallpapers Available", systemImage: "photo.on.rectangle.angled", description: Text("Clear filters or adjust Settings → Blocked tags to show hidden content."))
            }
            discoverShelf("Featured", wallpapers: Array(library.eligible.prefix(3)), large: true)
            discoverShelf("Animated", wallpapers: library.eligible.filter { $0.kind != "image" })
            if library.eligible.contains(where: { $0.file != nil }) {
                discoverShelf("Your Wallpapers", wallpapers: library.eligible.filter { $0.file != nil })
            }
        }.padding(24)
    }
    private var pageHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(library.sectionTitle).font(.system(size: 32, weight: .bold, design: .serif))
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
                        Text("Every day").tag(86400.0)
                    }
                    Toggle("Shuffle", isOn: Binding(
                        get: { library.state.playlist(id)?.shuffle ?? library.state.shuffle },
                        set: { library.updatePlaylist(id, shuffle: $0) }))
                    Button("Duplicate Playlist") { library.duplicatePlaylist(id) }
                } label: { Label("Playlist Options", systemImage: "ellipsis.circle") }.fluaGlassMenu()
            }
            fluaGlassRow {
                if library.section.hasPrefix("playlist:") {
                    let id = String(library.section.dropFirst(9))
                    Button { library.startPlaylist(id) } label: { Label("Play", systemImage: "play.fill") }
                        .fluaProminentButton().tint(library.accentOverride)
                }
                Button { library.chooseMedia() } label: { Label(library.importing ? "Importing…" : "Import", systemImage: "square.and.arrow.down") }
                    .disabled(library.importing).fluaGlassButton()
                Button { library.createWallpaper() } label: { Label("Create", systemImage: "plus") }
                    .fluaProminentButton().tint(library.accentOverride)
            }
        }
    }
    @ViewBuilder private func discoverShelf(_ title: String, wallpapers: [Wallpaper], large: Bool = false) -> some View {
        if !wallpapers.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(title).font(.system(size: 20, weight: .semibold))
                    Spacer()
                    Button("Show All") { library.section = "browse" }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
                if large, let lead = wallpapers.first {
                    wallpaperCard(lead).frame(maxWidth: 560, alignment: .leading)
                    if wallpapers.count > 1 { shelfRow(Array(wallpapers.dropFirst())) }
                } else {
                    shelfRow(wallpapers)
                }
            }
        }
    }
    private func shelfRow(_ wallpapers: [Wallpaper]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 16) {
                ForEach(wallpapers) { wallpaperCard($0).frame(width: 240, height: 150) }
            }
        }
    }
    private var browseToolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                FluaSegmentedPicker(title: "Playback type", selection: $library.filter.kind,
                    choices: [("All", "all"), ("Animated", "animated"), ("Still", "still")])
                    .frame(width: 260)
                Spacer()
                if library.section == "browse" {
                    Picker("Sort By", selection: $library.browseSort) {
                        Text("Name").tag("name"); Text("Favorites First").tag("favorites")
                    }.fluaMenuPicker().frame(width: 176)
                }
            }
            ScrollView(.horizontal) {
                HStack {
                    FilterMenu(title: "Category", choices: Array(Set(LibraryChoices.categories + library.state.wallpapers.filter { !library.state.isBlocked($0) }.map(\.category))).sorted(), selection: $library.filter.categories)
                    FilterMenu(title: "Color", choices: LibraryChoices.colors, selection: $library.filter.colors, showsColorSwatches: true)
                    FilterMenu(title: "Motion", choices: LibraryChoices.motions, selection: $library.filter.motions)
                    FilterMenu(title: "Resolution", choices: LibraryChoices.resolutions, selection: $library.filter.resolutions)
                    FilterMenu(title: "Aspect", choices: LibraryChoices.aspects, selection: $library.filter.aspects)
                }
            }
            if library.filter.activeCount > 0 || !library.query.isEmpty {
                HStack {
                    Text("\(library.filter.activeCount) selected · \(library.eligible.count) matches").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear filters") { library.clearFilters() }.fluaGlassButton()
                }
                if !library.filter.tags.isEmpty {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(library.filter.tags.sorted(), id: \.self) { tag in
                                Button { library.filter.tags.remove(tag) } label: { Label(tag, systemImage: "xmark.circle") }
                                    .accessibilityLabel("Remove " + tag + " filter")
                                    .help("Remove tag filter: " + tag)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .fluaGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    private func wallpaperCard(_ w: Wallpaper) -> some View {
        WallpaperCard(wallpaper: w, selected: library.selection == w.id)
            .onTapGesture { library.selection = w.id }
            .onTapGesture(count: 2) { library.selection = w.id; library.applySelected() }
            .contextMenu {
                Button("Play Wallpaper") { library.selection = w.id; library.applySelected() }
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
        List(selection: sectionSelection) {
            Section {
                Label("Discover", systemImage: "sparkles").tag("discover")
                Label("Browse", systemImage: "rectangle.grid.2x2").tag("browse")
            }
            Section("Library") {
                Label("All Wallpapers", systemImage: "books.vertical").tag("all")
                Label("Favorites", systemImage: "heart").tag("favorites")
                Label("Your media", systemImage: "film").tag("imports")
            }
            Section("Playlists") {
                Button { ui.creatingPlaylist = true } label: { Label("Create playlist", systemImage: "plus") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).tint(.secondary).help("Create playlist")
                ForEach(library.state.playlists) { playlist in
                    Label(playlist.name, systemImage: "music.note.list").tag("playlist:" + playlist.id)
                        .contextMenu { Button("Delete playlist", role: .destructive) { library.deletePlaylist(playlist.id) } }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(.ultraThinMaterial)
        .tint(library.accent)
        .safeAreaInset(edge: .top, spacing: 0) { sidebarHeader }
        .safeAreaInset(edge: .bottom, spacing: 0) { sidebarFooter }
        .navigationSplitViewColumnWidth(min: 208, ideal: 224, max: 256)
    }
    private var sidebarHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(nsImage: MenuBarIcon.sakura).renderingMode(.template).resizable().frame(width: 22, height: 22).foregroundStyle(library.accent).accessibilityHidden(true)
                Text("Flua").font(.system(size: 22, weight: .semibold, design: .serif))
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $library.query).textFieldStyle(.plain).accessibilityLabel("Search")
                    .onChange(of: library.query) { _, value in
                        if !value.isEmpty && library.section == "discover" { library.section = "browse" }
                    }
                if !library.query.isEmpty {
                    Button { library.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("Clear search").help("Clear search")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .fluaGlass(in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .padding(16)
    }
    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { library.chooseMedia() } label: { Label("Import Scene…", systemImage: "square.and.arrow.down") }
                .buttonStyle(.plain)
            SettingsLink { Label("Settings", systemImage: "gearshape") }.buttonStyle(.plain)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }
    private func transport(compact: Bool) -> some View {
        let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 16))
        return layout {
            HStack(spacing: 8) {
                Circle().fill(library.state.paused ? Color.orange : library.accent).frame(width: 8, height: 8)
                Text(library.activity).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            HStack(spacing: 12) {
                FluaSegmentedPicker(title: "Display Mode", selection: Binding(get: { library.playbackMode }, set: { library.setPlaybackMode($0) }),
                    choices: [("Mirrored", "mirrored"), ("Per Display", "perDisplay")], showsLabel: false)
                    .frame(width: 190)
                fluaGlassRow {
                    Button { library.advancePlaylists(force: true, backwards: true) } label: { Image(systemName: "backward.end.fill") }
                        .accessibilityLabel("Previous in playlist").help("Previous in playlist").fluaGlassButton()
                    Button { library.advancePlaylists(force: true) } label: { Image(systemName: "forward.end.fill") }
                        .accessibilityLabel("Next in playlist").help("Next in playlist").fluaGlassButton()
                    Button { library.stop() } label: { Image(systemName: "stop.fill") }
                        .accessibilityLabel("Stop on selected displays").help("Stop on selected displays").fluaGlassButton()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }
}

struct WallpaperCard: View {
    @EnvironmentObject var library: Library
    let wallpaper: Wallpaper
    let selected: Bool
    var body: some View {
        // The photo is a background so its pixel size cannot stretch the card.
        Color.clear
            .aspectRatio(16/10, contentMode: .fit)
            .background {
                if let image = library.thumbnails[wallpaper.id] {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Color(nsColor: .quaternarySystemFill).overlay(Image(systemName: wallpaper.kind == "video" ? "film" : "photo").foregroundStyle(.secondary))
                }
            }
            .overlay { LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .center, endPoint: .bottom) }
            .overlay(alignment: .bottomLeading) {
                HStack(alignment: .bottom, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(wallpaper.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                        Text(wallpaper.kind == "image" ? "Still" : "Animated").font(.caption).foregroundStyle(.white.opacity(0.72))
                    }
                    Spacer(minLength: 0)
                    Button {
                        library.selection = wallpaper.id
                        library.applySelected()
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(7)
                            .fluaGlass(clear: true, in: Circle())
                            .environment(\.colorScheme, .dark)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Circle())
                    .accessibilityLabel("Play Wallpaper")
                }.padding(12)
                    .fluaGlass(clear: true, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .environment(\.colorScheme, .dark)
                    .padding(8)
            }
            .overlay(alignment: .topTrailing) {
                Button { library.favorite(wallpaper) } label: {
                    Image(systemName: wallpaper.favorite ? "heart.fill" : "heart").font(.system(size: 12)).foregroundStyle(.white).padding(8)
                        .fluaGlass(clear: true, in: Circle()).environment(\.colorScheme, .dark)
                }
                .buttonStyle(.plain)
                .padding(8)
                .contentShape(Circle())
                .accessibilityLabel(wallpaper.favorite ? "Remove favorite" : "Add favorite")
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? library.accent : Color.primary.opacity(0.12), lineWidth: selected ? 2 : 1))
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            }
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
    @FocusState private var focusedTag: String?
    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                // Apply the toolbar inset as padding to keep native hit testing aligned with the content.
                ScrollView { content.padding(.top, geometry.safeAreaInsets.top) }
                    .ignoresSafeArea(.container, edges: .top)
                    .onChange(of: focusedTag) { _, tag in
                        if let tag { proxy.scrollTo(tag, anchor: .center) }
                    }
            }
        }
        .background(.ultraThinMaterial)
    }
    private var content: some View {
        Group {
            if let w = library.selected {
                VStack(alignment: .leading, spacing: 24) {
                    SurfacePreview(wallpaper: w, url: library.disk.url(for: w)).id(w.id).aspectRatio(16/10, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 8) {
                        Text(w.title).font(.system(size: 24, weight: .semibold, design: .serif))
                        Text(w.file == nil ? "An original animated scene, rendered on your Mac." : "Imported \(w.kind), stored in this library.").font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Play on").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        FluaSegmentedPicker(title: "Display Mode", selection: Binding(get: { library.playbackMode }, set: { library.setPlaybackMode($0) }),
                            choices: [("Mirrored", "mirrored"), ("Per Display", "perDisplay")])
                        if library.playbackMode == "perDisplay" {
                            Picker("Display", selection: $library.display) {
                                ForEach(library.screens, id: \.self) { screen in Text(screen.localizedName).tag(displayID(screen)) }
                            }.labelsHidden().fluaMenuPicker().frame(maxWidth: .infinity)
                        }
                        FluaSegmentedPicker(title: "Surface", selection: $library.surface,
                            choices: [("Desktop", .desktop), ("Lock Screen", .lockScreen)])
                        Toggle("Link Desktop and Lock Screen", isOn: Binding(get: { library.surfacesLinked }, set: { library.setSurfacesLinked($0) }))
                            .font(.caption).tint(library.accentOverride)
                        FluaSegmentedPicker(title: "Rendering mode", selection: Binding<WallpaperMode?>(get: { library.surfaceMode }, set: { if let mode = $0 { library.setSurfaceMode(mode) } }),
                            choices: (library.surfaceMode == nil ? [("Mixed", nil)] : []) + [("Animated", .animated), ("Still", .still)])
                        LabeledContent("Desktop", value: library.surfaceSummary(.desktop)).font(.caption)
                        LabeledContent("Lock Screen", value: library.surfaceSummary(.lockScreen)).font(.caption)
                        fluaGlassGroup {
                            VStack(alignment: .leading, spacing: 8) {
                                Button {
                                    library.applySelected()
                                } label: {
                                    Label(library.nativeSetupBusy ? "Working…" : "Play Wallpaper", systemImage: "play.fill")
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                }
                                .disabled(library.nativeSetupBusy)
                                .accessibilityLabel("Play Wallpaper")
                                .fluaProminentButton()
                                .tint(library.accentOverride)
                            }
                        }
                        Text("Applies directly to macOS. Continues playing when Flua quits.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    mediaFacts(w)
                    Divider().opacity(0.3)
                    if w.kind == "video", let source = library.disk.url(for: w) {
                        fluaGlassGroup {
                            VStack(alignment: .leading, spacing: 8) {
                                Button { VideoEditorWindow.open(wallpaper: w, source: source, library: library) } label: {
                                    Label("Edit and export video…", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity)
                                }.fluaGlassButton()
                                Button("Export scene package…") { library.choosePackageExport(w) }.fluaGlassButton()
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Playback").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        if w.kind != "image" { slider("Speed", value: binding(\.speed, w), range: 0.25...2, suffix: String(format: "%.2f×", w.speed)) }
                        slider("Dim", value: binding(\.dimming, w), range: 0...0.85, suffix: "\(Int(w.dimming * 100))%")
                        if w.kind == "video" { slider("Volume", value: binding(\.volume, w), range: 0...1, suffix: "\(Int(w.volume * 100))%") }
                        if w.file != nil { Toggle("Fit entire image", isOn: binding(\.fit, w)).font(.caption).tint(library.accentOverride) }
                    }
                    Divider().opacity(0.3)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Details").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        TextField("Scene name", text: $ui.draftTitle).accessibilityLabel("Scene name").onSubmit { var v = library.selected ?? w; if !ui.draftTitle.trimmingCharacters(in: .whitespaces).isEmpty { v.title = ui.draftTitle; library.edit(v) } }
                        TextField("Tags, separated by commas", text: $ui.draftTags).accessibilityLabel("Tags").onSubmit { var v = library.selected ?? w; v.tags = ui.draftTags; library.edit(v) }
                        TextField("Category", text: $ui.draftCategory).accessibilityLabel("Category").onSubmit {
                            var value = library.selected ?? w
                            if value.metadata == nil { value.metadata = SceneMetadata() }
                            value.metadata?.category = ui.draftCategory.trimmingCharacters(in: .whitespacesAndNewlines)
                            library.edit(value)
                        }
                        Picker("Color", selection: classificationBinding(\.color, w)) {
                            ForEach(LibraryChoices.colors, id: \.self) { color in LibraryColorOption(color: color).tag(color) }
                        }.fluaMenuPicker()
                        Picker("Motion intensity", selection: classificationBinding(\.motion, w)) {
                            ForEach(LibraryChoices.motions, id: \.self) { Text($0).tag($0) }
                        }.fluaMenuPicker()
                        let tags = normalizedTags(w.tags)
                        // Eager rows keep offscreen tags in the keyboard focus order.
                        Grid(alignment: .leading) {
                            ForEach(Array(stride(from: 0, to: tags.count, by: 3)), id: \.self) { start in
                                GridRow {
                                    ForEach(tags[start..<min(start + 3, tags.count)], id: \.self) { tag in
                                        Button(tag) { library.filterTag(tag) }
                                            .accessibilityLabel("Filter by " + tag)
                                            .help("Filter library by tag: " + tag)
                                            .frame(maxWidth: .infinity)
                                            .focused($focusedTag, equals: tag).id(tag)
                                    }
                                }
                            }
                        }
                        Text("Press Return to save text edits.").font(.caption).foregroundStyle(.tertiary)
                        Menu {
                            ForEach(library.state.playlists) { p in Button((p.items.contains(w.id) ? "✓ " : "") + p.name) { library.toggleInPlaylist(w.id, p.id) } }
                        } label: { Label("Add to playlist", systemImage: "text.badge.plus") }.fluaGlassMenu().frame(maxWidth: .infinity)
                    }.textFieldStyle(FluaGlassTextFieldStyle())
                }.padding(24)
                .onAppear { ui.draftTitle = w.title; ui.draftTags = w.tags; ui.draftCategory = w.metadata?.category ?? "" }
                .onChange(of: w.id) { _, _ in ui.draftTitle = w.title; ui.draftTags = w.tags; ui.draftCategory = w.metadata?.category ?? "" }
            } else { ContentUnavailableView("Select a scene", systemImage: "sparkles").padding(.top, 100) }
        }
        .buttonStyle(FluaGlassButtonStyle())
    }
    private func mediaFacts(_ w: Wallpaper) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            LabeledContent("Resolution", value: w.file == nil ? "Not applicable" : w.mediaFacts.flatMap { $0.hasDimensions ? "\($0.width!) × \($0.height!)" : nil } ?? "Unknown")
            LabeledContent("File size", value: w.file == nil ? "Not applicable" : w.mediaFacts?.bytes.flatMap { $0 >= 0 ? ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) : nil } ?? "Unknown")
            LabeledContent("Source duration", value: w.kind == "video" ? formattedDuration(w.mediaFacts?.sourceDuration) : "Not applicable")
            if let source = w.mediaFacts?.sourceDuration, let edited = w.editedDuration, abs(source - edited) > 0.001 {
                LabeledContent("Trimmed duration", value: formattedDuration(edited))
            }
            LabeledContent("Date added", value: w.dateAdded?.formatted(date: .abbreviated, time: .omitted) ?? "Unknown")
        }.font(.caption).textSelection(.enabled)
    }
    private func formattedDuration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "Unknown" }
        return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, fractionalPart: .show(length: 2)))
    }
    private func classificationBinding(_ key: WritableKeyPath<SceneMetadata, String?>, _ w: Wallpaper) -> Binding<String> {
        Binding(get: { let value = library.state.item(w.id) ?? w; return key == \.color ? value.color : value.motion }, set: { value in
            var updated = library.state.item(w.id) ?? w
            if updated.metadata == nil { updated.metadata = SceneMetadata() }
            updated.metadata?[keyPath: key] = value
            library.edit(updated)
        })
    }
    private func binding<T>(_ key: WritableKeyPath<Wallpaper, T>, _ original: Wallpaper) -> Binding<T> {
        Binding(get: { (library.state.item(original.id) ?? original)[keyPath: key] }, set: { newValue in var v = library.state.item(original.id) ?? original; v[keyPath: key] = newValue; library.edit(v) })
    }
    private func slider(_ name: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        // A nil tint leaves the track gray in this scrolling inspector.
        VStack(spacing: 8) { HStack { Text(name); Spacer(); Text(suffix).foregroundStyle(.secondary).monospacedDigit() }.font(.caption); Slider(value: value, in: range).tint(library.accent).accessibilityLabel(name) }
    }
}

struct SettingsView: View {
    @StateObject private var ui = ViewState()
    @EnvironmentObject var library: Library
    private func addBlockedTags() {
        library.blockTags(ui.blockedTagDraft)
        ui.blockedTagDraft = ""
    }
    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Accent color", selection: Binding(
                    get: { AppAccent(rawValue: library.state.accentColor ?? "") ?? .system },
                    set: { library.state.accentColor = $0 == .system ? nil : $0.rawValue; library.save() }
                )) {
                    ForEach(AppAccent.allCases, id: \.self) { choice in
                        Label {
                            Text(choice.rawValue)
                        } icon: {
                            Image(nsImage: choice.swatch).renderingMode(.original)
                        }.tag(choice)
                    }
                }.fluaMenuPicker()
                Text("System follows the accent color selected in macOS settings.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Playback") {
                Picker("Display mode", selection: Binding(get: { library.playbackMode }, set: { library.setPlaybackMode($0) })) {
                    Text("Mirrored").tag("mirrored")
                    Text("Per Display").tag("perDisplay")
                }.fluaMenuPicker()
                Toggle("Pause behind fullscreen apps", isOn: $library.state.pauseOnFullscreen).tint(library.accentOverride)
                Toggle("Pause while running on battery", isOn: $library.state.pauseOnBattery).tint(library.accentOverride)
                Toggle("Pause in Low Power Mode", isOn: Binding(get: { library.state.pauseOnLowPower ?? false }, set: { library.state.pauseOnLowPower = $0; library.settingChanged() })).tint(library.accentOverride)
                Text("Wallpaper playback also pauses when the display sleeps or the session locks.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Playlists") {
                Toggle("Shuffle playlists", isOn: $library.state.shuffle).tint(library.accentOverride)
            }
            Section("Blocked tags") {
                HStack {
                    TextField("", text: $ui.blockedTagDraft, prompt: Text("Tags, separated by commas")).accessibilityLabel("Blocked tags").onSubmit { addBlockedTags() }
                    Button("Block") { addBlockedTags() }.disabled(normalizedTags(ui.blockedTagDraft).isEmpty)
                }
                if !library.state.blockedTags.isEmpty {
                    ScrollView {
                        VStack {
                            ForEach(library.state.blockedTags, id: \.self) { tag in
                                HStack {
                                    Text(tag)
                                    Spacer()
                                    Button("Unblock") { library.unblockTag(tag) }.accessibilityLabel("Unblock " + tag)
                                }
                            }
                        }
                    }.frame(maxHeight: 110)
                }
                Text("Matching tags hide wallpapers throughout the library. Files, playlists and playback assignments are preserved.").font(.caption).foregroundStyle(.secondary)
            }
            Section("General") {
                Toggle("Show in menu bar", isOn: Binding(get: { library.state.showsMenuBar }, set: { library.setShowsMenuBar($0) })).tint(library.accentOverride)
                Toggle("Hide from Dock", isOn: Binding(get: { library.state.hidesDockIcon }, set: { library.setHidesDockIcon($0) }))
                    .disabled(!library.state.showsMenuBar)
                    .tint(library.accentOverride)
                Text("The Dock icon can be hidden while Flua remains in the menu bar.").font(.caption).foregroundStyle(.secondary)
                Toggle("Open at login", isOn: Binding(get: { library.loginEnabled() }, set: { library.setLogin($0) })).tint(library.accentOverride)
                Button("Show media folder in Finder") { NSWorkspace.shared.open(library.disk.assets) }
                Text("Flua stores its own copies of imported media. Wallpapers play natively through macOS and continue playing after quitting Flua.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Lock Screen") {
                Text(NativeWallpaper.explanation).font(.caption).foregroundStyle(.secondary)
                if NativeWallpaper.available {
                    Button("Remove native provider…", role: .destructive) { ui.confirmingNativeRemoval = true }
                        .disabled(library.nativeSetupBusy)
                        .confirmationDialog("Remove native wallpaper provider?", isPresented: $ui.confirmingNativeRemoval) {
                            Button("Restore wallpapers and remove provider", role: .destructive) { library.removeNativeProvider() }
                        } message: {
                            Text("Restores the saved system wallpapers wherever Flua is still selected, then unregisters this copy of the provider. Your library and media are kept. Apply again to set it up later.")
                        }
                    Text("Removal restores saved system wallpapers and stops native playback. Keep this app and your library in place while Flua is selected.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("About") {
                Text("Flua 1.2 • Independent native wallpaper app").font(.callout)
                Text("Discover, browse, create, edit, playlists and per-display playback are built in. Everything in your library remains local.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden).padding(8)
            .fluaBackdrop(accent: library.accent)
            .fluaClearInitialFocus()
            .toggleStyle(.switch)
            .buttonStyle(FluaGlassButtonStyle())
            .textFieldStyle(FluaGlassTextFieldStyle())
            .onChange(of: library.state.pauseOnFullscreen) { _, _ in library.settingChanged() }
            .onChange(of: library.state.pauseOnBattery) { _, _ in library.settingChanged() }
            .onChange(of: library.state.shuffle) { _, _ in library.save() }
    }
}

struct FilterMenu: View {
    let title: String
    let choices: [String]
    @Binding var selection: Set<String>
    var showsColorSwatches = false

    var body: some View {
        Menu {
            ForEach(choices, id: \.self) { value in
                Toggle(isOn: Binding(get: { selection.contains(value) }, set: { included in
                    if included { selection.insert(value) } else { selection.remove(value) }
                })) {
                    if showsColorSwatches {
                        LibraryColorOption(color: value)
                    } else {
                        Text(value)
                    }
                }
            }
        } label: {
            Text(selection.isEmpty ? title : title + ": " + selection.sorted().joined(separator: ", "))
                .lineLimit(1)
        }
        .fluaGlassMenu()
        .fixedSize()
        .accessibilityLabel(title + " filter")
    }
}
