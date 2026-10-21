import SwiftUI
import AppKit
import Combine

final class ViewState: ObservableObject {
    @Published var playlistPicker: String?
    @Published var pickerSelected = Set<String>()
    @Published var pickerQuery = ""
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
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
            .buttonStyle(GlassPressEffect(prominent: prominent))
    }
}

private struct GlassPressEffect: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.role == .destructive ? Color.red : Color.primary)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .fluaGlass(in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                if prominent {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.tint.opacity(0.16))
                        .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.tint.opacity(0.4), lineWidth: 1) }
                        .allowsHitTesting(false)
                }
            }
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.1), value: configuration.isPressed)
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
        SmokeRunner.configureVerificationWindow(window)
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
        buttonStyle(FluaGlassButtonStyle(prominent: true))
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
            if args.contains("--smoke-test") {
                guard let i = args.firstIndex(of: "--data-dir"), args.indices.contains(i + 1),
                      !args[i + 1].isEmpty, !args[i + 1].hasPrefix("--") else {
                    throw NativeWallpaperError("Smoke verification requires an isolated --data-dir.")
                }
            }
            let root: URL
            if let i = args.firstIndex(of: "--data-dir"), args.indices.contains(i + 1) {
                root = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            } else {
                let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                root = LibraryPaths.resolve(applicationSupport: support)
            }
            return try Library(root: root, systemPlaybackEnabled: !args.contains("--smoke-test"))
        }
        catch {
            if args.contains("--smoke-test") {
                fputs("Flua smoke: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
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
        if arguments.contains("--accessibility-audit") || arguments.contains("--preview-smoke") || arguments.contains("--smoke-test") {
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
            if !ProcessInfo.processInfo.arguments.contains("--smoke-test") { NSApp.activate() }
        }
        Window("Flua", id: "library") {
            LibraryView().environmentObject(library)
                .frame(minWidth: 700, minHeight: 440)
                .windowFullScreenBehavior(ProcessInfo.processInfo.arguments.contains("--smoke-test") || ProcessInfo.processInfo.arguments.contains("--preview-smoke") ? .disabled : .automatic)
        }
        .defaultSize(width: 1320, height: 840)
        // Smoke tests start without an automatic window to exercise explicit launch handling.
        .defaultLaunchBehavior(ProcessInfo.processInfo.arguments.contains("--smoke-test") || ProcessInfo.processInfo.arguments.contains("--preview-smoke") ? .suppressed : .presented)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Wallpaper…") { library.chooseMedia() }.keyboardShortcut("n")
            }
            CommandMenu("Playback") {
                Button(library.state.paused ? "Resume playlists" : "Pause playlists") { library.togglePlaylistPause() }.keyboardShortcut("p", modifiers: [.command, .shift])
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
        Button(library.state.paused ? "Resume playlists" : "Pause playlists") { library.togglePlaylistPause() }
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
        GeometryReader { windowGeometry in
            NavigationSplitView(columnVisibility: $ui.columnVisibility) {
                sidebar
                    .toolbar(removing: .sidebarToggle)
            } detail: {
                GeometryReader { geometry in
                    let isCompact = geometry.size.width < 650
                    ScrollViewReader { proxy in
                    ScrollView {
                        Group {
                            libraryContent(width: geometry.size.width)
                        }
                        .padding(.top, geometry.safeAreaInsets.top)
                        .padding(.bottom, ui.transportHeight)
                    }
                    .ignoresSafeArea(.container, edges: .top)
                    .overlay(alignment: .bottom) {
                        transport(compact: isCompact, stackedControls: geometry.size.width < 380)
                            .fluaGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .padding(12)
                            .padding(.trailing, NSScroller.scrollerWidth(for: .regular, scrollerStyle: NSScroller.preferredScrollerStyle))
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                                if abs(ui.transportHeight - $0) > 0.5 { ui.transportHeight = $0 }
                            }
                    }
                    .onChange(of: library.lastImportIDs) { _, ids in
                        if !ids.isEmpty {
                            DispatchQueue.main.async { if let id = library.selection { proxy.scrollTo(id, anchor: .top) } }
                        }
                    }
                    }
                }
                .navigationSplitViewColumnWidth(min: 280, ideal: 800)
            }
            .inspector(isPresented: .constant(windowGeometry.size.width >= 1000)) {
                InspectorView().inspectorColumnWidth(min: 220, ideal: 280, max: 360)
            }
        }
        .sheet(isPresented: Binding(get: { ui.playlistPicker != nil }, set: { if !$0 { ui.playlistPicker = nil } })) {
            if let id = ui.playlistPicker { PlaylistWallpaperPicker(playlistID: id).environmentObject(library) }
        }
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .navigation) {
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
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fluaBackdrop(accent: library.accent)
        .fluaClearInitialFocus()
        .toggleStyle(.switch)
        .textFieldStyle(FluaGlassTextFieldStyle())
        .overlay {
            if ui.dragOver {
                RoundedRectangle(cornerRadius: 16).strokeBorder(library.accent, lineWidth: 2).padding(16)
                    .overlay(Text("Drop wallpapers to add").font(.title3).padding(16).fluaGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous)))
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $ui.dragOver) { providers in
            Task { @MainActor in await library.importDroppedFiles(providers) }
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
        .alert("Remove wallpaper?", isPresented: Binding(get: { ui.deleting != nil }, set: { if !$0 { ui.deleting = nil } })) {
            Button("Remove", role: .destructive) { if let w = ui.deleting { library.remove(w) }; ui.deleting = nil }
            Button("Cancel", role: .cancel) { ui.deleting = nil }
        } message: { Text("The wallpaper will be removed from playlists and stopped on any display. Imported files are kept in Flua’s media folder.") }
    }
    private var displayed: [Wallpaper] { library.visible }
    private var sectionSelection: Binding<String?> {
        Binding(get: { library.section }, set: { value in
            guard let value, value != library.section else { return }
            library.section = value
            if value == "discover" { library.query = "" }
        })
    }
    private func libraryContent(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            pageHeader(compact: width < 650)
            browseToolbar(compact: width < 650)
            if displayed.isEmpty {
                ContentUnavailableView {
                    Label("No Wallpapers", systemImage: "photo.on.rectangle.angled")
                }
                    .frame(maxWidth: .infinity, minHeight: 320)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                    ForEach(displayed) { wallpaperCard($0).id($0.id) }
                }
            }
        }.padding(24)
    }
    private func pageHeader(compact: Bool) -> some View {
        let layout = compact || library.section.hasPrefix("playlist:") ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        return layout {
            Text(library.sectionTitle).font(.system(size: compact ? 26 : 32, weight: .bold, design: .serif))
                .lineLimit(1)
            if !compact { Spacer(minLength: 8) }
            pageHeaderActions(compact: compact)
        }
    }
    private func pageHeaderActions(compact: Bool) -> some View {
        let layout = AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
        return layout {
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
            let buttonLayout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
            buttonLayout {
                if library.section.hasPrefix("playlist:") {
                    let id = String(library.section.dropFirst(9))
                    Button { library.startPlaylist(id) } label: { Label("Set Playlist", systemImage: "desktopcomputer") }
                        .fluaProminentButton().tint(library.accentOverride)
                }
                if library.section.hasPrefix("playlist:") {
                    Button("Add Wallpapers…") { ui.playlistPicker = String(library.section.dropFirst(9)) }.fluaGlassButton()
                }
                Button { library.chooseMedia() } label: { Label(library.importing ? "Adding…" : "Add Wallpaper…", systemImage: "plus") }
                    .disabled(library.importing)
                    .fluaProminentButton().tint(library.accentOverride)
            }
        }
    }
    private func browseToolbar(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
            FluaSegmentedPicker(title: "Source", selection: $library.filter.source,
                choices: [("All", "all"), ("Built-in", "builtin"), ("Imported", "imported")])
            layout {
                FluaSegmentedPicker(title: "Playback type", selection: $library.filter.kind,
                    choices: [("All", "all"), ("Animated", "animated"), ("Still", "still")])
                    .frame(maxWidth: 260)
                if !compact { Spacer(minLength: 8) }
                if !library.section.hasPrefix("playlist:") {
                    Picker("Sort By", selection: $library.browseSort) {
                        Text("Name").tag("name"); Text("Favorites First").tag("favorites"); Text("Recently Added").tag("recent")
                    }.fluaMenuPicker().frame(width: 230)
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
            if library.filter.activeCount > 0 || !library.query.isEmpty || library.browseSort != "name" {
                HStack {
                    Text("\(library.filter.activeCount) selected · \(library.visible.count) matches").font(.caption).foregroundStyle(.secondary)
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
        WallpaperCard(wallpaper: w, selected: library.selection == w.id || (library.importNotice != nil && library.lastImportIDs.contains(w.id)))
            .onTapGesture { library.selection = w.id }
            .contextMenu {
                Button("Set Wallpaper") { library.selection = w.id; library.applySelected() }
                Button(w.favorite ? "Remove from Favorites" : "Add to Favorites") { library.favorite(w) }
                if w.kind == "video", let source = library.disk.url(for: w) {
                    Button("Edit Video…") { VideoEditorWindow.open(wallpaper: w, source: source, library: library) }
                }
                if w.file != nil { Button("Export Wallpaper…") { library.choosePackageExport(w) } }
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
            Section("Library") {
                Label("Wallpapers", systemImage: "rectangle.grid.2x2").tag("all")
                Label("Favorites", systemImage: "heart").tag("favorites")
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
        .navigationSplitViewColumnWidth(min: 180, ideal: 224, max: 256)
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
            SettingsLink { Label("Settings", systemImage: "gearshape") }.buttonStyle(.plain)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }
    private func transport(compact: Bool, stackedControls: Bool) -> some View {
        let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 16))
        return layout {
            HStack(spacing: 8) {
                Circle().fill(library.state.paused ? Color.orange : library.accent).frame(width: 8, height: 8)
                Text(library.importNotice ?? library.activity).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if library.importNotice != nil {
                    Button("Undo") { library.undoImport() }.fluaGlassButton().fixedSize()
                    Button { library.importNotice = nil } label: { Image(systemName: "xmark") }.accessibilityLabel("Dismiss confirmation").fluaGlassButton()
                }
                Spacer(minLength: 0)
            }
            let controlsLayout = stackedControls ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))
            controlsLayout {
                FluaSegmentedPicker(title: "Display Mode", selection: Binding(get: { library.playbackMode }, set: { library.setPlaybackMode($0) }),
                    choices: [("Mirrored", "mirrored"), ("Per Display", "perDisplay")], showsLabel: false)
                    .frame(maxWidth: 190)
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
                VStack(alignment: .leading, spacing: 20) {
                    Text(w.title).font(.system(size: 24, weight: .semibold, design: .serif))
                    SurfacePreview(wallpaper: w, url: library.disk.url(for: w)).id(w.id).aspectRatio(16/10, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    detailsSection(w)
                    Divider().opacity(0.3)
                    settingsSection(w)
                    if w.kind == "video", let source = library.disk.url(for: w) {
                        trimSection(wallpaper: w, source: source)
                    }
                    setWallpapersSection(w)
                }.padding(24)
                .onAppear { ui.draftTitle = w.title; ui.draftTags = w.tags; ui.draftCategory = w.metadata?.category ?? "" }
                .onChange(of: w.id) { _, _ in ui.draftTitle = w.title; ui.draftTags = w.tags; ui.draftCategory = w.metadata?.category ?? "" }
            } else {
                ContentUnavailableView("Select a wallpaper", systemImage: "sparkles").padding(.top, 100)
            }
        }
        .textFieldStyle(FluaGlassTextFieldStyle())
        .toggleStyle(.switch)
        .buttonStyle(FluaGlassButtonStyle())
    }

    private func detailsSection(_ w: Wallpaper) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            detailsFields(w)

            Text("Press Return to save text edits.").font(.caption).foregroundStyle(.tertiary)

            Menu {
                ForEach(library.state.playlists) { p in
                    Button((p.items.contains(w.id) ? "✓ " : "") + p.name) { library.toggleInPlaylist(w.id, p.id) }
                }
            } label: {
                Label("Add to playlist", systemImage: "text.badge.plus")
            }
            .fluaGlassMenu()
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
        }
    }

    private func detailsFields(_ w: Wallpaper) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Wallpaper name", text: $ui.draftTitle)
                .accessibilityLabel("Wallpaper name")
                .onSubmit {
                    var v = library.selected ?? w
                    if !ui.draftTitle.trimmingCharacters(in: .whitespaces).isEmpty { v.title = ui.draftTitle; library.edit(v) }
                }
            TextField("Tags, separated by commas", text: $ui.draftTags)
                .accessibilityLabel("Tags")
                .onSubmit { var v = library.selected ?? w; v.tags = ui.draftTags; library.edit(v) }
            TextField("Category", text: $ui.draftCategory)
                .accessibilityLabel("Category")
                .onSubmit {
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
        }
    }

    private enum ConfigTarget: Hashable {
        case display(String)
        case lockScreen
    }

    private var visibleTargetChoices: [(String, ConfigTarget)] {
        var choices: [(String, ConfigTarget)] = []
        if library.playbackMode == "mirrored" {
            choices.append(("Desktop", .display("all")))
        } else {
            for screen in library.screens {
                choices.append((screen.localizedName, .display(displayID(screen))))
            }
        }
        if !library.surfacesLinked {
            choices.append(("Lock Screen", .lockScreen))
        }
        return choices
    }

    private var configTarget: ConfigTarget {
        let current: ConfigTarget
        if library.surface == .lockScreen { current = .lockScreen }
        else if library.playbackMode == "mirrored" { current = .display("all") }
        else { current = .display(library.display) }
        if visibleTargetChoices.contains(where: { $0.1 == current }) { return current }
        return visibleTargetChoices.first.map { $0.1 } ?? .lockScreen
    }

    private func settingsSection(_ w: Wallpaper) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Mirror all displays", isOn: Binding(
                get: { library.playbackMode == "mirrored" },
                set: { library.setPlaybackMode($0 ? "mirrored" : "perDisplay") }
            ))
            .font(.caption).tint(library.accentOverride)

            Toggle("Mirror Desktop and Lock Screen", isOn: Binding(
                get: { library.surfacesLinked },
                set: { library.setSurfacesLinked($0) }
            ))
            .font(.caption).tint(library.accentOverride)

            if library.playbackMode != "mirrored" || !library.surfacesLinked {
                FluaSegmentedPicker(title: "Configure", selection: Binding(
                    get: { configTarget },
                    set: { target in
                        switch target {
                        case .display(let id):
                            library.surface = .desktop
                            if library.playbackMode == "perDisplay" { library.display = id }
                        case .lockScreen:
                            library.surface = .lockScreen
                        }
                    }
                ), choices: visibleTargetChoices, showsLabel: false)
            }

            FluaSegmentedPicker(title: "Rendering mode", selection: Binding<WallpaperMode?>(get: { library.surfaceMode }, set: { if let mode = $0 { library.setSurfaceMode(mode) } }),
                choices: (library.surfaceMode == nil ? [("Mixed", nil)] : []) + [("Animated", .animated), ("Still", .still)])

            if w.file != nil {
                Toggle("Fit entire image", isOn: binding(\.fit, w)).font(.caption).tint(library.accentOverride)
            }

            if w.kind != "image" { NumericSlider(name: "Speed", value: binding(\.speed, w), range: 0.25...2, format: { String(format: "%.2f", $0) }, parse: { Double($0) }, unit: "×", accent: library.accent).id(w.id) }
            NumericSlider(name: "Dim", value: binding(\.dimming, w), range: 0...0.85, format: formatPercentage, parse: { Double($0).map { $0 / 100 } }, unit: "%", accent: library.accent).id(w.id)
            if w.kind == "video" { NumericSlider(name: "Volume", value: binding(\.volume, w), range: 0...1, format: formatPercentage, parse: { Double($0).map { $0 / 100 } }, unit: "%", accent: library.accent).id(w.id) }
        }
    }

    private func trimSection(wallpaper w: Wallpaper, source: URL) -> some View {
        fluaGlassGroup {
            VStack(alignment: .leading, spacing: 8) {
                Button { VideoEditorWindow.open(wallpaper: w, source: source, library: library) } label: {
                    Label("Trim range and choose cover", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity)
                }.fluaGlassButton()
            }
        }
    }

    private func setWallpapersSection(_ w: Wallpaper) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            fluaGlassGroup {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        library.applySelected()
                    } label: {
                        Label(library.nativeSetupBusy ? "Working…" : "Set Wallpapers", systemImage: "desktopcomputer")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .disabled(library.nativeSetupBusy)
                    .accessibilityLabel("Set Wallpapers")
                    .fluaProminentButton()
                    .tint(library.accentOverride)
                }
            }
            Text("Applies directly to macOS. Continues playing when Flua quits.")
                .font(.caption).foregroundStyle(.secondary)
        }
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
}

private struct NumericSlider: View {
    let name: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String
    let parse: (String) -> Double?
    let unit: String
    let accent: Color
    @FocusState private var isFocused: Bool
    @StateObject private var draft = NumericDraft()

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(name)
                Spacer()
                HStack(spacing: 2) {
                    TextField("", text: $draft.text)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .focused($isFocused)
                        .onSubmit { commit() }
                        .onChange(of: isFocused) { _, focused in
                            if focused { draft.text = format(value) } else { commit() }
                        }
                        .frame(width: 56)
                        .accessibilityLabel("\(name) value")
                        .help("Enter \(format(range.lowerBound))–\(format(range.upperBound))\(unit). Press Return to apply.")
                    Text(unit).font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            Slider(value: $value, in: range).tint(accent).accessibilityLabel(name)
        }
        .onAppear { draft.text = format(value) }
        .onChange(of: value) { _, newValue in draft.text = format(newValue) }
    }

    private func commit() {
        let (newValue, text) = applyNumericEntry(draft: draft.text, current: value, range: range, parse: parse, format: format)
        if value != newValue { value = newValue }
        draft.text = text
    }
}

private final class NumericDraft: ObservableObject {
    @Published var text: String = ""
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
                if library.state.pauseOnLowPower == true {
                    Picker("Battery pause threshold", selection: Binding(get: { library.state.lowPowerThreshold }, set: { library.state.lowPowerThreshold = $0; library.settingChanged() })) {
                        Text("10%").tag(10)
                        Text("20%").tag(20)
                        Text("30%").tag(30)
                        Text("50%").tag(50)
                    }.fluaMenuPicker()
                }
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
                Button("Show wallpaper folder in Finder") { NSWorkspace.shared.open(library.disk.assets) }
                Text("Flua stores its own copies of imported wallpapers. Wallpapers play natively through macOS and continue playing after quitting Flua.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Lock Screen") {
                Text(NativeWallpaper.explanation).font(.caption).foregroundStyle(.secondary)
                if NativeWallpaper.available {
                    Button("Remove native provider…", role: .destructive) { ui.confirmingNativeRemoval = true }
                        .disabled(library.nativeSetupBusy)
                        .confirmationDialog("Remove native wallpaper provider?", isPresented: $ui.confirmingNativeRemoval) {
                            Button("Restore wallpapers and remove provider", role: .destructive) { library.removeNativeProvider() }
                        } message: {
                            Text("Restores the saved system wallpapers wherever Flua is still selected, then unregisters this copy of the provider. Your library and wallpapers are kept. Set Wallpaper again to set it up later.")
                        }
                    Text("Removal restores saved system wallpapers and stops native playback. Keep this app and your library in place while Flua is selected.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("About") {
                Text("Flua 1.2 • Independent native wallpaper app").font(.callout)
                Text("Add, preview, edit and set wallpapers, with playlists and per-display playback. Everything in your library remains local.").font(.caption).foregroundStyle(.secondary)
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

struct PlaylistWallpaperPicker: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @StateObject private var ui = ViewState()
    let playlistID: String
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Wallpapers").font(.title2)
            TextField("Search wallpapers", text: $ui.pickerQuery)
            List(library.state.browsing(section: "all", query: ui.pickerQuery)) { wallpaper in
                Toggle(wallpaper.title, isOn: Binding(get: { ui.pickerSelected.contains(wallpaper.id) || library.state.playlist(playlistID)?.items.contains(wallpaper.id) == true }, set: { enabled in
                    if enabled { ui.pickerSelected.insert(wallpaper.id) } else { ui.pickerSelected.remove(wallpaper.id) }
                })).disabled(library.state.playlist(playlistID)?.items.contains(wallpaper.id) == true)
            }
            HStack {
                Button("Add Files…") { library.chooseMedia(playlistID: playlistID); dismiss() }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add Selected") { library.addToPlaylist(ui.pickerSelected, playlistID: playlistID); dismiss() }.disabled(ui.pickerSelected.isEmpty)
            }
        }.padding(24).frame(width: 440, height: 500)
    }
}
