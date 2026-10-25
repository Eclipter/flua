import AppKit
import AVFoundation
import QuartzCore

final class MediaSurface: NSView {
    private var queue: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var videoLayer: AVPlayerLayer?
    private var sceneView: AmbientSceneView?
    private var imageLayer: CALayer?
    private var desiredRate: Float = 1
    private var readyObservation: NSKeyValueObservation?
    private var isPaused = false
    private var playbackSuspended = true
    private var visibilityObservers: [NSObjectProtocol] = []
    private(set) var holdsStill = false
    private(set) var showsStillImage = false
    private var currentWallpaper: Wallpaper?
    private var currentURL: URL?
    var sceneIsPaused: Bool { sceneView?.isPaused ?? true }
    var sceneFrameCount: Int { sceneView?.frameCount ?? 0 }
    var playbackTime: Double { queue?.currentTime().seconds ?? 0 }
    var playbackRate: Float { queue?.rate ?? 0 }
    var mediaReady: Bool { queue?.currentItem?.status == .readyToPlay }
    var onError: ((String) -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        visibilityObservers.forEach { NotificationCenter.default.removeObserver($0) }
        visibilityObservers.removeAll()
        if let window {
            visibilityObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.updatePlaybackState() } })
            if let clip = enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                visibilityObservers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                    object: clip, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.updatePlaybackState() } })
            }
        }
        updatePlaybackState()
    }
    override func viewDidHide() { super.viewDidHide(); updatePlaybackState() }
    override func viewDidUnhide() { super.viewDidUnhide(); updatePlaybackState() }
    private func updatePlaybackState(force: Bool = false) {
        let suspended = isPaused || holdsStill || isHiddenOrHasHiddenAncestor || visibleRect.isEmpty
            || window?.occlusionState.contains(.visible) != true
        guard force || suspended != playbackSuspended else { return }
        playbackSuspended = suspended
        if suspended { queue?.pause() }
        else if queue?.currentItem?.status == .readyToPlay { queue?.playImmediately(atRate: desiredRate) }
        sceneView?.isPaused = suspended
    }
    func configure(_ wallpaper: Wallpaper, url: URL?, autoplay: Bool = true, mode: WallpaperMode = .animated, stillImage: NSImage? = nil) {
        cleanup()
        currentWallpaper = wallpaper
        currentURL = url
        holdsStill = mode == .still
        isPaused = holdsStill || !autoplay
        desiredRate = Float(wallpaper.speed)
        if holdsStill {
            if let stillImage { addImage(stillImage, fit: wallpaper.fit) }
            else if wallpaper.kind == "image", let url, let image = NSImage(contentsOf: url) { addImage(image, fit: wallpaper.fit) }
        } else if wallpaper.kind == "video", let url {
            let asset = AVURLAsset(url: url)
            let item = AVPlayerItem(asset: asset)
            let player = AVQueuePlayer()
            player.isMuted = true
            player.automaticallyWaitsToMinimizeStalling = true
            queue = player
            if let edit = wallpaper.videoEdit, let end = edit.end, end > edit.start, edit.start >= 0 {
                looper = AVPlayerLooper(player: player, templateItem: item, timeRange: CMTimeRange(start: CMTime(seconds: edit.start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600)))
            } else { looper = AVPlayerLooper(player: player, templateItem: item) }
            let vl = AVPlayerLayer(player: player)
            vl.videoGravity = wallpaper.fit ? .resizeAspect : .resizeAspectFill
            layer?.addSublayer(vl)
            videoLayer = vl
            readyObservation = player.observe(\.currentItem?.status, options: [.new, .initial]) { [weak self] p, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.queue === p else { return }
                    if p.currentItem?.status == .failed {
                        self.onError?(p.currentItem?.error?.localizedDescription ?? "Video playback failed.")
                    } else if p.currentItem?.status == .readyToPlay && !self.playbackSuspended {
                        p.playImmediately(atRate: self.desiredRate)
                    }
                }
            }
        } else if wallpaper.kind == "image", let url, let image = NSImage(contentsOf: url) {
            addImage(image, fit: wallpaper.fit)
        } else if ["aurora", "cosmos", "ocean", "ember"].contains(wallpaper.kind) {
            let scene = AmbientSceneView(frame: bounds, scene: wallpaper.kind)
            scene.autoresizingMask = [.width, .height]
            scene.speed = wallpaper.speed
            scene.dimming = 0
            scene.isPaused = true
            addSubview(scene)
            sceneView = scene
            if let error = scene.previewError { onError?(error) }
        } else {
            onError?("The wallpaper's media file is missing or unsupported.")
        }
        // A sibling overlay stays above both layer-based video and NSView scenes.
        let overlay = NSView(frame: bounds)
        overlay.identifier = NSUserInterfaceItemIdentifier("shade")
        overlay.autoresizingMask = [.width, .height]
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(wallpaper.dimming).cgColor
        addSubview(overlay)
        needsLayout = true
        updatePlaybackState(force: true)
    }
    func setPaused(_ paused: Bool) {
        guard !holdsStill, paused != isPaused else { return }
        isPaused = paused
        updatePlaybackState()
    }
    func useStill(_ image: NSImage) {
        guard holdsStill, let wallpaper = currentWallpaper else { return }
        imageLayer?.removeFromSuperlayer()
        addImage(image, fit: wallpaper.fit)
        needsLayout = true
    }
    func updateParameters(_ w: Wallpaper) {
        if holdsStill {
            currentWallpaper = w
            imageLayer?.contentsGravity = w.fit ? .resizeAspect : .resizeAspectFill
            subviews.first { $0.identifier?.rawValue == "shade" }?.layer?.backgroundColor = NSColor.black.withAlphaComponent(w.dimming).cgColor
            return
        }
        if w.kind == "video", currentWallpaper?.videoEdit?.start != w.videoEdit?.start || currentWallpaper?.videoEdit?.end != w.videoEdit?.end {
            configure(w, url: currentURL, autoplay: !isPaused)
            return
        }
        currentWallpaper = w
        desiredRate = Float(w.speed)
        queue?.isMuted = true
        if !playbackSuspended, queue?.currentItem?.status == .readyToPlay { queue?.rate = desiredRate }
        videoLayer?.videoGravity = w.fit ? .resizeAspect : .resizeAspectFill
        imageLayer?.contentsGravity = w.fit ? .resizeAspect : .resizeAspectFill
        sceneView?.speed = w.speed
        subviews.first { $0.identifier?.rawValue == "shade" }?.layer?.backgroundColor = NSColor.black.withAlphaComponent(w.dimming).cgColor
    }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer?.frame = bounds
        imageLayer?.frame = bounds
        CATransaction.commit()
        updatePlaybackState()
    }
    func cleanup() {
        readyObservation = nil
        queue?.pause()
        looper?.disableLooping()
        queue?.removeAllItems()
        queue = nil
        looper = nil
        videoLayer?.removeFromSuperlayer()
        videoLayer = nil
        imageLayer?.removeFromSuperlayer()
        imageLayer = nil
        sceneView?.isPaused = true
        subviews.forEach { $0.removeFromSuperview() }
        sceneView = nil
        holdsStill = false
        showsStillImage = false
    }
    private func addImage(_ image: NSImage, fit: Bool) {
        var rect = NSRect(origin: .zero, size: image.size)
        let il = CALayer()
        il.contents = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) ?? NSBitmapImageRep(data: image.tiffRepresentation ?? Data())?.cgImage
        il.contentsGravity = fit ? .resizeAspect : .resizeAspectFill
        layer?.addSublayer(il)
        imageLayer = il
        if holdsStill { showsStillImage = il.contents != nil }
    }
    isolated deinit {
        visibilityObservers.forEach { NotificationCenter.default.removeObserver($0) }
        queue?.pause()
        looper?.disableLooping()
    }
}

func displayID(_ screen: NSScreen) -> String {
    let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
        return CFUUIDCreateString(nil, uuid) as String
    }
    return String(id)
}
