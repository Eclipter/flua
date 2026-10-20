import SwiftUI
import AppKit
import AVKit
import AVFoundation
import Combine
import CoreImage

struct VideoInformation {
    let duration: Double
    let width: Int
    let height: Int
    let fps: Double
    let bitrate: Double
    let bytes: Int64
    let hasAudio: Bool
    static func load(_ url: URL) async throws -> VideoInformation {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, let track = try await asset.loadTracks(withMediaType: .video).first else { throw EditorFailure.invalidVideo }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        let fps = try await track.load(.nominalFrameRate)
        let bitrate = try await track.load(.estimatedDataRate)
        let hasAudio = try await !asset.loadTracks(withMediaType: .audio).isEmpty
        let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return VideoInformation(duration: duration, width: Int(abs(rect.width)), height: Int(abs(rect.height)), fps: Double(fps), bitrate: Double(bitrate), bytes: bytes, hasAudio: hasAudio)
    }
}

enum EditorFailure: LocalizedError {
    case invalidVideo, invalidRange, sourceDestination, unavailableExporter
    var errorDescription: String? {
        switch self {
        case .invalidVideo: return "This file has no playable video track."
        case .invalidRange: return "Choose a valid trim range of at least 0.1 seconds within the video."
        case .sourceDestination: return "Choose a different destination to preserve the source video."
        case .unavailableExporter: return "This video cannot be exported with the selected quality."
        }
    }
}

enum VideoTools {
    static func range(_ edit: VideoEdit, duration: Double, maximum: Double? = nil) throws -> CMTimeRange {
        let end = min(edit.end ?? duration, duration)
        guard edit.start.isFinite, end.isFinite, edit.start >= 0, end - edit.start >= 0.1, edit.start < duration else { throw EditorFailure.invalidRange }
        return CMTimeRange(start: CMTime(seconds: edit.start, preferredTimescale: 600), duration: CMTime(seconds: min(end - edit.start, maximum ?? duration), preferredTimescale: 600))
    }
    static func exporter(source: URL, edit: VideoEdit, preview: Bool = false) async throws -> AVAssetExportSession {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        let clip = try range(edit, duration: duration, maximum: preview ? 5 : nil)
        let composition = AVMutableComposition()
        for type in [AVMediaType.video, .audio] where type != .audio || edit.includeAudio {
            for sourceTrack in try await asset.loadTracks(withMediaType: type) {
                guard let track = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw EditorFailure.unavailableExporter }
                let available = try await sourceTrack.load(.timeRange)
                let included = CMTimeRangeGetIntersection(clip, otherRange: available)
                guard included.duration.seconds > 0 else { composition.removeTrack(track); continue }
                try track.insertTimeRange(included, of: sourceTrack, at: CMTimeSubtract(included.start, clip.start))
                if type == .video { track.preferredTransform = try await sourceTrack.load(.preferredTransform) }
            }
        }
        let preset: String
        switch edit.quality {
        case "small": preset = AVAssetExportPreset640x480
        case "medium": preset = AVAssetExportPreset1280x720
        case "1080": preset = AVAssetExportPreset1920x1080
        default: preset = AVAssetExportPresetHighestQuality
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: preset), session.supportedFileTypes.contains(.mp4) else { throw EditorFailure.unavailableExporter }
        session.shouldOptimizeForNetworkUse = true
        return session
    }
    static func thumbnail(source: URL, time: Double, size: CGSize = CGSize(width: 1920, height: 1200)) async throws -> Data {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = size
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let result = try await generator.image(at: CMTime(seconds: max(0, time), preferredTimescale: 600))
        guard let data = NSBitmapImageRep(cgImage: result.image).representation(using: .png, properties: [:]) else { throw EditorFailure.invalidVideo }
        return data
    }
    static func export(_ session: AVAssetExportSession, source: URL, destination: URL) async throws {
        guard source.resolvingSymlinksInPath().standardizedFileURL != destination.resolvingSymlinksInPath().standardizedFileURL else { throw EditorFailure.sourceDestination }
        // Write beside the destination first, so a cancelled export leaves existing files intact.
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".flua-" + UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: staging) }
        try await session.export(to: staging, as: .mp4)
        if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging) }
        else { try FileManager.default.moveItem(at: staging, to: destination) }
    }
}

@MainActor final class VideoEditorModel: ObservableObject {
    @Published var draft: Wallpaper
    @Published var info: VideoInformation?
    @Published var error: String?
    @Published var status = ""
    @Published var playhead: Double = 0
    let original: Wallpaper
    let source: URL
    let player: AVPlayer
    weak var library: Library?
    var window: NSWindow?
    private var observer: Any?
    private var closed = false
    init(wallpaper: Wallpaper, source: URL, library: Library) {
        draft = wallpaper; original = wallpaper; self.source = source; self.library = library
        player = AVPlayer(url: source)
        player.isMuted = true
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, time.seconds.isFinite else { return }
                self.playhead = time.seconds
                if let end = self.draft.videoEdit?.end, time.seconds >= end, self.player.rate > 0 {
                    self.player.seek(to: CMTime(seconds: self.draft.videoEdit?.start ?? 0, preferredTimescale: 600))
                }
            }
        }
        Task {
            do {
                let value = try await VideoInformation.load(source)
                guard !closed else { return }
                info = value
                if draft.videoEdit == nil { draft.videoEdit = VideoEdit(end: value.duration) }
                if draft.metadata == nil { draft.metadata = SceneMetadata() }
                let start = CMTime(seconds: draft.videoEdit?.start ?? 0, preferredTimescale: 600)
                let positioned = await player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
                if positioned && !closed { player.play() }
            } catch { self.error = error.localizedDescription }
        }
    }
    func seek(_ time: Double) { player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
    func save() {
        guard let info, let edit = draft.videoEdit else { return }
        do {
            _ = try VideoTools.range(edit, duration: info.duration)
            draft.videoEdit?.end = min(edit.end ?? info.duration, info.duration)
            guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "Enter a wallpaper name."; return }
            error = nil
            library?.edit(draft)
            library?.generateThumbnail(draft)
            status = "Saved to your library. The original video is preserved."
        } catch { self.error = error.localizedDescription }
    }
    func close() { closed = true; player.pause(); if let observer { player.removeTimeObserver(observer); self.observer = nil }; window = nil }
}

struct EditorPlayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> EditorFrameView { EditorFrameView(player: player) }
    func updateNSView(_ view: EditorFrameView, context: Context) {}
    static func dismantleNSView(_ view: EditorFrameView, coordinator: ()) { view.cleanup() }
}

final class EditorFrameView: NSView {
    let player: AVPlayer
    private let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var timer: Timer?
    private weak var item: AVPlayerItem?
    private var transform = CGAffineTransform.identity
    init(player: AVPlayer) {
        self.player = player
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        item = player.currentItem
        item?.add(output)
        Task { @MainActor [weak self, weak player] in
            if let asset = player?.currentItem?.asset, let track = try? await asset.loadTracks(withMediaType: .video).first,
               let transform = try? await track.load(.preferredTransform) { self?.transform = transform }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 24, repeats: true) { [weak self] _ in self?.drawFrame() }
        RunLoop.main.add(timer!, forMode: .common)
    }
    required init?(coder: NSCoder) { fatalError() }
    private func drawFrame() {
        let time = player.currentTime()
        guard output.hasNewPixelBuffer(forItemTime: time), let pixels = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
        let image = CIImage(cvPixelBuffer: pixels).transformed(by: transform)
        guard let frame = imageContext.createCGImage(image, from: image.extent) else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.contents = frame
        CATransaction.commit()
    }
    func cleanup() { timer?.invalidate(); timer = nil; item?.remove(output); item = nil }
    deinit { timer?.invalidate() }
}

struct VideoEditorView: View {
    @EnvironmentObject var library: Library
    @ObservedObject var model: VideoEditorModel
    private func editBinding<T>(_ key: WritableKeyPath<VideoEdit,T>, fallback: T) -> Binding<T> {
        Binding(get: { model.draft.videoEdit?[keyPath: key] ?? fallback }, set: { value in var e = model.draft.videoEdit ?? VideoEdit(end: model.info?.duration); e[keyPath: key] = value; model.draft.videoEdit = e })
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text(model.draft.title).font(.system(size: 28, weight: .bold, design: .serif)).lineLimit(1)
                EditorPlayer(player: model.player).aspectRatio(16/10, contentMode: .fit).background(.black).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                HStack {
                    fluaGlassRow {
                        Button { model.player.play() } label: { Label("Play", systemImage: "play.fill") }.fluaGlassButton()
                        Button { model.player.pause() } label: { Label("Pause", systemImage: "pause.fill") }.fluaGlassButton()
                    }
                    Spacer()
                    Text("Preview audio is muted").font(.caption).foregroundStyle(.secondary)
                }
                if let info = model.info {
                    Text("\(info.width) × \(info.height)  ·  \(String(format: "%.2f", info.fps)) fps  ·  \(String(format: "%.1f", info.duration)) s  ·  \(ByteCountFormatter.string(fromByteCount: info.bytes, countStyle: .file))  ·  \(String(format: "%.1f", info.bitrate / 1_000_000)) Mbps").font(.caption).foregroundStyle(.secondary)
                    HStack { Text("Position"); Slider(value: Binding(get: { model.playhead }, set: { model.playhead = $0; model.seek($0) }), in: 0...info.duration).tint(library.accent); Text(String(format: "%.2f s", model.playhead)).monospacedDigit().frame(width: 75) }.font(.caption)
                    HStack {
                        Button("Set trim start here") { var e = model.draft.videoEdit ?? VideoEdit(end: info.duration); e.start = min(model.playhead, (e.end ?? info.duration) - 0.1); model.draft.videoEdit = e }
                        Button("Set trim end here") { var e = model.draft.videoEdit ?? VideoEdit(end: info.duration); e.end = max(model.playhead, e.start + 0.1); model.draft.videoEdit = e }
                        Button("Use as cover") { model.draft.videoEdit?.thumbnail = model.playhead }
                    }.font(.caption)
                    HStack {
                        Text("Start"); TextField("Start", value: editBinding(\.start, fallback: 0), format: .number.precision(.fractionLength(2))).frame(width: 75)
                        Text("End"); TextField("End", value: Binding(get: { model.draft.videoEdit?.end ?? info.duration }, set: { model.draft.videoEdit?.end = $0 }), format: .number.precision(.fractionLength(2))).frame(width: 75)
                        Spacer(); Text("Cover \(String(format: "%.2f", model.draft.videoEdit?.thumbnail ?? 0)) s").foregroundStyle(.secondary)
                    }.font(.caption).textFieldStyle(FluaGlassTextFieldStyle())
                } else { ProgressView("Reading video…") }
                Spacer(minLength: 0)
                if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                if !model.status.isEmpty { Text(model.status).font(.caption).foregroundStyle(.secondary) }
            }.padding(24).frame(minWidth: 580, maxWidth: .infinity)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                Text("Trim and Cover").font(.headline)
                Text("Choose a trim range and cover in the preview. Your source video is preserved.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.window?.close() }.fluaGlassButton()
                Button("Save Changes") { model.save(); if model.error == nil { model.window?.close() } }
                    .disabled(model.info == nil).fluaProminentButton()
            }.padding(24).frame(width: 240)
        }.frame(minWidth: 980, minHeight: 650).fluaBackdrop(accent: library.accent)
            .fluaClearInitialFocus()
            .toggleStyle(.switch)
            .buttonStyle(FluaGlassButtonStyle())
            .textFieldStyle(FluaGlassTextFieldStyle())
    }
}

@MainActor final class VideoEditorWindow: NSObject, NSWindowDelegate {
    let model: VideoEditorModel
    let window: NSWindow
    private static var openEditors: [String: VideoEditorWindow] = [:]
    static func open(wallpaper: Wallpaper, source: URL, library: Library) {
        if let editor = openEditors[wallpaper.id] { editor.window.makeKeyAndOrderFront(nil); return }
        let editor = VideoEditorWindow(wallpaper: wallpaper, source: source, library: library)
        openEditors[wallpaper.id] = editor
        editor.window.makeKeyAndOrderFront(nil)
    }
    init(wallpaper: Wallpaper, source: URL, library: Library) {
        model = VideoEditorModel(wallpaper: wallpaper, source: source, library: library)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 740), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Edit — " + wallpaper.title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: VideoEditorView(model: model).environmentObject(library))
        window.delegate = self
        window.center()
        model.window = window
    }
    func windowWillClose(_ notification: Notification) { model.close(); Self.openEditors.removeValue(forKey: model.original.id) }
}

extension Library {
    @MainActor func choosePackageExport(_ wallpaper: Wallpaper) {
        guard let source = disk.url(for: wallpaper) else { return }
        let panel = NSSavePanel()
        if wallpaper.kind == "image" {
            panel.nameFieldStringValue = wallpaper.title + "." + source.pathExtension
            panel.message = "Export a copy of this wallpaper image."
            panel.begin { [weak self] response in
                guard response == .OK, let destination = panel.url else { return }
                do { try FileManager.default.copyItem(at: source, to: destination) }
                catch { self?.error = error.localizedDescription }
            }
            return
        }
        panel.nameFieldStringValue = wallpaper.title + ".flua"
        panel.message = "Export a folder containing the edited video, a thumbnail and a portable wallpaper manifest."
        panel.begin { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            Task { @MainActor in
                guard let self else { return }
                do { try await Self.exportPackage(wallpaper, source: source, destination: destination); self.activity = "Exported \(destination.lastPathComponent)." }
                catch { self.error = error.localizedDescription }
            }
        }
    }
    static func exportPackage(_ wallpaper: Wallpaper, source: URL, destination: URL) async throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".flua-package-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        let duration = try await AVURLAsset(url: source).load(.duration).seconds
        let edit = wallpaper.videoEdit ?? VideoEdit(end: duration)
        let session = try await VideoTools.exporter(source: source, edit: edit)
        let video = staging.appendingPathComponent("asset.mp4")
        try await VideoTools.export(session, source: source, destination: video)
        let clip = try VideoTools.range(edit, duration: duration)
        // Exported video starts at zero; map the source thumbnail to its new timeline.
        let thumbnailTime = min(max(0, edit.thumbnail - edit.start), max(0, clip.duration.seconds - 1.0 / 600))
        try await VideoTools.thumbnail(source: video, time: thumbnailTime).write(to: staging.appendingPathComponent("thumbnail.png"))
        let metadata = wallpaper.metadata ?? SceneMetadata()
        let manifest: [String: Any] = ["type": "video", "title": wallpaper.title, "details": metadata.details, "categoryIdentifier": metadata.category, "linkTitle": metadata.creditTitle, "linkURL": metadata.creditURL, "color": wallpaper.color, "motionIntensity": wallpaper.motion, "tags": normalizedTags(wallpaper.tags), "files": ["asset": "asset.mp4", "largeThumbnail": "thumbnail.png"], "thumbnailTimestamp": thumbnailTime, "duration": clip.duration.seconds, "createdBy": "Flua 1.2"]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: staging.appendingPathComponent("manifest.json"))
        try fm.moveItem(at: staging, to: destination)
    }
}
