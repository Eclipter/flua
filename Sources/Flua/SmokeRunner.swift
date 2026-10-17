import AppKit
import ApplicationServices
import AVFoundation
import SwiftUI

/// Invoked only with --smoke-test <directory>; writes all test state to --data-dir.
enum SmokeRunner {
    private static var running = false
    /// Keeps an audit window off the active space and out of the window cycle.
    @MainActor static func park(_ window: NSWindow) {
        window.alphaValue = 0.01
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
            "Search", "Category filter", "Color filter", "Motion filter", "Resolution filter", "Aspect filter",
            "Filter by ambient", "Filter by green", "Filter by nature", "Add favorite", "Scene name", "Tags", "Category",
            "Speed", "Dim", "Previous in playlist", "Next in playlist", "Pause or resume", "Stop on selected displays", "Create playlist"
        ])
        library.query = "no-match"
        library.filterTag("ambient")
        library.blockTags("test")
        await pause(0.4)
        for window in NSApp.windows { park(window); window.orderBack(nil) }
        missing += missingNames("Flua Library Audit", ["Clear search", "Clear filters", "Remove ambient filter"])
        let settings = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 530, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        settings.title = "Flua Settings Audit"
        settings.isReleasedWhenClosed = false
        settings.contentView = NSHostingView(rootView: SettingsView().environmentObject(library).frame(width: 530, height: 760))
        park(settings)
        settings.orderBack(nil)
        await pause(0.4)
        missing += missingNames("Flua Settings Audit", ["Accent color", "Blocked tags", "Block", "Unblock test"])
        let report: [String: Any] = ["passed": missing.isEmpty, "missing": missing]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: destination)
        }
        exit(missing.isEmpty ? 0 : 1)
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
    @MainActor static func runIfRequested(library: Library) async {
        let args = ProcessInfo.processInfo.arguments
        guard !running, let i = args.firstIndex(of: "--smoke-test"), args.indices.contains(i + 1) else { return }
        running = true
        let out = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        var results: [String: Any] = [:]
        var failures: [String] = []
        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            await pause(1)
            results["libraryVisibleOnLaunch"] = NSApp.windows.contains { $0.title == "Flua" && $0.isVisible }
            if results["libraryVisibleOnLaunch"] as? Bool != true { failures.append("libraryVisibleOnLaunch") }
            results["inspectorSceneInteraction"] = await verifyInspectorInteraction(library: library)
            library.stop()
            let image = AmbientSceneView.thumbnail(scene: "ocean", size: NSSize(width: 640, height: 360))
            let imageURL = out.appendingPathComponent("sample.png")
            try png(image).write(to: imageURL)
            let videoURL = out.appendingPathComponent("sample.mov")
            try await Task.detached { try makeVideo(videoURL) }.value
            library.importMedia([imageURL, videoURL])
            let deadline = Date().addingTimeInterval(20)
            while library.importing && Date() < deadline { await pause(0.1) }
            let videos = library.state.wallpapers.filter { $0.kind == "video" }
            let images = library.state.wallpapers.filter { $0.kind == "image" }
            results["imageImport"] = images.count == 1
            results["videoImport"] = videos.count == 1
            if videos.count != 1 || images.count != 1 { throw LibraryError.unreadableMedia("smoke fixtures") }
            let testWindow = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
            testWindow.isReleasedWhenClosed = false
            testWindow.title = "Flua playback verification"
            let surface = MediaSurface(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
            testWindow.contentView = surface
            testWindow.orderFront(nil)
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
            try await Task.detached { try makeVideo(rotatedURL, transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 360, ty: 0)) }.value
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
            await pause(0.8)
            results["videoReady"] = surface.mediaReady
            results["videoPlaying"] = surface.playbackRate > 0
            var times: [Double] = []
            for _ in 0..<16 { await pause(0.15); times.append(surface.playbackTime) }
            results["videoTimes"] = times
            results["videoLooped"] = zip(times, times.dropFirst()).contains { $1 < $0 - 0.2 }
            surface.setPaused(true)
            let pausedTime = surface.playbackTime
            await pause(0.5)
            results["videoPaused"] = abs(surface.playbackTime - pausedTime) < 0.08 && surface.playbackRate == 0
            surface.setPaused(false)
            await pause(0.3)
            results["videoResumed"] = surface.playbackRate > 0
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
            edited.videoEdit = VideoEdit(start: 0.25, end: 0.75, thumbnail: 0.5, includeAudio: false, quality: "medium")
            edited.metadata = SceneMetadata(details: "Portable test scene", category: "Abstract", creditTitle: "Flua", creditURL: "", color: "Purple", motion: "High")
            edited.tags = "test, portable"
            surface.configure(edited, url: library.disk.url(for: edited))
            await pause(0.4)
            var trimmedTimes: [Double] = []
            for _ in 0..<12 { await pause(0.1); trimmedTimes.append(surface.playbackTime) }
            results["trimmedTimes"] = trimmedTimes
            results["trimmedPlayback"] = trimmedTimes.allSatisfy { $0 >= 0.24 && $0 <= 0.77 } && zip(trimmedTimes, trimmedTimes.dropFirst()).contains { $1 < $0 - 0.1 }
            let exported = out.appendingPathComponent("trimmed.mp4")
            let exportSession = try await VideoTools.exporter(source: videoURL, edit: edited.videoEdit!)
            try await VideoTools.export(exportSession, source: videoURL, destination: exported)
            let exportedInfo = try await VideoInformation.load(exported)
            results["trimmedExport"] = abs(exportedInfo.duration - 0.5) < 0.06 && !exportedInfo.hasAudio
            let sourceWithAudio = try await makeAudioVideo(video: videoURL, directory: out)
            let audioEdit = VideoEdit(start: 0.25, end: 0.75, includeAudio: true, quality: "medium")
            let withAudio = out.appendingPathComponent("with-audio.mp4")
            let audioSession = try await VideoTools.exporter(source: sourceWithAudio, edit: audioEdit)
            try await VideoTools.export(audioSession, source: sourceWithAudio, destination: withAudio)
            let audioInfo = try await VideoInformation.load(withAudio)
            results["audioExport"] = audioInfo.hasAudio && abs(audioInfo.duration - 0.5) < 0.08
            var mutedEdit = audioEdit; mutedEdit.includeAudio = false
            let muted = out.appendingPathComponent("muted.mp4")
            try await VideoTools.export(VideoTools.exporter(source: sourceWithAudio, edit: mutedEdit), source: sourceWithAudio, destination: muted)
            results["muteExport"] = try await !VideoInformation.load(muted).hasAudio
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
            library.edit(edited)
            results["editorPersistence"] = try library.disk.load().item(edited.id)?.videoEdit == edited.videoEdit
            VideoEditorWindow.open(wallpaper: edited, source: library.disk.url(for: edited)!, library: library)
            await pause(0.7)
            if let window = NSApp.windows.first(where: { $0.title == "Edit — " + edited.title }), let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let destination = out.appendingPathComponent("Flua-editor.png")
                try bitmap.representation(using: .png, properties: [:])?.write(to: destination)
                capture(window, to: destination)
                results["editorWindow"] = true
                window.close()
            }
            for kind in ["image", "aurora", "cosmos", "ocean", "ember"] {
                let w = kind == "image" ? images[0] : library.state.wallpapers.first { $0.kind == kind }!
                surface.configure(w, url: library.disk.url(for: w))
                await pause(0.15)
                results["render_" + kind] = surface.subviews.count > 0 || (surface.layer?.sublayers?.count ?? 0) > 0
            }
            surface.cleanup()
            testWindow.close()
            if let screen = NSScreen.screens.first {
                let baseline = NSWorkspace.shared.desktopImageURL(for: screen)
                library.engine.pauseOnFullscreen = false
                library.engine.apply(video, url: library.disk.url(for: video), to: screen)
                await pause(0.3)
                let diagnostics = library.engine.windowDiagnostics
                results["desktopWindow"] = diagnostics
                results["desktopWindowVisible"] = diagnostics.first?["visible"] as? Bool == true
                results["desktopIgnoresMouse"] = diagnostics.first?["ignoresMouseEvents"] as? Bool == true
                library.engine.stopAll()
                results["desktopCleanup"] = library.engine.activeCount == 0
                results["systemWallpaperPreserved"] = NSWorkspace.shared.desktopImageURL(for: screen) == baseline
            }
            library.selection = video.id
            await pause(0.3)
            results["inspectorVideoInteraction"] = await verifyInspectorInteraction(library: library)
            results["libraryApply"] = library.state.displays.values.allSatisfy { $0.desktop.wallpaperID == video.id } && library.engine.activeCount == NSScreen.screens.count
            library.startPlaylist("ambient")
            results["playlistStart"] = library.state.displays.values.allSatisfy { $0.desktop.wallpaperID == "aurora" && $0.desktop.playlistID == "ambient" }
            library.advancePlaylists(force: true)
            results["playlistNext"] = library.state.displays.values.allSatisfy { $0.desktop.wallpaperID == "ocean" }
            library.stop()
            results["libraryStop"] = library.state.displays.isEmpty && library.engine.activeCount == 0
            if let screen = library.screens.first {
                let key = displayID(screen)
                library.state.setMode(.still, display: key, surface: .desktop)
                library.selection = "aurora"
                library.applySelected()
                let sceneStamp = stillStamp(for: library.state.item("aurora")!)
                results["sceneStillRetained"] = library.engine.activeCount == library.screens.count && library.engine.windowDiagnostics.allSatisfy { ($0["still"] as? Bool) == true && ($0["stillImage"] as? Bool) == true && ($0["rate"] as? Double) == 0 && $0["wallpaper"] as? String == "aurora" }
                    && library.disk.retainedStill(id: "aurora", stamp: sceneStamp) != nil
                library.selection = video.id
                let sourceURL = library.disk.url(for: video)!
                let sourceBefore = try Data(contentsOf: sourceURL)
                library.applySelected()
                var desktopStill = false
                for _ in 0..<50 {
                    await pause(0.1)
                    desktopStill = library.engine.activeCount == library.screens.count && library.engine.windowDiagnostics.allSatisfy { ($0["still"] as? Bool) == true && ($0["stillImage"] as? Bool) == true && ($0["rate"] as? Double) == 0 && $0["wallpaper"] as? String == video.id }
                    if desktopStill { break }
                }
                results["desktopStill"] = desktopStill
                library.togglePause()
                library.togglePause()
                results["desktopStillSurvivesPause"] = library.state.paused == false && library.state.displays[key]?.desktop.mode == .still
                    && library.engine.windowDiagnostics.allSatisfy { ($0["still"] as? Bool) == true && ($0["rate"] as? Double) == 0 }
                results["desktopStillPersisted"] = try library.disk.load().displays[key]?.desktop.mode == .still
                results["desktopStillPreservesSource"] = try Data(contentsOf: sourceURL) == sourceBefore
                library.stop()
                library.state.displays.removeAll()
                library.state.paused = false
                library.save()
                library.engine.stopAll()
            }
            if let screen = library.screens.first {
                let key = displayID(screen)
                library.state.assign("ember", display: key, surface: .lockScreen)
                library.state.setMode(.still, display: key, surface: .lockScreen)
                let lockScreen = library.state.displays[key]?.lockScreen
                library.selection = video.id
                library.applySelected()
                results["desktopApplyPreservesLockScreen"] = library.state.displays.values.allSatisfy {
                    $0.desktop.wallpaperID == video.id && $0.lockScreen == lockScreen
                }
                library.startPlaylist("ambient")
                library.advancePlaylists(force: true)
                results["desktopPlaylistPreservesLockScreen"] = library.state.displays.values.allSatisfy {
                    $0.desktop.wallpaperID == "ocean" && $0.lockScreen == lockScreen
                }
                library.stop()
                _ = library.restoreAssignments()
                results["desktopStopPreservesLockScreen"] = library.engine.activeCount == 0
                    && library.state.displays.values.allSatisfy { $0.desktop.wallpaperID == nil && $0.lockScreen == lockScreen }
                let persisted = try library.disk.load()
                results["surfaceAssignmentsPersisted"] = persisted.displays == library.state.displays
                library.state.displays.removeAll()
                library.save()
            }
            if let screen = library.screens.first {
                let key = displayID(screen)
                library.selection = "aurora"
                library.applySelected()
                library.surface = .lockScreen
                library.selection = "ember"
                library.saveSelectedSurface()
                library.setSurfaceMode(.still)
                results["surfaceControlsIndependent"] = library.state.displays[key]?.desktop.wallpaperID == "aurora"
                    && library.state.displays[key]?.lockScreen?.wallpaperID == "ember"
                    && library.state.displays[key]?.lockScreen?.mode == .still
                library.setSurfacesLinked(true)
                results["surfaceControlsLinkCopiesDesktop"] = library.surfacesLinked
                    && library.state.displays[key]?.lockScreen == library.state.displays[key]?.desktop
                library.setSurfaceMode(.still)
                results["surfaceControlsLinkedMode"] = library.state.displays[key]?.desktop.mode == .still
                    && library.engine.windowDiagnostics.allSatisfy { $0["still"] as? Bool == true }
                library.setSurfacesLinked(false)
                library.setSurfaceMode(.animated)
                results["surfaceControlsUnlinkPreservesDesktop"] = library.state.displays[key]?.desktop.mode == .still
                    && library.state.displays[key]?.lockScreen?.mode == .animated
                    && !library.surfacesLinked
                results["surfaceControlsPersisted"] = try library.disk.load().displays == library.state.displays
                library.surface = .desktop
                library.engine.stopAll()
                library.state.displays.removeAll()
                library.save()
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
            results["clickableTag"] = library.section == "browse" && library.visible.contains { $0.id == edited.id } && library.filter.tags == ["portable"]
            library.filter.colors = ["Purple"]
            results["combinedBrowsing"] = library.visible.count == 2
            library.selection = edited.id
            await pause(0.3)
            if let window = NSApp.windows.first(where: { $0.title == "Flua" }) {
                captureView(window, to: out.appendingPathComponent("Flua-filters.png"))
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
            let settings = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 530, height: 760), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            settings.isReleasedWhenClosed = false
            settings.title = "Flua Settings Verification"
            settings.contentView = NSHostingView(rootView: SettingsView().environmentObject(library).preferredColorScheme(.dark))
            settings.orderFront(nil)
            await pause(0.3)
            captureView(settings, to: out.appendingPathComponent("Flua-settings.png"))
            if let mainWindow = NSApp.windows.first(where: { $0.title == "Flua" }) {
                captureView(mainWindow, to: out.appendingPathComponent("Flua-library-system.png"))
            }
            results["systemAccentDefault"] = library.state.accentColor == nil && library.accent == AppAccent.system.color && library.accentOverride == nil
            library.state.accentColor = AppAccent.purple.rawValue
            library.save()
            let savedAccent = try library.disk.load().accentColor
            results["accentSelection"] = savedAccent == "Purple" && library.accent == AppAccent.purple.color && library.accentOverride == AppAccent.purple.color
            await pause(0.3)
            captureView(settings, to: out.appendingPathComponent("Flua-settings-purple.png"))
            if let mainWindow = NSApp.windows.first(where: { $0.title == "Flua" }) {
                captureView(mainWindow, to: out.appendingPathComponent("Flua-library-purple.png"))
            }
            library.state.accentColor = AppAccent.system.rawValue
            results["explicitSystemAccent"] = library.accentOverride == nil
            library.state.accentColor = "Unknown future color"
            results["unknownAccentFallback"] = library.accent == AppAccent.system.color && library.accentOverride == nil
            library.state.accentColor = nil
            library.save()
            results["systemAccentReset"] = try library.disk.load().accentColor == nil
            settings.close()
            library.unblockTag("example")
            library.selection = "aurora"
            library.section = "discover"
            await pause(0.5)
            if let window = NSApp.windows.first(where: { $0.title == "Flua" }) {
                results["discoverWindow"] = true
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
            let required = ["inspectorSceneInteraction", "inspectorVideoInteraction", "explicitSystemAccent", "systemAccentDefault", "accentSelection", "unknownAccentFallback", "systemAccentReset", "importFacts", "rotatedFacts", "missingFacts", "legacyBackfill", "staleEditPreservesFacts", "unknownColorBackfill", "unknownColorRoundTrip", "blockedDiscover", "clickableTag", "combinedBrowsing", "clearFiltersPreservesBlockedTags", "clearFilters", "imageImport", "videoImport", "videoReady", "videoPlaying", "videoLooped", "videoPaused", "videoResumed", "liveAdjustmentPreservesTime", "liveAdjustmentSpeed", "stillHeld", "stillIgnoresResume", "stillPreservesSource", "sceneStillRetained", "desktopStill", "desktopStillSurvivesPause", "desktopStillPersisted", "desktopStillPreservesSource", "render_image", "render_aurora", "render_cosmos", "render_ocean", "render_ember", "desktopWindowVisible", "desktopIgnoresMouse", "desktopCleanup", "systemWallpaperPreserved", "libraryApply", "playlistStart", "playlistNext", "libraryStop", "libraryRoundTrip", "discoverWindow", "windowSnapshot", "videoInformation", "trimmedPlayback", "trimmedExport", "thumbnailExport", "rejectInvalidTrim", "preserveSourceOnExport", "packageRoundTrip", "editorPersistence", "editorWindow", "audioExport", "muteExport"]
            for key in required where results[key] as? Bool != true { failures.append(key) }
            for (key, value) in results where key.hasPrefix("surfaceControls") && value as? Bool != true { failures.append(key) }
        } catch { failures.append(String(reflecting: error)) }
        results["failures"] = failures
        results["passed"] = failures.isEmpty
        if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: out.appendingPathComponent("smoke-results.json")) }
        NSApp.terminate(nil)
    }
    @MainActor private static func verifyInspectorInteraction(library: Library) async -> Bool {
        guard let window = NSApp.windows.first(where: { $0.title == "Flua" }),
              let root = window.contentView, let parent = root.superview,
              let selected = library.selected else { return false }
        var controls: [NSControl] = []
        func collect(_ view: NSView) {
            if let control = view as? NSControl,
               root.convert(control.bounds, from: control).minX > root.bounds.maxX - 360 {
                controls.append(control)
            }
            for child in view.subviews { collect(child) }
        }
        collect(root)
        // The link checkbox precedes the desktop Play button.
        guard let button = controls.compactMap({ $0 as? NSButton }).dropFirst().first,
              let slider = controls.compactMap({ $0 as? NSSlider }).first else { return false }
        // Accessibility actions bypass the mouse routing that broke in the native inspector.
        for control in [button as NSControl, slider as NSControl] {
            control.scrollToVisible(control.bounds)
            await pause(0.1)
            let center = NSPoint(x: control.bounds.midX, y: control.bounds.midY)
            guard let hit = root.hitTest(parent.convert(center, from: control)),
                  hit === control || hit.isDescendant(of: control) else { return false }
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
        await pause(0.1)
        return library.engine.activeCount == library.screens.count && !library.state.displays.isEmpty
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
        let activeCount = library.engine.activeCount
        libraryWindows().first?.close()
        await pause(0.3)
        let libraryWasClosed = libraryWindows().isEmpty
        try reopen()
        await pause(0.5)
        results["reopenClosedLibraryWithWallpaper"] = libraryWasClosed && libraryWindows().count == 1 && activeCount > 0
            && library.engine.activeCount == activeCount
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
        guard CGPreflightScreenCaptureAccess() else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
        try? task.run()
        task.waitUntilExit()
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
    static func makeVideo(_ url: URL, transform: CGAffineTransform = .identity) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360])
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360, kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? LibraryError.unreadableMedia("writer") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<24 {
            let deadline = Date().addingTimeInterval(10)
            while !input.isReadyForMoreMediaData && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
            guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { throw LibraryError.unreadableMedia("video encoder") }
            var maybeBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &maybeBuffer)
            guard let buffer = maybeBuffer else { throw LibraryError.unreadableMedia("pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let c = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
                c.setFillColor(CGColor(red: 0.03, green: 0.10, blue: 0.17, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
                c.setFillColor(CGColor(red: 0.45, green: 0.8, blue: 0.68, alpha: 1)); c.fillEllipse(in: CGRect(x: 20 + frame * 20, y: 130, width: 80, height: 80))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 24)) else { throw writer.error ?? LibraryError.unreadableMedia("video frame") }
        }
        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        guard semaphore.wait(timeout: .now() + 15) == .success, writer.status == .completed else { throw writer.error ?? LibraryError.unreadableMedia("video finalize") }
    }
}
