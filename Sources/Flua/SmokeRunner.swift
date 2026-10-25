import AppKit
import ApplicationServices
import AVFoundation
import SwiftUI
import Darwin
import Combine

/// Runs opt-in isolated runtime checks and writes outputs only to their supplied directories.
enum SmokeRunner {
    private static var running = false
    private static var toolbarFrames: [[String: Any]] = []
    @MainActor private static func hasVisibleToolbarBackdrop(_ view: NSView) -> Bool {
        if view.accessibilityRole() == .toolbar { return false }
        let emptyGlass = (view as? NSGlassEffectView).map { $0.contentView == nil } == true
        if (view is NSVisualEffectView || emptyGlass), !view.isHiddenOrHasHiddenAncestor { return true }
        return view.subviews.contains(where: hasVisibleToolbarBackdrop)
    }
    @MainActor private static func hasVisibleToolbarLine(_ view: NSView, in root: NSView, bottom: CGFloat) -> Bool {
        let frame = view.convert(view.bounds, to: root)
        let distance = root.isFlipped ? abs(frame.maxY - bottom) : abs(frame.minY - bottom)
        if !(view is NSControl), view.subviews.isEmpty, frame.width > 1,
           frame.height > 0, frame.height <= 1, distance < 1,
           !view.isHiddenOrHasHiddenAncestor, view.alphaValue > 0 { return true }
        return view.subviews.contains { hasVisibleToolbarLine($0, in: root, bottom: bottom) }
    }
    @MainActor static func observeToolbarWindow(_ window: NSWindow, phase: String) {
        guard ProcessInfo.processInfo.arguments.contains("--fullscreen-chrome"),
              window.frame.height > 0, window.frame.height < 200, window.frame.width >= 700,
              !toolbarFrames.contains(where: { $0["window"] as? Int == window.windowNumber && $0["phase"] as? String == phase }),
              let root = window.contentView else { return }
        let bottom = root.isFlipped ? root.bounds.maxY : root.bounds.minY
        let prepared = !hasVisibleToolbarBackdrop(root) && !hasVisibleToolbarLine(root, in: root, bottom: bottom)
        toolbarFrames.append(["window": window.windowNumber, "phase": phase,
            "parent": window.parent?.identifier?.rawValue ?? "none", "frame": NSStringFromRect(window.frame),
            "prepared": prepared])
    }
    @MainActor static func configureVerificationWindow(_ window: NSWindow, playback: Bool = false) {
        let args = ProcessInfo.processInfo.arguments
        guard ["--smoke-test", "--preview-smoke", "--accessibility-audit"].contains(where: args.contains) else { return }
        if playback {
            window.collectionBehavior = [.primary, .fullScreenNone, .stationary, .ignoresCycle]
            window.hidesOnDeactivate = false
            window.ignoresMouseEvents = true
        } else if !window.ignoresMouseEvents || window.alphaValue > 0.01 {
            park(window)
        }
    }
    /// Keeps verification windows out of sight; accessibility inspection needs minimal opacity.
    @MainActor static func park(_ window: NSWindow) {
        window.alphaValue = ProcessInfo.processInfo.arguments.contains("--accessibility-audit") ? 0.01 : 0
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.stationary, .ignoresCycle]
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    }
    @MainActor static func runAuditIfRequested(library: Library) async {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--accessibility-audit"), args.indices.contains(i + 1) else { return }
        let destination = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        for window in NSApp.windows { park(window); window.orderBack(nil) }
        await pause(0.4)
        for window in NSApp.windows { park(window); window.orderBack(nil) }
        let hosted = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1320, height: 840), styleMask: [.titled], backing: .buffered, defer: false)
        hosted.title = "Flua Library Audit"
        hosted.isReleasedWhenClosed = false
        hosted.contentView = NSHostingView(rootView: LibraryView().environmentObject(library).frame(width: 1320, height: 840).preferredColorScheme(.dark))
        park(hosted)
        hosted.orderBack(nil)
        await pause(0.4)
        var missing = missingNames("Flua Library Audit", [
            "Playback type: All", "Playback type: Animated", "Playback type: Still",
            "Display Mode: Mirrored", "Display Mode: Per Display", "Configure: Lock Screen", "Mirror all displays",
            "Rendering mode: Animated", "Rendering mode: Still", "Mirror Desktop and Lock Screen",
            "Hide Sidebar", "Search", "Category filter", "Color filter", "Motion filter", "Resolution filter", "Aspect filter",
            "Add favorite: Northern lights", "Add favorite: Deep space", "Wallpaper name", "Tags", "Category",
            "Color", "Motion intensity",
            "Speed", "Dim", "Previous in playlist", "Next in playlist", "Stop on selected displays", "Create playlist"
        ])
        let auditTitle = "Flua Library Audit"
        let filterNames = ["Category", "Color", "Motion", "Resolution", "Aspect"]
        for name in filterNames {
            if auditElement(auditTitle, named: name + " filter").map({ ax($0, kAXValueAttribute) }) != "All" {
                missing.append(name + " filter must announce All")
            }
        }
        if let favorite = auditElement(auditTitle, named: "Add favorite: Northern lights") {
            if AXUIElementPerformAction(favorite, kAXPressAction as CFString) != .success {
                missing.append("Favorite accessibility action")
            }
            await pause(0.3)
            missing += missingNames(auditTitle, ["Remove favorite: Northern lights"])
            if library.state.item("aurora")?.favorite != true { missing.append("Favorite action must save its state") }
            if let remove = auditElement(auditTitle, named: "Remove favorite: Northern lights") {
                if AXUIElementPerformAction(remove, kAXPressAction as CFString) != .success {
                    missing.append("Remove favorite accessibility action")
                }
            }
            await pause(0.3)
            missing += missingNames(auditTitle, ["Add favorite: Northern lights"])
            if library.state.item("aurora")?.favorite != false { missing.append("Remove favorite must save its state") }
        } else { missing.append("Favorite accessibility target") }
        if let playlistLibrary = try? Library(root: destination.deletingLastPathComponent().appendingPathComponent("PlaylistControlValidation"), systemPlaybackEnabled: false),
           let key = playlistLibrary.screens.first.map(displayID) {
            // Keep the main audit's accessibility tree attached while testing another library.
            let playlistWindow = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1320, height: 840), styleMask: [.titled], backing: .buffered, defer: false)
            playlistWindow.title = "Flua Playlist Control Audit"
            playlistWindow.isReleasedWhenClosed = false
            playlistWindow.contentView = NSHostingView(rootView: LibraryView().environmentObject(playlistLibrary).frame(width: 1320, height: 840))
            park(playlistWindow)
            playlistWindow.orderBack(nil)
            defer { playlistWindow.close() }
            let auditTitle = playlistWindow.title
            playlistLibrary.tick?.invalidate()
            playlistLibrary.state.displayMode = "perDisplay"
            playlistLibrary.display = key
            playlistLibrary.state.shuffle = false
            playlistLibrary.state.assign("ember", display: key)
            let desktop = playlistLibrary.state.displays[key]?.desktop
            func checkPlaylistControls(_ enabled: Bool, context: String) async {
                await pause(0.3)
                for (name, expected) in [("Previous in playlist", enabled), ("Next in playlist", enabled), ("Stop on selected displays", true)] {
                    guard let button = auditElement(auditTitle, named: name) else {
                        missing.append(context + ": missing " + name)
                        continue
                    }
                    var value: CFTypeRef?
                    if AXUIElementCopyAttributeValue(button, kAXEnabledAttribute as CFString, &value) != .success
                        || (value as? NSNumber)?.boolValue != expected {
                        missing.append(context + ": incorrect availability of " + name)
                    }
                }
            }
            await checkPlaylistControls(false, context: "Single wallpaper")
            captureView(hosted, to: destination.deletingLastPathComponent().appendingPathComponent("Flua-transport-inactive.png"))
            playlistLibrary.surface = .lockScreen
            playlistLibrary.startPlaylist("ambient")
            await checkPlaylistControls(true, context: "Active Lock Screen playlist")
            captureView(hosted, to: destination.deletingLastPathComponent().appendingPathComponent("Flua-transport-active.png"))
            playlistLibrary.togglePlaylistPause()
            await checkPlaylistControls(true, context: "Paused playlist")
            playlistLibrary.togglePlaylistPause()
            playlistLibrary.surface = .desktop
            await checkPlaylistControls(false, context: "Other surface has a playlist")
            playlistLibrary.surface = .lockScreen
            var controlsPassed = playlistLibrary.state.displays[key]?.lockScreen?.wallpaperID == "aurora"
                && playlistLibrary.state.displays[key]?.desktop == desktop
            for (name, expected) in [("Next in playlist", "ocean"), ("Previous in playlist", "aurora")] {
                await pause(0.3)
                if let button = auditElement(auditTitle, named: name) {
                    controlsPassed = AXUIElementPerformAction(button, kAXPressAction as CFString) == .success && controlsPassed
                } else { controlsPassed = false }
                await pause(0.3)
                controlsPassed = controlsPassed && playlistLibrary.state.displays[key]?.lockScreen?.wallpaperID == expected
                    && playlistLibrary.state.displays[key]?.desktop == desktop
            }
            if !controlsPassed { missing.append("Lock Screen playlist Previous/Next preserve Desktop") }
            playlistLibrary.state.nativePlayback[key] = true
            if let stop = auditElement(auditTitle, named: "Stop on selected displays") {
                if AXUIElementPerformAction(stop, kAXPressAction as CFString) != .success {
                    missing.append("Stop accessibility action")
                }
            } else { missing.append("Stop accessibility target") }
            await checkPlaylistControls(false, context: "Stopped playlist with saved assignment")
            if playlistLibrary.state.displays[key]?.lockScreen?.playlistID != "ambient" {
                missing.append("Stop retains the saved playlist")
            }
            playlistLibrary.nativeSetupBusy = true
            await checkPlaylistControls(false, context: "Native setup busy")
            playlistLibrary.nativeSetupBusy = false
            if let error = playlistLibrary.error { missing.append("Lock Screen playlist verification: " + error) }
        } else { missing.append("Lock Screen playlist verification library") }
        let selectedBeforeSettings = library.selection
        let windowsBeforeSettings = NSApp.windows.count
        if let settingsButton = auditElement(auditTitle, named: "Settings") {
            if AXUIElementPerformAction(settingsButton, kAXPressAction as CFString) != .success {
                missing.append("Open internal Settings action")
            }
        } else { missing.append("Settings sidebar button") }
        for (index, delay) in [0.05, 0.1, 0.2].enumerated() {
            await pause(delay)
            captureView(hosted, to: destination.deletingLastPathComponent().appendingPathComponent("Flua-settings-opening-\(index).png"))
        }
        await pause(0.65)
        captureView(hosted, to: destination.deletingLastPathComponent().appendingPathComponent("Flua-settings-navigation.png"))
        missing += missingNames(auditTitle, ["Accent color", "Blocked tags", "Show window on startup"])
        if library.section != "settings" { missing.append("Settings sidebar opens internal page") }
        if NSApp.windows.count > windowsBeforeSettings { missing.append("Settings must not open another window") }
        if auditElement(auditTitle, named: "Set Wallpapers") != nil { missing.append("Settings hides playback controls") }
        if auditElement(auditTitle, named: "Wallpaper name") != nil { missing.append("Settings hides wallpaper inspector") }
        library.navigate(to: "all")
        for (index, delay) in [0.05, 0.1, 0.2].enumerated() {
            await pause(delay)
            captureView(hosted, to: destination.deletingLastPathComponent().appendingPathComponent("Flua-settings-closing-\(index).png"))
        }
        await pause(0.65)
        missing += missingNames(auditTitle, ["Set Wallpapers", "Wallpaper name"])
        if library.selection != selectedBeforeSettings { missing.append("Settings preserves wallpaper selection") }
        library.filter.categories = ["Nature"]
        library.filter.colors = ["Green", "Purple"]
        library.filter.motions = ["Low"]
        library.filter.resolutions = ["4K"]
        library.filter.aspects = ["16:9"]
        await pause(0.3)
        for (name, expected) in zip(filterNames, ["Nature", "Green, Purple", "Low", "4K", "16:9"]) {
            if auditElement(auditTitle, named: name + " filter").map({ ax($0, kAXValueAttribute) }) != expected {
                missing.append(name + " filter must announce " + expected)
            }
        }
        library.clearFilters()
        await pause(0.3)
        let inspectorNames = spokenNames(titled: "Flua Library Audit")
        if inspectorNames.contains(where: { $0.hasPrefix("Filter by ") }) {
            missing.append("Inspector must not show duplicate tag buttons")
        }
        library.query = "no-match"
        library.filterTag("ambient")
        library.blockTags("test")
        await pause(0.4)
        for window in NSApp.windows { park(window); window.orderBack(nil) }
        missing += missingNames("Flua Library Audit", ["Clear search", "Clear filters", "Remove ambient filter"])
        let settings = hosted
        library.section = "settings"
        await pause(0.4)
        missing += missingNames(settings.title, ["Accent color", "Blocked tags", "Block", "Unblock test", "Show in menu bar", "Hide from Dock"])
        let settingsAX = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        var settingsWindowsRef: CFTypeRef?
        AXUIElementCopyAttributeValue(settingsAX, kAXWindowsAttribute as CFString, &settingsWindowsRef)
        let settingsWindow = (settingsWindowsRef as? [AXUIElement])?.first { ax($0, kAXTitleAttribute) == settings.title }
        var startupControlPassed = checkboxValue(settings.title, named: "Show window on startup") == true
        for shown in [false, true] {
            if let settingsWindow, let checkbox = findCheckbox(settingsWindow, "Show window on startup", 0) {
                startupControlPassed = AXUIElementPerformAction(checkbox, kAXPressAction as CFString) == .success && startupControlPassed
            } else {
                startupControlPassed = false
            }
            await pause(0.2)
            startupControlPassed = startupControlPassed && checkboxValue(settings.title, named: "Show window on startup") == shown
                && (try? library.disk.load())?.showWindowOnStartup == shown
        }
        if !startupControlPassed { missing.append("Startup window control saves both states") }
        var powerControlsPassed = true
        for (name, lowPower, lowBattery) in [("Pause in Low Power Mode", false, true),
                                             ("Pause when battery is low", false, false),
                                             ("Pause in Low Power Mode", true, false),
                                             ("Pause when battery is low", true, true)] {
            if let settingsWindow, let checkbox = findCheckbox(settingsWindow, name, 0) {
                powerControlsPassed = AXUIElementPerformAction(checkbox, kAXPressAction as CFString) == .success && powerControlsPassed
            } else {
                powerControlsPassed = false
            }
            await pause(0.2)
            let saved = try? library.disk.load()
            powerControlsPassed = powerControlsPassed && saved?.pauseOnLowPower == lowPower && saved?.pauseOnLowBattery == lowBattery
            powerControlsPassed = powerControlsPassed && checkboxValue(settings.title, named: "Pause in Low Power Mode") == lowPower
                && checkboxValue(settings.title, named: "Pause when battery is low") == lowBattery
            captureView(settings, to: destination.deletingLastPathComponent().appendingPathComponent("Flua-settings-power-\(lowPower)-\(lowBattery).png"))
        }
        if !powerControlsPassed { missing.append("Independent Low Power Mode and low battery controls") }
        let menuShown = checkboxValue(settings.title, named: "Show in menu bar") == true
        let dockHidden = checkboxValue(settings.title, named: "Hide from Dock") == false
        let dockEnabled = checkboxEnabled(settings.title, named: "Hide from Dock") == true
        if !menuShown || !dockHidden || !dockEnabled { missing.append("Hide from Dock while menu bar is shown") }
        library.state.setShowsMenuBar(false)
        await pause(0.3)
        let dockStaysOff = checkboxValue(settings.title, named: "Hide from Dock") == false
        let dockDisabled = checkboxEnabled(settings.title, named: "Hide from Dock") == false
        if !dockStaysOff || !dockDisabled { missing.append("Hide from Dock while menu bar is hidden") }
        library.state.setShowsMenuBar(true)
        let report: [String: Any] = ["passed": missing.isEmpty, "missing": missing]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: destination)
        }
        exit(missing.isEmpty ? 0 : 1)
    }
    @MainActor static func runPreviewSmokeIfRequested() async {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--preview-smoke"), args.indices.contains(i + 1) else { return }
        if args.contains("--scroll-benchmark") {
            await runScrollBenchmark(destination: URL(fileURLWithPath: args[i + 1]))
            return
        }
        let destination = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var frameRates: [String: Double] = [:]
        var cpuUsage: [String: Double] = [:]
        var visibility: [String: String] = [:]
        for kind in AmbientSceneView.scenes.map(\.id) {
            let window = NSPanel(contentRect: NSRect(x: 120, y: 120, width: 640, height: 392), styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
            window.title = "Flua Scene Preview Benchmark — " + kind
            window.isReleasedWhenClosed = false
            configureVerificationWindow(window, playback: true)
            window.animationBehavior = .none
            let preview = AmbientSceneView(frame: NSRect(origin: .zero, size: NSSize(width: 640, height: 392)), scene: kind)
            window.contentView = preview
            window.orderBack(nil)
            await waitUntilVisible(window)
            visibility[kind] = "occlusion=\(window.occlusionState.rawValue) hidden=\(preview.isHiddenOrHasHiddenAncestor) rect=\(preview.visibleRect)"
            await pause(0.2)
            let initialFrames = preview.frameCount
            let cpuStart = processCPUTime()
            let start = CACurrentMediaTime()
            await pause(0.6)
            let duration = CACurrentMediaTime() - start
            frameRates[kind] = Double(preview.frameCount - initialFrames) / duration
            cpuUsage[kind] = (processCPUTime() - cpuStart) / duration * 100
            preview.isPaused = true
            window.close()
            await pause(0.1)
        }
        let report: [String: Any] = [
            "passed": frameRates.values.allSatisfy { $0 > 0 },
            "framesPerSecond": frameRates,
            "cpuPercentOfOneCore": cpuUsage,
            "visibility": visibility
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: destination)
            print(String(decoding: data, as: UTF8.self))
        }
        exit(frameRates.values.allSatisfy { $0 > 0 } ? 0 : 1)
    }
    @MainActor private static func runScrollBenchmark(destination: URL) async {
        let library = AppContext.library
        library.tick?.invalidate()
        await pause(0.2)
        for original in library.state.wallpapers {
            var copy = original
            copy.id += "-scroll-fixture"
            copy.title += " copy"
            library.state.wallpapers.append(copy)
            library.thumbnails[copy.id] = library.thumbnails[original.id]
        }
        let window = NSPanel(contentRect: NSRect(x: 10, y: 20, width: 1440, height: 900),
            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "Flua Scroll Benchmark"
        window.isReleasedWhenClosed = false
        let root = NSHostingView(rootView: LibraryView().environmentObject(library))
        window.contentView = root
        await pause(1)
        window.alphaValue = 1
        window.ignoresMouseEvents = true
        window.setFrameOrigin(NSPoint(x: 10, y: 20))
        window.level = .floating
        window.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        window.orderFrontRegardless()
        let ready = destination.appendingPathExtension("ready")
        let start = destination.appendingPathExtension("start")
        try? Data(String(window.windowNumber).utf8).write(to: ready)
        let deadline = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: start.path), Date() < deadline { await pause(0.05) }
        guard FileManager.default.fileExists(atPath: start.path) else { window.close(); exit(1) }
        var scrolls: [NSScrollView] = []
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView, scroll.hasVerticalScroller, scroll.bounds.width > 260 {
                scrolls.append(scroll)
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        var phases: [[Double]] = []
        for scroll in scrolls {
            let began = CACurrentMediaTime()
            for step in 0..<360 {
                let clip = scroll.contentView
                let maximum = max(0, (scroll.documentView?.bounds.height ?? 0) - clip.bounds.height)
                let phase = Double(step % 120) / 119
                clip.scroll(to: NSPoint(x: 0, y: maximum * (1 - cos(phase * 2 * .pi)) / 2))
                scroll.reflectScrolledClipView(clip)
                await pause(1.0 / 60)
            }
            phases.append([began, CACurrentMediaTime()])
        }
        if let data = try? JSONSerialization.data(withJSONObject: phases) { try? data.write(to: destination) }
        window.close()
        exit(phases.count == 2 ? 0 : 1)
    }
    private static func checkboxValue(_ title: String, named name: String) -> Bool? {
        checkboxAttribute(title, named: name, kAXValueAttribute)
    }
    private static func checkboxEnabled(_ title: String, named name: String) -> Bool? {
        checkboxAttribute(title, named: name, kAXEnabledAttribute)
    }
    private static func checkboxAttribute(_ title: String, named name: String, _ attribute: String) -> Bool? {
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              let window = windows.first(where: { ax($0, kAXTitleAttribute) == title }),
              let box = findCheckbox(window, name, 0) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(box, attribute as CFString, &value) == .success else { return nil }
        if let enabled = value as? Bool { return enabled }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }
    private static func findCheckbox(_ element: AXUIElement, _ name: String, _ depth: Int) -> AXUIElement? {
        if depth > 16 { return nil }
        if ["AXCheckBox", "AXSwitch"].contains(ax(element, kAXRoleAttribute)) {
            let label = ax(element, kAXDescriptionAttribute) + " " + ax(element, kAXTitleAttribute) + " " + ax(element, kAXTitleUIElementAttribute)
            if label.contains(name) { return element }
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }
        for child in children {
            if let found = findCheckbox(child, name, depth + 1) { return found }
        }
        return nil
    }
    private static func auditElement(_ title: String, named name: String) -> AXUIElement? {
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              let window = windows.first(where: { ax($0, kAXTitleAttribute) == title }) else { return nil }
        func find(_ element: AXUIElement, _ depth: Int) -> AXUIElement? {
            guard depth <= 16 else { return nil }
            if ax(element, kAXDescriptionAttribute) == name || ax(element, kAXTitleAttribute) == name { return element }
            var childrenRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                  let children = childrenRef as? [AXUIElement] else { return nil }
            for child in children {
                if let match = find(child, depth + 1) { return match }
            }
            return nil
        }
        return find(window, 0)
    }
    private static func missingNames(_ title: String, _ required: [String]) -> [String] {
        let names = spokenNames(titled: title)
        return required.filter { !names.contains($0) }
    }
    private static func spokenNames(titled title: String) -> Set<String> {
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              let window = windows.first(where: { ax($0, kAXTitleAttribute) == title }) else { return [] }
        var names: Set<String> = []
        let roles: Set<String> = ["AXButton", "AXTextField", "AXTextArea", "AXPopUpButton", "AXMenuButton", "AXCheckBox", "AXRadioButton", "AXSlider", "AXComboBox"]
        func add(_ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { names.insert(trimmed) }
        }
        func visit(_ element: AXUIElement, _ depth: Int) {
            if depth > 16 { return }
            if roles.contains(ax(element, kAXRoleAttribute)) {
                add(ax(element, kAXDescriptionAttribute))
                add(ax(element, kAXTitleAttribute))
                add(ax(element, kAXHelpAttribute))
                add(ax(element, kAXTitleUIElementAttribute))
            }
            var childrenRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                  let children = childrenRef as? [AXUIElement] else { return }
            for child in children { visit(child, depth + 1) }
        }
        visit(window, 0)
        return names
    }
    private static func ax(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { return "" }
        if attribute == kAXTitleUIElementAttribute, CFGetTypeID(value as CFTypeRef) == AXUIElementGetTypeID() {
            let named = Unmanaged<AXUIElement>.fromOpaque(Unmanaged.passUnretained(value as AnyObject).toOpaque()).takeUnretainedValue()
            return ax(named, kAXValueAttribute) + " " + ax(named, kAXTitleAttribute) + " " + ax(named, kAXDescriptionAttribute)
        }
        let text = "\(value)".replacingOccurrences(of: "\n", with: " ")
        return text.count > 140 ? String(text.prefix(140)) : text
    }
    @MainActor private static func windowControlsVisible(_ window: NSWindow) -> Bool {
        [.closeButton, .miniaturizeButton, .zoomButton].allSatisfy { (kind: NSWindow.ButtonType) in
            guard let button = window.standardWindowButton(kind), button.window === window,
                  !button.isHiddenOrHasHiddenAncestor, !button.visibleRect.isEmpty else { return false }
            var ancestor: NSView? = button
            while let view = ancestor {
                if view.alphaValue <= 0.01 { return false }
                ancestor = view.superview
            }
            return true
        }
    }
    @MainActor static func runIfRequested(library: Library) async {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--startup-smoke"), args.indices.contains(i + 1), args.contains("--data-dir") {
            await pause(1)
            let window = NSApp.windows.first { $0.identifier?.rawValue == "library" }
            if args.contains("--fullscreen-chrome"), let window {
                let appearance = NSAppearance(named: args.contains("--fullscreen-light") ? .aqua : .darkAqua)
                NSApp.appearance = appearance
                window.appearance = appearance
                window.contentView?.appearance = appearance
                await pause(0.3)
                window.collectionBehavior.insert(.moveToActiveSpace)
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                await pause(0.3)
                if window.styleMask.contains(.fullScreen) {
                    window.toggleFullScreen(nil)
                    let deadline = Date().addingTimeInterval(5)
                    while Date() < deadline && (window.styleMask.contains(.fullScreen) || !windowControlsVisible(window)) {
                        await pause(0.1)
                    }
                }
            }
            let visible = window?.isVisible == true
            let fullScreenPrimary = window?.collectionBehavior.contains(.fullScreenPrimary) == true
            let fullScreenNone = window?.collectionBehavior.contains(.fullScreenNone) == true
            let fullScreenEligible = fullScreenPrimary && !fullScreenNone
            let controlsVisible = visible && window.map(windowControlsVisible) == true
            var passed = visible == library.state.showWindowOnStartup
                && (!visible || (fullScreenEligible && controlsVisible))
            var report: [String: Any] = [
                "passed": passed,
                "windowVisible": visible,
                "showWindowOnStartup": library.state.showWindowOnStartup,
                "hidesDockIcon": library.state.hidesDockIcon,
                "activationPolicy": NSApp.activationPolicy().rawValue,
                "fullScreenPrimary": fullScreenPrimary,
                "fullScreenNone": fullScreenNone,
                "fullScreenEligible": fullScreenEligible,
                "windowControlsVisible": controlsVisible
            ]
            if args.contains("--fullscreen-chrome"), let window, visible {
                // This opt-in check changes Spaces; ordinary smoke stays in the background.
                var enteredNotification = false
                var exitedNotification = false
                var transitionPrepared = false
                var transitionSamples = 0
                var transitionLineHidden = true
                let willEnterObserver = NotificationCenter.default.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { _ in
                    transitionPrepared = window.titlebarSeparatorStyle == .none
                }
                let enterObserver = NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { _ in enteredNotification = true }
                let exitObserver = NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { _ in exitedNotification = true }
                func checkTransitionLines() {
                    func check(_ root: NSView, bottom: CGFloat) {
                        transitionSamples += 1
                        transitionLineHidden = transitionLineHidden && !hasVisibleToolbarLine(root, in: root, bottom: bottom)
                    }
                    if let root = window.contentView?.superview {
                        check(root, bottom: root.convert(NSPoint(x: 0, y: window.contentLayoutRect.maxY), from: nil).y)
                    }
                    for chrome in window.childWindows ?? [] where !chrome.isSheet && chrome.frame.height < window.frame.height {
                        guard let root = chrome.contentView else { continue }
                        check(root, bottom: root.isFlipped ? root.bounds.maxY : root.bounds.minY)
                    }
                }
                defer {
                    NotificationCenter.default.removeObserver(willEnterObserver)
                    NotificationCenter.default.removeObserver(enterObserver)
                    NotificationCenter.default.removeObserver(exitObserver)
                }
                window.toggleFullScreen(nil)
                var deadline = Date().addingTimeInterval(5)
                while Date() < deadline && !enteredNotification {
                    checkTransitionLines()
                    await pause(0.1)
                }
                await pause(0.3)
                let entered = enteredNotification && window.styleMask.contains(.fullScreen)
                let chromeWindows = (window.childWindows ?? []).filter { !$0.isSheet }
                let backdropsHidden = !chromeWindows.isEmpty && chromeWindows.allSatisfy {
                    $0.contentView.map { !hasVisibleToolbarBackdrop($0) } == true
                }
                let separatorHidden = window.titlebarSeparatorStyle == .none
                    && !chromeWindows.isEmpty && chromeWindows.allSatisfy { $0.titlebarSeparatorStyle == .none }
                let toolbarVisible = window.toolbar?.isVisible == true
                let onActiveSpace = window.isOnActiveSpace
                let firstFrames = toolbarFrames.filter { $0["phase"] as? String == "draw" }
                let firstDrawPrepared = !firstFrames.isEmpty && firstFrames.allSatisfy { $0["prepared"] as? Bool == true }
                report["fullscreenEntered"] = entered
                report["fullscreenTransitionPrepared"] = transitionPrepared
                report["fullscreenTransitionSamples"] = transitionSamples
                report["fullscreenTransitionLineHidden"] = transitionLineHidden && transitionSamples > 0
                report["fullscreenBackdropsHidden"] = backdropsHidden
                report["fullscreenToolbarFrames"] = toolbarFrames
                report["fullscreenToolbarFirstDrawPrepared"] = firstDrawPrepared
                report["fullscreenSeparatorHidden"] = separatorHidden
                report["fullscreenToolbarVisible"] = toolbarVisible
                report["fullscreenWindowOnActiveSpace"] = onActiveSpace
                report["fullscreenAppActive"] = NSApp.isActive
                let snapshot = URL(fileURLWithPath: args[i + 1]).deletingPathExtension().appendingPathExtension("png")
                captureView(window, to: snapshot)
                var backgroundMatches = false
                var sidebarLineHidden = false
                if let chrome = chromeWindows.first {
                    let toolbarSnapshot = snapshot.deletingPathExtension().appendingPathExtension("toolbar.png")
                    captureView(chrome, to: toolbarSnapshot)
                    if let headerData = try? Data(contentsOf: toolbarSnapshot), let contentData = try? Data(contentsOf: snapshot),
                       let header = NSBitmapImageRep(data: headerData), let content = NSBitmapImageRep(data: contentData) {
                        func colorsMatch(_ first: NSColor?, _ second: NSColor?) -> Bool {
                            guard let a = first?.usingColorSpace(.sRGB), let b = second?.usingColorSpace(.sRGB) else { return false }
                            return abs(a.redComponent - b.redComponent) <= 2.0 / 255
                                && abs(a.greenComponent - b.greenComponent) <= 2.0 / 255
                                && abs(a.blueComponent - b.blueComponent) <= 2.0 / 255
                        }
                        let scale = CGFloat(header.pixelsWide) / chrome.frame.width
                        let contentScale = CGFloat(content.pixelsWide) / window.frame.width
                        backgroundMatches = [CGFloat(15), chrome.frame.width / 2, chrome.frame.width - 20].allSatisfy { x in
                            colorsMatch(header.colorAt(x: Int(x * scale), y: Int(10 * scale)),
                                content.colorAt(x: Int(x * contentScale), y: Int(10 * contentScale)))
                        }
                        let toolbarBottom = min(header.pixelsHigh, Int(chrome.frame.height * scale)) - 1
                        sidebarLineHidden = colorsMatch(header.colorAt(x: Int(15 * scale), y: toolbarBottom),
                            header.colorAt(x: Int(15 * scale), y: toolbarBottom - 3))
                    }
                }
                report["fullscreenBackgroundMatches"] = backgroundMatches
                report["fullscreenSidebarLineHidden"] = sidebarLineHidden
                if entered { window.toggleFullScreen(nil) }
                deadline = Date().addingTimeInterval(5)
                while Date() < deadline && (!exitedNotification || window.styleMask.contains(.fullScreen) || window.titlebarSeparatorStyle != .automatic || !windowControlsVisible(window)) {
                    await pause(0.1)
                }
                let restored = !window.styleMask.contains(.fullScreen)
                    && window.titlebarSeparatorStyle == .automatic && windowControlsVisible(window)
                report["windowedChromeRestored"] = restored
                report["stillFullscreen"] = window.styleMask.contains(.fullScreen)
                report["windowedSeparator"] = window.titlebarSeparatorStyle.rawValue
                passed = passed && entered && transitionPrepared && transitionLineHidden && transitionSamples > 0
                    && firstDrawPrepared && backdropsHidden && separatorHidden && toolbarVisible && restored && onActiveSpace
                    && backgroundMatches && sidebarLineHidden
                report["passed"] = passed
                if !args.contains("--fullscreen-observe") { window.close() }
            } else if args.contains("--fullscreen-chrome") {
                passed = false
                report["passed"] = false
            }
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: args[i + 1]))
            }
            if passed && args.contains("--fullscreen-chrome") && args.contains("--fullscreen-observe") { return }
            exit(passed ? 0 : 1)
        }
        guard !running, let i = args.firstIndex(of: "--smoke-test"), args.indices.contains(i + 1) else { return }
        running = true
        let out = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        var results: [String: Any] = [:]
        var failures: [String] = []
        results["systemPlayback"] = "Not exercised: saved assignments and provider descriptors are validated without OS integration."
        results["backgroundLaunch"] = !NSApp.isActive
        let activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            failures.append("Smoke verification activated Flua")
        }
        defer { NotificationCenter.default.removeObserver(activationObserver) }
        let errorObservation = library.$error.compactMap { $0 }.sink { failures.append("Unexpected library error: " + $0) }
        defer { errorObservation.cancel() }
        let originalWallpapers = library.screens.map { NSWorkspace.shared.desktopImageURL(for: $0) }
        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let validation = try Library(root: out.appendingPathComponent("NativeValidation"), systemPlaybackEnabled: false)
            validation.tick?.invalidate()
            validation.applySelected()
            results["nativeDescriptorValidation"] = validation.error == nil && !validation.nativeSetupBusy
                && validation.activity == "Validated saved wallpaper choices. System playback is disabled for verification."
                && validation.state.nativePlayback.isEmpty
            if let selectedID = validation.selected?.id {
                validation.state.wallpapers.removeAll { $0.id == selectedID }
                validation.applySavedNativeAssignments()
                results["nativeDescriptorValidationRejectsMissing"] = validation.error?.contains("unavailable or blocked") == true
            }
            let mismatch = try Library(root: out.appendingPathComponent("NativeMismatch"))
            mismatch.tick?.invalidate()
            if NativeWallpaper.available, NativeWallpaper.catalogURL.resolvingSymlinksInPath() != mismatch.disk.catalog.resolvingSymlinksInPath() {
                mismatch.applySelected()
                results["nativeCatalogMismatchRejected"] = mismatch.error?.contains("This build uses a different library") == true
                    && !mismatch.nativeSetupBusy && mismatch.state.nativePlayback.isEmpty
            }
            await pause(1)
            if let window = NSApp.windows.first(where: { $0.title == "Flua" }) {
                window.setContentSize(NSSize(width: 1320, height: 840))
                park(window)
            }
            await pause(0.3)
            if let screen = library.screens.first {
                let key = displayID(screen)
                let original = library.state
                for mode in ["mirrored", "perDisplay"] {
                    var idle = original
                    idle.displayMode = mode
                    idle.interval = 300
                    if let playlist = idle.playlists.first {
                        idle.playlists[0].interval = 300
                        idle.assign("aurora", display: key, playlistID: playlist.id)
                    }
                    library.state = idle
                    library.applySavedNativeAssignments()
                    var publications = 0
                    let observation = library.$state.dropFirst().sink { _ in publications += 1 }
                    library.advancePlaylists(force: false)
                    observation.cancel()
                    results["idlePlaylistDoesNotPublish_" + mode] = publications == 0
                    if publications != 0 { failures.append("idlePlaylistDoesNotPublish_" + mode) }
                }
                library.state = original
                // A missing saved choice catches launch-time Apply before any system mutation.
                let launchDisk = library.disk
                let beforeLaunch = try launchDisk.load()
                var launchState = LibraryState.initial
                launchState.displayMode = "perDisplay"
                launchState.assign("aurora", display: key)
                launchState.wallpapers.removeAll { $0.id == "aurora" }
                launchState.nativePlayback[key] = true
                try launchDisk.save(launchState)
                let launched = try Library(root: launchDisk.root)
                launched.tick?.invalidate()
                await pause(0.2)
                results["launchDoesNotApplySavedWallpaper"] = NativeWallpaper.available
                    && NativeWallpaper.catalogURL.resolvingSymlinksInPath() == launchDisk.catalog.resolvingSymlinksInPath()
                    && launched.error == nil
                    && !launched.nativeSetupBusy
                    && launched.state.nativePlayback[key] == true
                    && launched.state.displays[key]?.desktop.wallpaperID == "aurora"
                try launchDisk.save(beforeLaunch)
                if results["launchDoesNotApplySavedWallpaper"] as? Bool != true {
                    failures.append("launchDoesNotApplySavedWallpaper")
                }
                let root = out.appendingPathComponent("LaunchRestoration", isDirectory: true)
                let disk = try LibraryDisk(root: root)
                var saved = LibraryState.initial
                saved.displayMode = "perDisplay"
                saved.assign("aurora", display: key)
                saved.nativePlayback[key] = false
                try disk.save(saved)
                let stopped = try Library(root: root)
                await pause(0.2)
                results["nativeStoppedSurvivesLaunch"] = stopped.state.nativePlayback[key] == false
                    && stopped.state.displays[key]?.desktop.wallpaperID == "aurora"
                stopped.tick?.invalidate()
                saved.nativePlayback[key] = true
                try disk.save(saved)
                let fallback = try Library(root: root)
                await pause(0.2)
                results["nativeUnavailableLaunchFallback"] = fallback.state.nativePlayback[key] == true
                fallback.stop()
                let stoppedFallback = try disk.load()
                results["nativeFallbackStopPersists"] = fallback.state.nativePlayback[key] == false
                    && fallback.state.displays[key]?.desktop.wallpaperID == "aurora"
                    && stoppedFallback.nativePlayback[key] == false
                fallback.tick?.invalidate()
                for check in ["nativeStoppedSurvivesLaunch", "nativeUnavailableLaunchFallback", "nativeFallbackStopPersists"] {
                    if results[check] as? Bool != true { failures.append(check) }
                }
            }
            results["libraryVisibleOnLaunch"] = NSApp.windows.contains { $0.title == "Flua" && $0.isVisible }
            if results["libraryVisibleOnLaunch"] as? Bool != true { failures.append("libraryVisibleOnLaunch") }
            if let window = NSApp.windows.first(where: { $0.title == "Flua" }) {
                results["libraryWindowChrome"] = window.titleVisibility == .hidden
                    && windowControlsVisible(window)
            }
            if results["libraryWindowChrome"] as? Bool != true { failures.append("libraryWindowChrome") }
            results["discoverSystemScrollers"] = verifySystemScrollers()
            if results["discoverSystemScrollers"] as? Bool != true { failures.append("discoverSystemScrollers") }
            results["inspectorSceneInteraction"] = await verifyInspectorInteraction(library: library)
            library.stop()
            let image = AmbientSceneView.thumbnail(scene: "ocean", size: NSSize(width: 640, height: 360))
            let imageURL = out.appendingPathComponent("sample.png")
            try png(image).write(to: imageURL)
            let videoURL = out.appendingPathComponent("sample.mov")
            try await Task.detached { try await makeVideo(videoURL) }.value
            let importPlaylist = library.state.playlists[0]
            library.section = "playlist:" + importPlaylist.id
            library.query = "no match"
            library.filter.source = "builtin"
            library.importMedia([imageURL, videoURL])
            let deadline = Date().addingTimeInterval(20)
            while library.importing && Date() < deadline { await pause(0.1) }
            results["importRevealsAdded"] = library.section == "all" && library.query.isEmpty && library.filter.activeCount == 0
                && library.selected?.file != nil && library.visible.contains { $0.id == library.selection }
                && library.state.playlist(importPlaylist.id)?.items == importPlaylist.items && library.importNotice != nil
            await pause(0.3)
            if let window = NSApp.windows.first(where: { $0.title == "Flua" }) {
                captureView(window, to: out.appendingPathComponent("Flua-added.png"))
            }
            let videos = library.state.wallpapers.filter { $0.kind == "video" }
            let images = library.state.wallpapers.filter { $0.kind == "image" }
            results["imageImport"] = images.count == 1
            results["videoImport"] = videos.count == 1
            if videos.count != 1 || images.count != 1 { throw LibraryError.unreadableMedia("smoke fixtures") }
            let testWindow = NSPanel(contentRect: NSRect(x: 20, y: 20, width: 192, height: 108), styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
            testWindow.isReleasedWhenClosed = false
            testWindow.title = "Flua playback verification"
            configureVerificationWindow(testWindow, playback: true)
            testWindow.level = .normal
            testWindow.hidesOnDeactivate = false
            testWindow.ignoresMouseEvents = true
            let surface = MediaSurface(frame: NSRect(x: 0, y: 0, width: 192, height: 108))
            testWindow.contentView = surface
            defer { surface.cleanup(); testWindow.close() }
            surface.onError = { failures.append($0) }
            let video = videos[0]
            let copiedBytes = (try FileManager.default.attributesOfItem(atPath: library.disk.url(for: video)!.path)[.size] as? NSNumber)?.int64Value
            results["importFacts"] = video.mediaFacts?.width == 640 && video.mediaFacts?.height == 360
                && abs((video.mediaFacts?.sourceDuration ?? 0) - 1) < 0.05
                && video.mediaFacts?.bytes == copiedBytes
                && video.dateAdded != nil && video.color != "Unknown"
                && images[0].mediaFacts?.width == 640 && images[0].mediaFacts?.height == 360
                && images[0].mediaFacts?.sourceDuration == nil && images[0].dateAdded != nil
            let rotatedURL = out.appendingPathComponent("rotated.mov")
            try await Task.detached { try await makeVideo(rotatedURL, transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 360, ty: 0)) }.value
            let rotated = await MediaInspection.load(url: rotatedURL, kind: "video")
            results["rotatedFacts"] = rotated.facts.width == 360 && rotated.facts.height == 640 && rotated.facts.aspect == "Portrait"
            let missing = await MediaInspection.load(url: out.appendingPathComponent("missing.mp4"), kind: "video")
            results["missingFacts"] = missing.facts.bytes == nil && !missing.facts.hasDimensions && missing.facts.sourceDuration == nil && missing.color == nil
            let legacyRoot = out.appendingPathComponent("legacy-library", isDirectory: true)
            let legacyDisk = try LibraryDisk(root: legacyRoot)
            try FileManager.default.copyItem(at: imageURL, to: legacyDisk.assets.appendingPathComponent("old.png"))
            var legacyState = LibraryState.initial
            legacyState.wallpapers.append(Wallpaper(id: "legacy-image", title: "Legacy", kind: "image", file: "old.png"))
            legacyState.wallpapers.append(Wallpaper(id: "legacy-missing", title: "Missing", kind: "video", file: "missing.mov"))
            try legacyDisk.save(legacyState)
            let legacyLibrary = try Library(root: legacyRoot)
            let backfillDeadline = Date().addingTimeInterval(10)
            while legacyLibrary.state.item("legacy-image")?.mediaFacts == nil && Date() < backfillDeadline { await pause(0.1) }
            results["legacyBackfill"] = legacyLibrary.state.item("legacy-image")?.mediaFacts?.width == 640
                && legacyLibrary.state.item("legacy-image")?.dateAdded == nil
                && legacyLibrary.state.item("legacy-image")?.color != "Unknown"
            let backfilledColor = legacyLibrary.state.item("legacy-image")?.color
            var staleDraft = legacyState.item("legacy-image")!
            staleDraft.metadata = SceneMetadata(details: "Edited before backfill finished")
            legacyLibrary.edit(staleDraft)
            results["staleEditPreservesFacts"] = legacyLibrary.state.item("legacy-image")?.mediaFacts?.width == 640
                && legacyLibrary.state.item("legacy-image")?.dateAdded == nil
                && legacyLibrary.state.item("legacy-image")?.color == backfilledColor
                && legacyLibrary.state.item("legacy-image")?.metadata?.details == staleDraft.metadata?.details
            var unknownColor = legacyLibrary.state.item("legacy-image")!
            unknownColor.metadata?.color = "Unknown"
            unknownColor.mediaFacts = nil
            legacyLibrary.state.wallpapers[legacyLibrary.state.wallpapers.firstIndex(where: { $0.id == unknownColor.id })!] = unknownColor
            legacyLibrary.backfillMetadata()
            let unknownBackfillDeadline = Date().addingTimeInterval(10)
            while legacyLibrary.state.item(unknownColor.id)?.mediaFacts == nil && Date() < unknownBackfillDeadline { await pause(0.1) }
            results["unknownColorBackfill"] = legacyLibrary.state.item(unknownColor.id)?.mediaFacts?.width == 640
                && legacyLibrary.state.item(unknownColor.id)?.color == "Unknown"
            legacyLibrary.tick?.invalidate()
            surface.configure(video, url: library.disk.url(for: video))
            testWindow.orderBack(nil)
            results["videoPreviewWindowVisible"] = await waitUntilVisible(testWindow)
            await pause(0.8)
            results["videoReady"] = surface.mediaReady
            results["previewWindowOcclusion"] = testWindow.occlusionState.rawValue
            results["previewWindowOnActiveSpace"] = testWindow.isOnActiveSpace
            results["previewAppActive"] = NSApp.isActive
            results["previewVisibleRect"] = NSStringFromRect(surface.visibleRect)
            results["videoPlaying"] = surface.playbackRate > 0
            var times: [Double] = []
            var visibility: [String] = []
            for _ in 0..<16 {
                await pause(0.15)
                times.append(surface.playbackTime)
                visibility.append("\(testWindow.occlusionState.rawValue) hidden=\(surface.isHiddenOrHasHiddenAncestor) rect=\(surface.visibleRect)")
            }
            results["videoVisibility"] = visibility
            results["videoTimes"] = times
            results["videoLooped"] = zip(times, times.dropFirst()).contains { $1 < $0 - 0.2 }
            surface.setPaused(true)
            let pausedTime = surface.playbackTime
            await pause(0.5)
            results["videoPaused"] = abs(surface.playbackTime - pausedTime) < 0.08 && surface.playbackRate == 0
            surface.setPaused(false)
            let resumeDeadline = Date().addingTimeInterval(2)
            while surface.playbackRate == 0 && Date() < resumeDeadline { await pause(0.05) }
            results["videoResumed"] = surface.playbackRate > 0
            surface.isHidden = true
            await pause(0.2)
            let hiddenVideoTime = surface.playbackTime
            await pause(0.2)
            results["hiddenVideoPreviewPaused"] = surface.playbackRate == 0 && abs(surface.playbackTime - hiddenVideoTime) < 0.08
            surface.isHidden = false
            await pause(0.3)
            results["hiddenVideoPreviewResumed"] = surface.playbackRate > 0
            for check in ["hiddenVideoPreviewPaused", "hiddenVideoPreviewResumed"] {
                if results[check] as? Bool != true { failures.append(check) }
            }
            surface.setPaused(true)
            let beforeAdjustment = surface.playbackTime
            var adjusted = video
            adjusted.speed = 1.5
            adjusted.dimming = 0.3
            surface.updateParameters(adjusted)
            results["liveAdjustmentPreservesTime"] = abs(surface.playbackTime - beforeAdjustment) < 0.03
            surface.setPaused(false)
            await pause(0.1)
            results["liveAdjustmentSpeed"] = abs(surface.playbackRate - 1.5) < 0.01
            capture(testWindow, to: out.appendingPathComponent("Flua-video-playback.png"))
            let information = try await VideoInformation.load(videoURL)
            results["videoInformation"] = information.width == 640 && information.height == 360 && abs(information.duration - 1) < 0.05
            var edited = video
            edited.videoEdit = VideoEdit(start: 0.25, end: 0.75, thumbnail: 0.5, quality: "medium")
            edited.metadata = SceneMetadata(details: "Portable test scene", category: "Abstract", creditTitle: "Flua", creditURL: "", color: "Purple", motion: "High")
            edited.tags = "test, portable"
            surface.configure(edited, url: library.disk.url(for: edited))
            await pause(0.4)
            var trimmedTimes: [Double] = []
            for _ in 0..<12 { await pause(0.1); trimmedTimes.append(surface.playbackTime) }
            results["trimmedTimes"] = trimmedTimes
            results["trimmedPlayback"] = trimmedTimes.allSatisfy { $0 >= 0.24 && $0 <= 0.77 } && zip(trimmedTimes, trimmedTimes.dropFirst()).contains { $1 < $0 - 0.1 }
            testWindow.orderBack(nil)
            results["scenePreviewWindowVisible"] = await waitUntilVisible(testWindow)
            for kind in ["image", "aurora", "cosmos", "ocean", "ember"] {
                let w = kind == "image" ? images[0] : library.state.wallpapers.first { $0.kind == kind }!
                surface.configure(w, url: library.disk.url(for: w))
                await pause(0.15)
                results["render_" + kind] = surface.subviews.count > 0 || (surface.layer?.sublayers?.count ?? 0) > 0
            }
            weak let releasedScene = surface.subviews.compactMap { $0 as? AmbientSceneView }.first
            if let scene = releasedScene {
                let frames = scene.frameCount
                let start = CACurrentMediaTime()
                let cpuStart = processCPUTime()
                await pause(0.6)
                results["scenePreviewFPS"] = Double(scene.frameCount - frames) / (CACurrentMediaTime() - start)
                results["scenePreviewCPUPercent"] = (processCPUTime() - cpuStart) / (CACurrentMediaTime() - start) * 100
                results["scenePreviewVisibility"] = "\(testWindow.occlusionState.rawValue) hidden=\(scene.isHiddenOrHasHiddenAncestor) rect=\(surface.visibleRect)"
                results["scenePreviewAnimated"] = scene.frameCount > frames + 2
                surface.setPaused(true)
                await pause(0.1)
                let paused = scene.frameCount
                await pause(0.2)
                results["scenePreviewPaused"] = scene.frameCount == paused
                surface.setPaused(false)
                scene.isHidden = true
                await pause(0.1)
                let hidden = scene.frameCount
                await pause(0.2)
                results["scenePreviewHidden"] = scene.frameCount == hidden
                scene.isHidden = false
                await pause(0.2)
                results["scenePreviewResumed"] = scene.frameCount > hidden
                testWindow.orderOut(nil)
                await pause(0.2)
                let occluded = scene.frameCount
                await pause(0.2)
                results["scenePreviewWindowHidden"] = scene.frameCount == occluded
                testWindow.orderBack(nil)
                results["scenePreviewReshownWindowVisible"] = await waitUntilVisible(testWindow)
                await pause(0.3)
                results["scenePreviewWindowResumed"] = scene.frameCount > occluded
            }
            surface.cleanup()
            await pause(0.1)
            results["scenePreviewReleased"] = releasedScene == nil
            for check in ["scenePreviewAnimated", "scenePreviewPaused", "scenePreviewHidden", "scenePreviewResumed", "scenePreviewReleased", "scenePreviewWindowHidden", "scenePreviewWindowResumed"] {
                if results[check] as? Bool != true { failures.append(check) }
            }
            let previousSelection = library.selection
            let previousSurface = library.surface
            let previousLinked = library.surfacesLinked
            library.surface = .desktop
            let previousDesktopMode = library.surfaceMode ?? .animated
            library.surface = .lockScreen
            let previousLockScreenMode = library.surfaceMode ?? .animated
            library.surface = previousSurface
            if previousLinked { library.setSurfacesLinked(false) }
            testWindow.setContentSize(NSSize(width: 380, height: 900))
            testWindow.title = "Flua inspector verification"
            testWindow.contentView = NSHostingView(rootView: InspectorView().environmentObject(library))
            library.selection = video.id
            library.surface = .desktop
            var coverVideo = video
            coverVideo.videoEdit = VideoEdit(start: 0.25, end: 0.75, thumbnail: 0.1)
            library.edit(coverVideo)
            library.setSurfaceMode(.still)
            results["inspectorPreviewWindowVisible"] = await waitUntilVisible(testWindow)
            func inspectorPreview() -> MediaSurface? {
                func find(_ view: NSView) -> MediaSurface? {
                    if let surface = view as? MediaSurface { return surface }
                    for child in view.subviews {
                        if let surface = find(child) { return surface }
                    }
                    return nil
                }
                return testWindow.contentView.flatMap(find)
            }
            var previewConfiguration = coverVideo
            previewConfiguration.speed = 1.5
            previewConfiguration.dimming = 0.2
            library.editConfiguration(previewConfiguration)
            var previewDeadline = Date().addingTimeInterval(5)
            while inspectorPreview()?.showsStillImage != true && Date() < previewDeadline { await pause(0.05) }
            let videoStillPreview = inspectorPreview()
            results["inspectorVideoStillPreview"] = videoStillPreview?.holdsStill == true && videoStillPreview?.showsStillImage == true
            results["inspectorVideoStillFrameClamped"] = stillFrameTime(edit: coverVideo.videoEdit,
                duration: coverVideo.mediaFacts?.sourceDuration) == 0.25
            capture(testWindow, to: out.appendingPathComponent("Flua-inspector-video-still.png"))
            library.surface = .desktop
            library.setSurfaceMode(.still)
            library.surface = .lockScreen
            library.setSurfaceMode(.animated)
            await pause(0.3)
            let lockScreenAnimated = inspectorPreview()?.holdsStill == false && library.surfaceMode == .animated
            library.surface = .desktop
            await pause(0.3)
            let desktopStillRemains = inspectorPreview()?.holdsStill == true && library.surfaceMode == .still
            library.surface = .lockScreen
            library.setSurfaceMode(.still)
            await pause(0.3)
            results["inspectorSurfaceModesIndependent"] = lockScreenAnimated && desktopStillRemains
                && inspectorPreview()?.holdsStill == true
            library.surface = .desktop
            library.setSurfaceMode(.still)
            library.setSurfaceMode(.animated)
            previewDeadline = Date().addingTimeInterval(3)
            while (inspectorPreview()?.playbackRate ?? 0) <= 0 && Date() < previewDeadline { await pause(0.05) }
            results["inspectorVideoPreviewResumed"] = inspectorPreview()?.holdsStill == false && (inspectorPreview()?.playbackRate ?? 0) > 0
            let resumedVideoTime = inspectorPreview()?.playbackTime ?? 0
            await pause(0.12)
            results["inspectorVideoTimeAdvancesAfterResume"] = (inspectorPreview()?.playbackTime ?? 0) > resumedVideoTime + 0.02
            capture(testWindow, to: out.appendingPathComponent("Flua-inspector-video-animated.png"))
            library.selection = "aurora"
            library.setSurfaceMode(.still)
            await pause(0.4)
            let sceneStillPreview = inspectorPreview()
            results["inspectorSceneStillPreview"] = sceneStillPreview?.holdsStill == true && sceneStillPreview?.showsStillImage == true
            capture(testWindow, to: out.appendingPathComponent("Flua-inspector-scene-still.png"))
            library.setSurfaceMode(.animated)
            let sceneFramesBeforeResume = sceneStillPreview?.sceneFrameCount ?? 0
            await pause(0.4)
            let sceneFramesAfterResume = sceneStillPreview?.sceneFrameCount ?? 0
            results["inspectorSceneFrameProgress"] = sceneFramesAfterResume > sceneFramesBeforeResume + 2
            results["inspectorScenePreviewResumed"] = sceneStillPreview?.holdsStill == false
                && sceneStillPreview?.sceneIsPaused == false && sceneFramesAfterResume > sceneFramesBeforeResume + 2
            capture(testWindow, to: out.appendingPathComponent("Flua-inspector-scene-animated.png"))
            library.selection = previousSelection
            library.edit(video)
            library.editConfiguration(video)
            library.surface = .desktop
            library.setSurfaceMode(previousDesktopMode)
            library.surface = .lockScreen
            library.setSurfaceMode(previousLockScreenMode)
            if previousLinked { library.setSurfacesLinked(true) }
            library.surface = previousSurface
            for check in ["inspectorPreviewWindowVisible", "inspectorVideoStillPreview", "inspectorVideoStillFrameClamped", "inspectorSurfaceModesIndependent", "inspectorVideoPreviewResumed", "inspectorVideoTimeAdvancesAfterResume", "inspectorSceneStillPreview", "inspectorSceneFrameProgress", "inspectorScenePreviewResumed"] {
                if results[check] as? Bool != true { failures.append(check) }
            }
            testWindow.close()
            let exported = out.appendingPathComponent("trimmed.mp4")
            let exportSession = try await VideoTools.exporter(source: videoURL, edit: edited.videoEdit!)
            try await VideoTools.export(exportSession, source: videoURL, destination: exported)
            let exportedInfo = try await VideoInformation.load(exported)
            results["trimmedExport"] = abs(exportedInfo.duration - 0.5) < 0.06 && !exportedInfo.hasAudio
            let sourceWithAudio = try await makeAudioVideo(video: videoURL, directory: out)
            let audioSourceInfo = try await VideoInformation.load(sourceWithAudio)
            let audioSourceBytes = try Data(contentsOf: sourceWithAudio)
            let silentEdit = VideoEdit(start: 0.25, end: 0.75, quality: "medium")
            let silent = out.appendingPathComponent("silent.mp4")
            try await VideoTools.export(VideoTools.exporter(source: sourceWithAudio, edit: silentEdit), source: sourceWithAudio, destination: silent)
            let silentInfo = try await VideoInformation.load(silent)
            // Exported wallpaper video carries no audio track even when the source has one.
            let preservedAudioSource = try Data(contentsOf: sourceWithAudio) == audioSourceBytes
            results["silentExport"] = audioSourceInfo.hasAudio && !silentInfo.hasAudio && abs(silentInfo.duration - 0.5) < 0.08 && preservedAudioSource
            let thumbnail = try await VideoTools.thumbnail(source: videoURL, time: 0.5)
            results["thumbnailExport"] = NSImage(data: thumbnail) != nil
            let sourceBeforeStill = try Data(contentsOf: videoURL)
            let stillTime = stillFrameTime(edit: VideoEdit(start: 0.25, end: 0.75, thumbnail: 0.1), duration: information.duration)
            let stillFrame = try await VideoTools.thumbnail(source: videoURL, time: stillTime)
            surface.configure(video, url: videoURL, mode: .still, stillImage: NSImage(data: stillFrame))
            await pause(0.2)
            results["stillHeld"] = surface.holdsStill && surface.showsStillImage && surface.playbackRate == 0 && !surface.mediaReady
            surface.setPaused(false)
            results["stillIgnoresResume"] = surface.holdsStill && surface.playbackRate == 0
            results["stillPreservesSource"] = try Data(contentsOf: videoURL) == sourceBeforeStill
            do { _ = try VideoTools.range(VideoEdit(start: 2, end: 1), duration: 1); results["rejectInvalidTrim"] = false }
            catch { results["rejectInvalidTrim"] = true }
            do { try await VideoTools.export(exportSession, source: videoURL, destination: videoURL); results["preserveSourceOnExport"] = false }
            catch { results["preserveSourceOnExport"] = FileManager.default.fileExists(atPath: videoURL.path) }
            let packageURL = out.appendingPathComponent("Portable.flua", isDirectory: true)
            try await Library.exportPackage(edited, source: videoURL, destination: packageURL)
            let manifestURL = packageURL.appendingPathComponent("manifest.json")
            var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
            manifest["width"] = 99999
            manifest["height"] = 99999
            manifest["duration"] = 99999
            manifest["dateAdded"] = 0
            manifest["fileSize"] = 99999
            try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
            library.importMedia([packageURL])
            let packageDeadline = Date().addingTimeInterval(20)
            while library.importing && Date() < packageDeadline { await pause(0.1) }
            results["packageRoundTrip"] = library.state.wallpapers.contains {
                $0.id != video.id && $0.kind == "video" && $0.tags == edited.tags && $0.metadata == edited.metadata
                    && $0.color == "Purple" && $0.motion == "High" && $0.dateAdded != nil
                    && $0.mediaFacts?.width == exportedInfo.width && abs(($0.mediaFacts?.sourceDuration ?? 0) - 0.5) < 0.06
            }
            var unclassified = edited
            unclassified.tags = "unknown-color"
            unclassified.metadata?.color = "Unknown"
            let unknownPackageURL = out.appendingPathComponent("UnknownColor.flua", isDirectory: true)
            try await Library.exportPackage(unclassified, source: videoURL, destination: unknownPackageURL)
            library.importMedia([unknownPackageURL])
            let unknownPackageDeadline = Date().addingTimeInterval(20)
            while library.importing && Date() < unknownPackageDeadline { await pause(0.1) }
            results["unknownColorRoundTrip"] = library.state.wallpapers.contains {
                $0.tags == unclassified.tags && $0.color == "Unknown" && $0.metadata == unclassified.metadata
            }
            let beforeCancel = library.state.item(edited.id)!
            let cancelModel = VideoEditorModel(wallpaper: beforeCancel, source: library.disk.url(for: edited)!, library: library)
            while cancelModel.info == nil && cancelModel.error == nil { await pause(0.1) }
            cancelModel.draft.videoEdit?.start = 0.3
            cancelModel.close()
            results["editorCancel"] = library.state.item(edited.id)?.videoEdit == beforeCancel.videoEdit
            let saveModel = VideoEditorModel(wallpaper: edited, source: library.disk.url(for: edited)!, library: library)
            while saveModel.info == nil && saveModel.error == nil { await pause(0.1) }
            saveModel.draft.videoEdit?.start = 0.4
            saveModel.draft.videoEdit?.thumbnail = 0.45
            var newer = library.state.item(edited.id)!
            newer.title = "Renamed while editing"
            newer.favorite.toggle()
            newer.tags = "editor regression"
            newer.speed = 1.5
            newer.dimming = 0.3
            newer.fit.toggle()
            library.edit(newer)
            saveModel.save()
            var expected = newer
            expected.videoEdit = saveModel.draft.videoEdit
            let persistedEditorSave = try library.disk.load().item(edited.id)
            results["editorPreservesNewerEdits"] = library.state.item(edited.id) == expected
                && persistedEditorSave == expected
            let editorSourcePreserved = try Data(contentsOf: videoURL) == Data(contentsOf: library.disk.url(for: edited)!)
            results["editorSave"] = library.state.item(edited.id)?.videoEdit?.start == 0.4 && editorSourcePreserved
            saveModel.draft.videoEdit?.start = information.duration + 1
            saveModel.save()
            results["editorRejectsInvalidDraft"] = saveModel.error != nil && library.state.item(edited.id) == expected
            saveModel.draft.videoEdit = expected.videoEdit
            saveModel.draft.id = "removed-editor-wallpaper"
            saveModel.save()
            results["editorRejectsMissingWallpaper"] = saveModel.error != nil
                && library.state.item(saveModel.draft.id) == nil && library.state.item(edited.id) == expected
            saveModel.close()
            library.edit(edited)
            results["editorPersistence"] = try library.disk.load().item(edited.id)?.videoEdit == edited.videoEdit
            let editorWindow = VideoEditorWindow(wallpaper: edited, source: library.disk.url(for: edited)!, library: library)
            editorWindow.window.orderBack(nil)
            await pause(0.7)
            if let window = NSApp.windows.first(where: { $0.title == "Edit — " + edited.title }), let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let destination = out.appendingPathComponent("Flua-editor.png")
                try bitmap.representation(using: .png, properties: [:])?.write(to: destination)
                capture(window, to: destination)
                results["editorWindow"] = true
                await captureAppearances(window, stem: "Flua-editor", directory: out)
                window.close()
            }
            library.selection = video.id
            await pause(0.3)
            results["inspectorVideoInteraction"] = await verifyInspectorInteraction(library: library)
            results["libraryAssignmentValidated"] = !library.state.displays.isEmpty
                && library.state.displays.values.allSatisfy { $0.desktop.wallpaperID == video.id }
                && library.error == nil
            library.updatePlaylist("ambient", shuffle: false)
            library.startPlaylist("ambient")
            results["playlistStart"] = library.state.displays.values.allSatisfy { $0.desktop.wallpaperID == "aurora" && $0.desktop.playlistID == "ambient" }
            library.advancePlaylists(force: true)
            results["playlistNext"] = library.state.displays.values.allSatisfy { $0.desktop.wallpaperID == "ocean" }
            library.stop()
            results["libraryStop"] = library.state.displays.isEmpty || library.state.nativePlayback.values.allSatisfy { !$0 }
            if let screen = library.screens.first {
                let key = displayID(screen)
                library.state.setMode(.still, display: key, surface: .desktop)
                library.selection = "aurora"
                library.applySelected()
                results["sceneStillMode"] = library.state.displays[key]?.desktop.mode == .still
                library.selection = video.id
                let sourceURL = library.disk.url(for: video)!
                let sourceBefore = try Data(contentsOf: sourceURL)
                library.applySelected()
                results["desktopStill"] = library.state.displays[key]?.desktop.mode == .still
                let assignmentsBeforePause = library.state.displays
                library.togglePlaylistPause()
                results["playlistPauseStatus"] = try library.state.paused
                    && library.activity == "Playlists paused. Wallpapers keep playing."
                    && library.state.displays == assignmentsBeforePause
                    && library.disk.load().paused
                library.togglePlaylistPause()
                results["playlistResumeStatus"] = try !library.state.paused
                    && library.activity == "Playlists resumed."
                    && library.state.displays == assignmentsBeforePause
                    && !library.disk.load().paused
                results["desktopStillSurvivesPause"] = library.state.paused == false && library.state.displays[key]?.desktop.mode == .still
                results["desktopStillPersisted"] = try library.disk.load().displays[key]?.desktop.mode == .still
                results["desktopStillPreservesSource"] = try Data(contentsOf: sourceURL) == sourceBefore
                library.stop()
                library.state.displays.removeAll()
                library.state.paused = false
                library.save()
            }
            if let screen = library.screens.first {
                let key = displayID(screen)
                library.state.assign("ember", display: key, surface: .lockScreen)
                library.state.setMode(.still, display: key, surface: .lockScreen)
                library.selection = video.id
                library.applySelected()
                results["applySelectedSurfaceOnly"] = library.state.displays[key]?.desktop.wallpaperID == video.id
                    && library.state.displays[key]?.lockScreen?.wallpaperID == "ember"
                    && library.state.displays[key]?.lockScreen?.mode == .still
                library.surface = .lockScreen
                library.applySelected()
                results["applyLockScreenOnly"] = library.state.displays[key]?.desktop.wallpaperID == video.id
                    && library.state.displays[key]?.lockScreen?.wallpaperID == video.id
                    && library.state.displays[key]?.lockScreen?.mode == .still
                library.surface = .desktop
                let lockScreen = library.state.displays[key]?.lockScreen
                library.updatePlaylist("ambient", shuffle: false)
                library.startPlaylist("ambient")
                library.advancePlaylists(force: true)
                results["desktopPlaylistPreservesLockScreen"] = library.state.displays.values.allSatisfy {
                    $0.desktop.wallpaperID == "ocean" && $0.lockScreen == lockScreen
                }
                library.stop()
                _ = library.restoreAssignments()
                results["desktopStopPreservesLockScreen"] = library.state.displays.values.allSatisfy { $0.desktop.wallpaperID == nil && $0.lockScreen == lockScreen }
                let persisted = try library.disk.load()
                results["surfaceAssignmentsPersisted"] = persisted.displays == library.state.displays
                library.tick?.invalidate()
                library.surface = .lockScreen
                library.startPlaylist("ambient")
                library.surface = .desktop
                library.startPlaylist("ambient")
                let previousInterval = library.state.playlists[0].interval
                library.state.playlists[0].interval = 0
                library.advancePlaylists(force: false)
                results["independentPlaylistTimers"] = library.state.displays.values.allSatisfy {
                    $0.desktop.wallpaperID == "ocean" && $0.lockScreen?.wallpaperID == "ocean"
                }
                for id in library.screens.map(displayID) { library.state.setSurfacesLinked(true, display: id) }
                library.advancePlaylists(force: false)
                results["linkedPlaylistAdvancesOnce"] = library.state.displays.values.allSatisfy {
                    $0.desktop.wallpaperID == "cosmos" && $0.lockScreen == $0.desktop
                }
                library.state.playlists[0].interval = previousInterval
                library.state.displays.removeAll()
                library.save()
            }
            if let screen = library.screens.first {
                let key = displayID(screen)
                library.selection = "aurora"
                library.applySelected()
                let saved = library.state.displays
                library.surface = .lockScreen
                library.selection = "ember"
                library.setSurfaceMode(.still)
                results["surfaceControlsDraftOnly"] = try library.state.displays == saved
                    && library.disk.load().displays == saved && library.surfaceMode == .still
                library.surface = .desktop
                library.applySelected()
                results["surfaceControlsApplyHiddenMode"] = library.state.displays[key]?.desktop.wallpaperID == "ember"
                    && library.state.displays[key]?.lockScreen?.wallpaperID == nil
                library.surface = .lockScreen
                library.setSurfacesLinked(true)
                results["surfaceControlsLinkCopiesDesktop"] = library.surfacesLinked
                    && library.targetAssignments.allSatisfy { $0.lockScreen == $0.desktop }
                results["configurePickerLinkedNormalizesToDesktop"] = library.surface == .desktop
                library.setSurfaceMode(.still)
                results["surfaceControlsLinkedMode"] = library.surfaceMode == .still
                library.setSurfacesLinked(false)
                library.surface = .lockScreen
                library.setSurfaceMode(.animated)
                results["surfaceControlsUnlinkPreservesDesktop"] = library.targetAssignments.allSatisfy {
                    $0.desktop.mode == .still && $0.lockScreen?.mode == .animated && !$0.surfacesLinked
                }
                library.applySelected()
                results["surfaceControlsPersisted"] = try library.disk.load().displays == library.state.displays
                library.surface = .desktop
                library.state.displays.removeAll()
                library.save()
            }
            let draftValidation = try Library(root: out.appendingPathComponent("ConfigurationDraftValidation"), systemPlaybackEnabled: false)
            draftValidation.tick?.invalidate()
            if let screen = draftValidation.screens.first {
                let key = displayID(screen)
                draftValidation.state.displayMode = "perDisplay"
                draftValidation.display = key
                draftValidation.updatePlaylist("ambient", shuffle: false)
                draftValidation.startPlaylist("ambient")
                draftValidation.surface = .lockScreen
                draftValidation.setSurfaceMode(.still)
                draftValidation.surface = .desktop
                draftValidation.advancePlaylists(force: true)
                draftValidation.surface = .lockScreen
                let advanced = draftValidation.state.displays[key]?.desktop
                results["configurationDraftPreviewUsesLivePlaylist"] = draftValidation.surfaceSummary(.desktop).contains("Quiet tides")
                draftValidation.selection = "cosmos"
                draftValidation.applySelected()
                results["configurationDraftPreservesPlaylistProgress"] = draftValidation.state.displays[key]?.desktop == advanced
                draftValidation.setSurfaceMode(.animated)
                draftValidation.remove(draftValidation.state.item("ocean")!)
                draftValidation.selection = "ember"
                draftValidation.applySelected()
                results["configurationDraftPreservesRemoval"] = draftValidation.state.displays[key]?.desktop.wallpaperID == nil
                    && draftValidation.state.displays[key]?.lockScreen?.wallpaperID == "ember"
            }
            library.selection = edited.id
            library.section = "discover"
            let savedAssignments = library.state.displays, savedPlaylists = library.state.playlists
            library.blockTags(" TEST, , test ")
            let persistedBlockedTags = try library.disk.load().blockedTags
            results["blockedDiscover"] = !library.eligible.contains { $0.id == edited.id } && library.selection == nil
                && library.state.blockedTags == ["test"] && library.state.displays == savedAssignments && library.state.playlists == savedPlaylists
                && persistedBlockedTags == ["test"]
            library.unblockTag("test")
            library.filterTag("PORTABLE")
            results["tagFiltering"] = library.section == "all" && library.visible.contains { $0.id == edited.id } && library.filter.tags == ["portable"]
            library.filter.colors = ["Purple"]
            results["combinedBrowsing"] = library.visible.count == 2
            library.selection = edited.id
            await pause(0.3)
            if let window = NSApp.windows.first(where: { $0.title == "Flua" }) {
                results["browseSystemScrollers"] = verifySystemScrollers()
                if results["browseSystemScrollers"] as? Bool != true { failures.append("browseSystemScrollers") }
                captureView(window, to: out.appendingPathComponent("Flua-filters.png"))
                await captureAppearances(window, stem: "Flua-browse", directory: out)
            }
            library.filter.colors = ["Orange"]
            await pause(0.2)
            if let window = NSApp.windows.first(where: { $0.title == "Flua" }) {
                captureView(window, to: out.appendingPathComponent("Flua-empty-results.png"))
            }
            library.query = "no-match"
            library.blockTags("test")
            library.clearFilters()
            let blockedTagsAfterReset = try library.disk.load().blockedTags
            results["clearFiltersPreservesBlockedTags"] = library.query.isEmpty && library.filter.activeCount == 0
                && library.state.blockedTags == ["test"] && !library.visible.contains { normalizedTags($0.tags).contains("test") }
                && !library.visible.isEmpty && blockedTagsAfterReset == ["test"]
            library.unblockTag("test")
            results["clearFilters"] = library.filter.activeCount == 0 && library.query.isEmpty && library.visible.count == library.state.wallpapers.count
            library.blockTags("example")
            guard let settings = NSApp.windows.first(where: { $0.title == "Flua" }) else {
                throw NativeWallpaperError("Main window unavailable for internal Settings verification.")
            }
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let animationPassed = await verifySettingsInspectorAnimation(settings, library: library, directory: out)
                results["settingsInspectorAnimation"] = animationPassed
                if !animationPassed { failures.append("settingsInspectorAnimation") }
            }
            library.section = "settings"
            await pause(0.3)
            let settingsChrome = windowControlsVisible(settings)
            captureView(settings, to: out.appendingPathComponent("Flua-settings.png"))
            await captureAppearances(settings, stem: "Flua-settings", directory: out)
            library.section = "all"
            await pause(0.3)
            results["libraryWindowChrome"] = results["libraryWindowChrome"] as? Bool == true
                && settingsChrome && windowControlsVisible(settings)
            captureView(settings, to: out.appendingPathComponent("Flua-library-system.png"))
            library.section = "settings"
            results["systemAccentDefault"] = library.state.accentColor == nil && library.accent == AppAccent.system.color && library.accentOverride == nil
            library.state.accentColor = AppAccent.purple.rawValue
            library.save()
            let savedAccent = try library.disk.load().accentColor
            results["accentSelection"] = savedAccent == "Purple" && library.accent == AppAccent.purple.color && library.accentOverride == AppAccent.purple.color
            await pause(0.3)
            captureView(settings, to: out.appendingPathComponent("Flua-settings-purple.png"))
            library.section = "all"
            await pause(0.3)
            captureView(settings, to: out.appendingPathComponent("Flua-library-purple.png"))
            library.section = "settings"
            let settingsFrame = settings.frame
            settings.setFrame(NSRect(x: settingsFrame.origin.x, y: settingsFrame.origin.y, width: 720, height: 440), display: true, animate: false)
            park(settings)
            await pause(0.3)
            captureView(settings, to: out.appendingPathComponent("Flua-settings-compact.png"))
            settings.setFrame(settingsFrame, display: true, animate: false)
            park(settings)
            library.state.accentColor = AppAccent.system.rawValue
            results["explicitSystemAccent"] = library.accentOverride == nil
            library.state.accentColor = "Unknown future color"
            results["unknownAccentFallback"] = library.accent == AppAccent.system.color && library.accentOverride == nil
            library.state.accentColor = nil
            library.save()
            results["systemAccentReset"] = try library.disk.load().accentColor == nil
            library.section = "all"
            library.unblockTag("example")
            library.selection = "aurora"
            library.section = "discover"
            await pause(0.5)
            if let window = NSApp.windows.first(where: { $0.title == "Flua" }) {
                results["discoverWindow"] = true
                await captureAppearances(window, stem: "Flua-discover", directory: out)
                results["instantInspectorResize"] = await verifyInstantInspectorResize(window)
                let originalFrame = window.frame
                window.setFrame(NSRect(x: originalFrame.origin.x, y: originalFrame.origin.y, width: 720, height: 440), display: true, animate: false)
                park(window)
                await pause(0.3)
                await pause(1)
                results["compactWindow"] = window.minSize.width <= 720 && window.frame.width <= 720
                results["compactWindowWidth"] = window.frame.width
                results["minimumWindowWidth"] = window.minSize.width
                if let screen = window.screen {
                    results["screenWidth"] = screen.frame.width
                    results["windowNarrowerThanHalfScreen"] = window.frame.width < screen.frame.width / 2
                }
                captureView(window, to: out.appendingPathComponent("Flua-minimum-size.png"))
                library.section = "browse"
                await pause(0.3)
                captureView(window, to: out.appendingPathComponent("Flua-minimum-browse.png"))
                library.section = "discover"
                window.setFrame(originalFrame, display: true)
                park(window)
                await pause(1)
                if let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    if let data = bitmap.representation(using: .png, properties: [:]) {
                        let destination = out.appendingPathComponent("Flua-discover.png")
                        try data.write(to: destination)
                        capture(window, to: destination)
                        results["windowSnapshot"] = (try? Data(contentsOf: destination))?.isEmpty == false
                    }
                }
            }
            results["libraryRoundTrip"] = try library.disk.load().wallpapers == library.state.wallpapers
            let reopenResults = try await verifyReopening(library: library)
            for (key, passed) in reopenResults {
                results[key] = passed
                if !passed { failures.append(key) }
            }
            let importResults = try await verifyImportFormats(library: library, image: imageURL, video: videoURL, package: packageURL, output: out)
            for (key, passed) in importResults {
                results[key] = passed
                if !passed { failures.append(key) }
            }
            results["symlinkImportIsIndependent"] = try await verifySymlinkImport(library: library, image: imageURL, output: out)
            library.blockTags("unknown-color")
            library.importMedia([unknownPackageURL])
            let blockedImportDeadline = Date().addingTimeInterval(20)
            while library.importing && Date() < blockedImportDeadline { await pause(0.1) }
            results["blockedImportRevealed"] = library.selected.map { library.state.isBlocked($0) && library.visible.contains($0) } == true
                && library.state.blockedTags == ["unknown-color"]
            library.undoImport()
            library.unblockTag("unknown-color")
            let beforeDrop = Set(library.state.wallpapers.map(\.id))
            await library.importDroppedFiles([NSItemProvider(object: imageURL as NSURL), NSItemProvider(object: videoURL as NSURL)])
            let dropDeadline = Date().addingTimeInterval(20)
            while library.importing && Date() < dropDeadline { await pause(0.1) }
            results["fileDrop"] = library.lastImportIDs.count == 2 && library.section == "all"
                && library.lastImportIDs.allSatisfy { id in library.visible.contains { $0.id == id } }
            library.undoImport()
            results["fileDropUndo"] = Set(library.state.wallpapers.map(\.id)) == beforeDrop
            let beforeUndo = Set(library.state.wallpapers.map(\.id))
            library.importMedia([imageURL], playlistID: importPlaylist.id)
            let undoDeadline = Date().addingTimeInterval(20)
            while library.importing && Date() < undoDeadline { await pause(0.1) }
            let undoItem = library.selected
            results["playlistFileImport"] = undoItem.map { library.state.playlist(importPlaylist.id)?.items.contains($0.id) == true } ?? false
            library.undoImport()
            results["importUndo"] = Set(library.state.wallpapers.map(\.id)) == beforeUndo && library.importNotice == nil
                && FileManager.default.fileExists(atPath: imageURL.path)
            library.addToPlaylist([edited.id], playlistID: importPlaylist.id)
            library.addToPlaylist([edited.id], playlistID: importPlaylist.id)
            results["playlistExistingAdd"] = library.state.playlist(importPlaylist.id)?.items.filter { $0 == edited.id }.count == 1
            results["systemWallpaperPreserved"] = library.screens.map { NSWorkspace.shared.desktopImageURL(for: $0) } == originalWallpapers
            let verificationWindows = NSApp.windows.filter { $0.styleMask.contains(.titled) }
            results["verificationWindows"] = verificationWindows.map { ["title": $0.title, "visible": $0.isVisible, "alpha": $0.alphaValue, "frame": NSStringFromRect($0.frame)] as [String: Any] }
            results["nonPlaybackWindowsHidden"] = verificationWindows.allSatisfy { window in
                !window.isVisible || window.alphaValue == 0
            }
            if results["nonPlaybackWindowsHidden"] as? Bool != true { failures.append("nonPlaybackWindowsHidden") }
            let required = [ "libraryWindowChrome", "instantInspectorResize", "independentPlaylistTimers", "linkedPlaylistAdvancesOnce", "configurationDraftPreviewUsesLivePlaylist", "configurationDraftPreservesPlaylistProgress", "configurationDraftPreservesRemoval", "applySelectedSurfaceOnly", "applyLockScreenOnly", "surfaceControlsApplyHiddenMode", "configurePickerLinkedNormalizesToDesktop", "fileDrop", "fileDropUndo", "blockedImportRevealed", "importRevealsAdded", "editorCancel", "editorSave", "editorPreservesNewerEdits", "editorRejectsInvalidDraft", "editorRejectsMissingWallpaper", "playlistFileImport", "importUndo", "playlistExistingAdd", "inspectorSceneInteraction", "inspectorVideoInteraction", "explicitSystemAccent", "systemAccentDefault", "accentSelection", "unknownAccentFallback", "systemAccentReset", "importFacts", "rotatedFacts", "missingFacts", "legacyBackfill", "staleEditPreservesFacts", "unknownColorBackfill", "unknownColorRoundTrip", "blockedDiscover", "tagFiltering", "combinedBrowsing", "clearFiltersPreservesBlockedTags", "clearFilters", "imageImport", "videoImport", "symlinkImportIsIndependent", "videoReady", "videoPlaying", "videoLooped", "videoPaused", "videoResumed", "liveAdjustmentPreservesTime", "liveAdjustmentSpeed", "stillHeld", "stillIgnoresResume", "stillPreservesSource", "sceneStillMode", "desktopStill", "desktopStillSurvivesPause", "playlistPauseStatus", "playlistResumeStatus", "desktopStillPersisted", "desktopStillPreservesSource", "render_image", "render_aurora", "render_cosmos", "render_ocean", "render_ember", "systemWallpaperPreserved", "libraryAssignmentValidated", "nativeDescriptorValidation", "nativeDescriptorValidationRejectsMissing", "nativeCatalogMismatchRejected", "backgroundLaunch", "videoPreviewWindowVisible", "scenePreviewWindowVisible", "scenePreviewReshownWindowVisible", "playlistStart", "playlistNext", "libraryStop", "libraryRoundTrip", "discoverWindow", "windowSnapshot", "videoInformation", "trimmedPlayback", "trimmedExport", "thumbnailExport", "rejectInvalidTrim", "preserveSourceOnExport", "packageRoundTrip", "editorPersistence", "editorWindow", "silentExport", "desktopPlaylistPreservesLockScreen", "desktopStopPreservesLockScreen", "surfaceAssignmentsPersisted"]
            for key in required + ["compactWindow"] where results[key] as? Bool != true { failures.append(key) }
            for (key, value) in results where key.hasPrefix("surfaceControls") && value as? Bool != true { failures.append(key) }
        } catch { failures.append(String(reflecting: error)) }
        results["failures"] = failures
        results["passed"] = failures.isEmpty
        if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: out.appendingPathComponent("smoke-results.json")) }
        NSApp.terminate(nil)
    }
    @MainActor private static func verifySymlinkImport(library: Library, image: URL, output: URL) async throws -> Bool {
        let linked = output.appendingPathComponent("linked-source.png")
        let alias = output.appendingPathComponent("linked.png")
        let moved = output.appendingPathComponent("linked-source-moved.png")
        try FileManager.default.copyItem(at: image, to: linked)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: linked)
        let previousIDs = Set(library.state.wallpapers.map(\.id))
        library.error = nil
        library.importMedia([alias])
        let deadline = Date().addingTimeInterval(20)
        while library.importing && Date() < deadline { await pause(0.1) }
        guard !library.importing, library.error == nil,
              let wallpaper = library.state.wallpapers.first(where: { !previousIDs.contains($0.id) }),
              wallpaper.kind == "image", let copied = library.disk.url(for: wallpaper) else { return false }
        let display = "symlink-import-smoke"
        var descriptorState = library.state
        descriptorState.assign(wallpaper.id, display: display)
        func descriptorUsesCopy() throws -> Bool {
            let assignments = try NativeWallpaperStore.assignments(from: descriptorState, displays: [display], root: library.disk.root, provider: "com.example.flua.smoke")
            guard let choice = assignments[display]?.desktop,
                  let file = (choice["Files"] as? [[String: String]])?.first?["relative"] else { return false }
            return URL(string: file)?.resolvingSymlinksInPath() == copied.resolvingSymlinksInPath()
        }
        guard try descriptorUsesCopy(),
              (try? copied.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              (try? copied.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return false }
        try FileManager.default.moveItem(at: linked, to: moved)
        let brokenAlias = output.appendingPathComponent("broken-link.png")
        try FileManager.default.createSymbolicLink(at: brokenAlias, withDestinationURL: output.appendingPathComponent("missing-source.png"))
        let brokenLibrary = try Library(root: output.appendingPathComponent("BrokenSymlinkLibrary"))
        brokenLibrary.tick?.invalidate()
        let previousBrokenIDs = Set(brokenLibrary.state.wallpapers.map(\.id))
        brokenLibrary.importMedia([brokenAlias])
        let brokenDeadline = Date().addingTimeInterval(20)
        while brokenLibrary.importing && Date() < brokenDeadline { await pause(0.1) }
        let brokenRejected = !brokenLibrary.importing && brokenLibrary.error != nil
            && Set(brokenLibrary.state.wallpapers.map(\.id)) == previousBrokenIDs
        brokenLibrary.stop()
        return try descriptorUsesCopy()
            && brokenRejected
            && FileManager.default.fileExists(atPath: moved.path)
            && !FileManager.default.fileExists(atPath: alias.path)
            && NSImage(contentsOf: copied) != nil
            && (try Data(contentsOf: copied)) == (try Data(contentsOf: image))
    }

    @MainActor private static func verifyImportFormats(library: Library, image: URL, video: URL, package: URL, output: URL) async throws -> [String: Bool] {
        let zipURL = output.appendingPathComponent("ImportVideo.zip")
        let archive = Process()
        archive.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        archive.currentDirectoryURL = package
        archive.arguments = ["-q", "-X", zipURL.path, "manifest.json", "asset.mp4", "thumbnail.png"]
        try archive.run()
        archive.waitUntilExit()
        guard archive.terminationStatus == 0 else { throw LibraryError.unreadableMedia("ZIP fixture") }
        let bdpkgURL = output.appendingPathComponent("ImportVideo.bdpkg")
        try FileManager.default.copyItem(at: zipURL, to: bdpkgURL)
        let packageVideo = package.appendingPathComponent("asset.mp4")
        let fixtures: [(String, URL, URL, String)] = [
            ("fullImportPNG", image, image, "image"),
            ("fullImportMOV", video, video, "video"),
            ("fullImportMP4", packageVideo, packageVideo, "video"),
            ("fullImportFolder", package, packageVideo, "video"),
            ("fullImportJSON", package.appendingPathComponent("manifest.json"), packageVideo, "video"),
            ("fullImportZIP", zipURL, packageVideo, "video"),
            ("fullImportBDPKG", bdpkgURL, packageVideo, "video")
        ]
        var results: [String: Bool] = [:]
        for (key, input, source, kind) in fixtures {
            let sourceBytes = try Data(contentsOf: source)
            let inputBytes = input.hasDirectoryPath ? nil : try Data(contentsOf: input)
            let previousIDs = Set(library.state.wallpapers.map(\.id))
            library.error = nil
            library.importMedia([input])
            let deadline = Date().addingTimeInterval(20)
            while library.importing && Date() < deadline { await pause(0.1) }
            let added = library.state.wallpapers.filter { !previousIDs.contains($0.id) }
            guard !library.importing, library.error == nil, added.count == 1,
                  let wallpaper = added.first, wallpaper.kind == kind,
                  let copied = library.disk.url(for: wallpaper) else {
                results[key] = false
                continue
            }
            let decoded: Bool
            if kind == "video" {
                let frame = try await VideoTools.thumbnail(source: copied, time: 0)
                decoded = NSImage(data: frame) != nil
            } else { decoded = NSImage(contentsOf: copied) != nil }
            let persisted = try library.disk.load().item(wallpaper.id)
            let copiedBytes = try Data(contentsOf: copied)
            let retainedSource = try Data(contentsOf: source)
            let retainedInput = inputBytes == nil ? nil : try Data(contentsOf: input)
            results[key] = decoded && persisted == wallpaper
                && wallpaper.mediaFacts?.width == 640 && wallpaper.mediaFacts?.height == 360
                && (kind == "image" || (wallpaper.mediaFacts?.sourceDuration ?? 0) > 0)
                && copied.standardizedFileURL != source.standardizedFileURL
                && copiedBytes == sourceBytes && retainedSource == sourceBytes
                && retainedInput == inputBytes
        }
        return results
    }
    @MainActor private static func verifySettingsInspectorAnimation(_ window: NSWindow, library: Library, directory: URL) async -> Bool {
        guard let root = window.contentView else { return false }
        func frame() -> NSRect? {
            var result: NSRect?
            func visit(_ view: NSView) {
                if view.identifier?.rawValue == "FluaInspectorApplyTarget" {
                    var ancestor = view.superview
                    while let parent = ancestor {
                        if let scroll = parent as? NSScrollView {
                            if !scroll.isHiddenOrHasHiddenAncestor {
                                if let layer = scroll.layer, let rootLayer = root.layer {
                                    let presented = layer.presentation() ?? layer
                                    result = (rootLayer.presentation() ?? rootLayer).convert(presented.bounds, from: presented)
                                } else {
                                    result = root.convert(scroll.bounds, from: scroll)
                                }
                            }
                            break
                        }
                        ancestor = parent.superview
                    }
                }
                view.subviews.forEach(visit)
            }
            visit(root)
            return result
        }
        let originalSelection = library.selection
        let originalSection = library.section
        defer {
            library.selection = originalSelection
            library.section = originalSection
        }
        library.selection = "aurora"
        library.section = "all"
        await pause(1)
        guard let baseline = frame() else { return false }
        var samples: [String: [String]] = [:]
        var moving: [Bool] = []
        for (direction, section) in [("opening", "settings"), ("closing", "all")] {
            library.navigate(to: section)
            var frames: [NSRect] = []
            var recorded: [String] = []
            for _ in 0..<25 {
                await pause(0.02)
                if let current = frame() {
                    frames.append(current)
                    recorded.append(NSStringFromRect(current))
                } else { recorded.append("hidden") }
            }
            samples[direction] = recorded
            let intermediate = frames.filter { $0.minX > baseline.minX + 1 && $0.minX < root.bounds.maxX - 1 }
            moving.append(intermediate.count >= 2 && intermediate.first != intermediate.last)
            await pause(0.5)
        }
        if let data = try? JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("settings-inspector-animation.json"))
        }
        return moving.allSatisfy { $0 } && frame() == baseline
    }
    @MainActor private static func verifyInstantInspectorResize(_ window: NSWindow) async -> Bool {
        guard let root = window.contentView else { return false }
        let originalFrame = window.frame
        defer { window.setFrame(originalFrame, display: true, animate: false) }
        func inspectorFrame() -> NSRect? {
            var frame: NSRect?
            func visit(_ view: NSView) {
                if view.identifier?.rawValue == "FluaInspectorApplyTarget" {
                    var ancestor = view.superview
                    while let parent = ancestor {
                        if let scroll = parent as? NSScrollView {
                            if !scroll.isHiddenOrHasHiddenAncestor {
                                frame = root.convert(scroll.bounds, from: scroll)
                            }
                            break
                        }
                        ancestor = parent.superview
                    }
                }
                view.subviews.forEach(visit)
            }
            visit(root)
            return frame
        }
        var passed = true
        // Match shortcut tiling: jump sizes without an AppKit window animation.
        for width in [1100.0, 900, 1320, 1000, 999, 1100, 1320] {
            var frame = originalFrame
            frame.size.width = width
            window.setFrame(frame, display: true, animate: false)
            await pause(0.05)
            root.layoutSubtreeIfNeeded()
            let immediate = inspectorFrame()
            await pause(0.35)
            root.layoutSubtreeIfNeeded()
            let settled = inspectorFrame()
            let visible = width >= 1000
            let stable = immediate == settled && (settled != nil) == visible
            if !stable {
                print("Inspector resize at \(width): initial \(String(describing: immediate)), settled \(String(describing: settled))")
            }
            passed = passed && stable
        }
        return passed
    }
    @MainActor private static func verifySystemScrollers() -> Bool {
        guard let window = NSApp.windows.first(where: { $0.title == "Flua" }),
              let root = window.contentView else { return false }
        var scrollViews: [NSScrollView] = []
        var header: NSView?
        func collect(_ view: NSView) {
            if view.identifier?.rawValue == "FluaLibraryHeader" { header = view }
            if let scrollView = view as? NSScrollView, scrollView.hasVerticalScroller,
               scrollView.bounds.width > 260 {
                scrollViews.append(scrollView)
            }
            for child in view.subviews { collect(child) }
        }
        collect(root)
        guard let header else { return false }
        let headerFrame = header.convert(header.bounds, to: nil)
        return scrollViews.count == 2 && scrollViews.allSatisfy { scrollView in
            let frame = scrollView.convert(scrollView.bounds, to: nil)
            let isLibrary = frame.width > root.bounds.width / 2
            let expectedTop = isLibrary ? headerFrame.minY : window.frame.height
            guard scrollView.scrollerStyle == NSScroller.preferredScrollerStyle,
                  abs(frame.minY) < 1, abs(frame.maxY - expectedTop) < 1 else {
                print("Scroll view does not fill its pane: \(frame), expected top: \(expectedTop)")
                return false
            }
            if let scroller = scrollView.verticalScroller, !scroller.isHidden {
                let track = scroller.convert(scroller.bounds, to: nil)
                guard abs(track.minY - frame.minY) < 1, abs(track.maxY - frame.maxY) < 1 else {
                    print("Scrollbar does not fill its scroll view: \(track), scroll view: \(frame)")
                    return false
                }
            }
            if isLibrary {
                let originalOrigin = scrollView.contentView.bounds.origin
                scrollView.contentView.scroll(to: NSPoint(x: originalOrigin.x, y: originalOrigin.y + 100))
                scrollView.reflectScrolledClipView(scrollView.contentView)
                let pinned = header.convert(header.bounds, to: nil) == headerFrame
                scrollView.contentView.scroll(to: originalOrigin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
                return pinned
            }
            return true
        }
    }
    @MainActor private static func verifyInspectorInteraction(library: Library) async -> Bool {
        guard let window = NSApp.windows.first(where: { $0.title == "Flua" }),
              let root = window.contentView, let parent = root.superview,
              let selected = library.selected else { return false }
        await pause(0.3)
        var inspector: NSScrollView?
        func findInspector(_ view: NSView) {
            if let scroll = view as? NSScrollView, scroll.hasVerticalScroller {
                let frame = root.convert(scroll.bounds, from: scroll)
                if frame.minX > root.bounds.midX, frame.width < root.bounds.width / 2 { inspector = scroll }
            }
            for child in view.subviews { findInspector(child) }
        }
        findInspector(root)
        guard let inspector else { return false }
        var controls: [NSControl] = []
        var applyTarget: NSView?
        func collect(_ view: NSView) {
            if let control = view as? NSControl { controls.append(control) }
            if view.identifier?.rawValue == "FluaInspectorApplyTarget" { applyTarget = view }
            for child in view.subviews { collect(child) }
        }
        collect(inspector)
        guard let button = applyTarget else { return false }
        let slider = controls.compactMap({ $0 as? NSSlider }).first
        let testControls: [NSView] = [button] + (slider != nil ? [slider!] : [])
        for control in testControls {
            control.scrollToVisible(control.bounds)
            await pause(0.1)
            let center = NSPoint(x: control.bounds.midX, y: control.bounds.midY)
            guard let hit = root.hitTest(parent.convert(center, from: control)),
                  control === button || hit === control || hit.isDescendant(of: control) else { return false }
        }
        button.scrollToVisible(button.bounds)
        await pause(0.1)
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let time = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: time,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: time + 0.01,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0) else { return false }
        NSApp.postEvent(up, atStart: true)
        window.sendEvent(down)
        await pause(0.5)
        return library.error == nil && !library.state.displays.isEmpty
            && library.state.displays.values.allSatisfy { $0.desktop.wallpaperID == selected.id }
    }
    @MainActor private static func verifyReopening(library: Library) async throws -> [String: Bool] {
        var results: [String: Bool] = [:]
        func libraryWindows() -> [NSWindow] { NSApp.windows.filter { $0.title == "Flua" && $0.isVisible } }
        func reopen() throws {
            let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication),
                targetDescriptor: NSAppleEventDescriptor(processIdentifier: ProcessInfo.processInfo.processIdentifier),
                returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
            _ = try event.sendEvent(options: .noReply, timeout: 1)
        }
        library.selection = "aurora"
        library.applySelected()
        defer { library.stop() }
        let activeChoice = library.state.displays.values.first?.desktop.wallpaperID
        libraryWindows().first?.close()
        await pause(0.3)
        let libraryWasClosed = libraryWindows().isEmpty
        try reopen()
        await pause(0.5)
        results["reopenClosedLibraryWithWallpaper"] = libraryWasClosed && libraryWindows().count == 1 && activeChoice != nil
            && library.state.displays.values.first?.desktop.wallpaperID == activeChoice
        let minimizedWindow = libraryWindows().first
        minimizedWindow?.miniaturize(nil)
        await pause(0.5)
        let libraryWasMinimized = minimizedWindow?.isMiniaturized == true
        try reopen()
        await pause(0.5)
        results["reopenMinimizedLibrary"] = libraryWasMinimized && libraryWindows().count == 1 && libraryWindows().first?.isMiniaturized == false
        try reopen()
        await pause(0.3)
        results["reopenKeepsSingleLibrary"] = libraryWindows().count == 1
        return results
    }
    @MainActor private static func captureAppearances(_ window: NSWindow, stem: String, directory: URL) async {
        let original = window.appearance
        let originalContentAppearance = window.contentView?.appearance
        for (name, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            window.appearance = NSAppearance(named: name)
            window.contentView?.appearance = NSAppearance(named: name)
            await pause(0.3)
            captureView(window, to: directory.appendingPathComponent(stem + "-" + suffix + ".png"))
        }
        window.appearance = original
        window.contentView?.appearance = originalContentAppearance
    }
    @MainActor static func captureView(_ window: NSWindow, to url: URL) {
        if let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
            capture(window, to: url)
        }
    }
    static func png(_ image: NSImage) throws -> Data {
        guard let data = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) else { throw LibraryError.unreadableMedia("test image") }
        return png
    }
    @MainActor static func capture(_ window: NSWindow, to url: URL) {
        guard window.alphaValue > 0.01, CGPreflightScreenCaptureAccess() else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
        try? task.run()
        task.waitUntilExit()
    }
    private static func processCPUTime() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    @MainActor private static weak var presentedPlaybackWindow: NSWindow?
    @discardableResult @MainActor private static func waitUntilVisible(_ window: NSWindow) async -> Bool {
        if let previous = presentedPlaybackWindow, previous !== window { previous.orderOut(nil) }
        presentedPlaybackWindow = window
        await pause(0.15)
        if !window.occlusionState.contains(.visible) {
            // Only live playback needs an exposed surface, including over an active fullscreen app.
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .stationary, .ignoresCycle]
            window.level = .statusBar
            window.orderFrontRegardless()
        }
        let deadline = Date().addingTimeInterval(5)
        while !window.occlusionState.contains(.visible) && Date() < deadline { await pause(0.05) }
        return window.occlusionState.contains(.visible)
    }
    static func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    static func makeAudioVideo(video: URL, directory: URL) async throws -> URL {
        let audioURL = directory.appendingPathComponent("tone.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        for i in 0..<48_000 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 440 * 2 * .pi / 48_000) * 0.05) }
        try autoreleasepool {
            let audioFile = try AVAudioFile(forWriting: audioURL, settings: format.settings)
            try audioFile.write(from: buffer)
        }
        let composition = AVMutableComposition()
        for (url, type) in [(video, AVMediaType.video), (audioURL, AVMediaType.audio)] {
            let asset = AVURLAsset(url: url)
            let source = try await asset.loadTracks(withMediaType: type).first!
            let destination = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid)!
            try destination.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600)), of: source, at: .zero)
        }
        let output = directory.appendingPathComponent("audio-source.mov")
        let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)!
        try await exporter.export(to: output, as: .mov)
        return output
    }
    static func makeVideo(_ url: URL, transform: CGAffineTransform = .identity) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360])
        input.transform = transform
        let attributes = CVPixelBufferCreationAttributes(pixelFormatType: .init(rawValue: kCVPixelFormatType_32ARGB), size: CVImageSize(width: 640, height: 360), compatibility: [.cgBitmapContext])
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: attributes)
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<24 {
            guard let pool = receiver.pixelBufferPool else { throw LibraryError.unreadableMedia("video encoder") }
            let pixels = try pool.makeMutablePixelBuffer()
            pixels.withUnsafeBuffer { buffer in
                CVPixelBufferLockBaseAddress(buffer, [])
                defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
                if let c = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
                    c.setFillColor(CGColor(red: 0.03, green: 0.10, blue: 0.17, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
                    c.setFillColor(CGColor(red: 0.45, green: 0.8, blue: 0.68, alpha: 1)); c.fillEllipse(in: CGRect(x: 20 + frame * 20, y: 130, width: 80, height: 80))
                }
            }
            try await receiver.append(CVReadOnlyPixelBuffer(pixels), with: CMTime(value: Int64(frame), timescale: 24))
        }
        receiver.finish()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else { throw writer.error ?? LibraryError.unreadableMedia("video finalize") }
    }
}

// SwiftUI glass buttons do not expose an NSButton for pointer-based smoke verification.
struct InspectorApplyTarget: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier("FluaInspectorApplyTarget")
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

struct LibraryHeaderTarget: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier("FluaLibraryHeader")
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}
