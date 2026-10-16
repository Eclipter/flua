import AppKit
import AVFoundation
import QuartzCore
import IOKit.ps

final class WallpaperWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class MediaSurface: NSView {
    private var queue: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var videoLayer: AVPlayerLayer?
    private var sceneView: AmbientSceneView?
    private var imageLayer: CALayer?
    private var shade = CALayer()
    private var desiredRate: Float = 1
    private var readyObservation: NSKeyValueObservation?
    private var isPaused = false
    private var currentWallpaper: Wallpaper?
    private var currentURL: URL?
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
    func configure(_ wallpaper: Wallpaper, url: URL?, autoplay: Bool = true) {
        cleanup()
        currentWallpaper = wallpaper
        currentURL = url
        isPaused = !autoplay
        desiredRate = Float(wallpaper.speed)
        if wallpaper.kind == "video", let url {
            let asset = AVURLAsset(url: url)
            let item = AVPlayerItem(asset: asset)
            let player = AVQueuePlayer()
            player.isMuted = wallpaper.volume == 0
            player.volume = Float(wallpaper.volume)
            player.automaticallyWaitsToMinimizeStalling = true
            queue = player
            if let edit = wallpaper.videoEdit, let end = edit.end, end > edit.start, edit.start >= 0 {
                looper = AVPlayerLooper(player: player, templateItem: item, timeRange: CMTimeRange(start: CMTime(seconds: edit.start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600)))
            } else { looper = AVPlayerLooper(player: player, templateItem: item) }
            player.isMuted = wallpaper.volume == 0 || wallpaper.videoEdit?.includeAudio == false
            let vl = AVPlayerLayer(player: player)
            vl.videoGravity = wallpaper.fit ? .resizeAspect : .resizeAspectFill
            layer?.addSublayer(vl)
            videoLayer = vl
            readyObservation = player.observe(\.currentItem?.status, options: [.new, .initial]) { [weak self] p, _ in
                DispatchQueue.main.async {
                    guard let self, self.queue === p else { return }
                    if p.currentItem?.status == .failed {
                        self.onError?(p.currentItem?.error?.localizedDescription ?? "Video playback failed.")
                    } else if p.currentItem?.status == .readyToPlay && !self.isPaused {
                        p.playImmediately(atRate: self.desiredRate)
                    }
                }
            }
            if autoplay { player.playImmediately(atRate: desiredRate) }
        } else if wallpaper.kind == "image", let url, let image = NSImage(contentsOf: url) {
            var rect = NSRect(origin: .zero, size: image.size)
            let il = CALayer()
            il.contents = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
            il.contentsGravity = wallpaper.fit ? .resizeAspect : .resizeAspectFill
            layer?.addSublayer(il)
            imageLayer = il
        } else if ["aurora", "cosmos", "ocean", "ember"].contains(wallpaper.kind) {
            let scene = AmbientSceneView(frame: bounds, scene: wallpaper.kind)
            scene.autoresizingMask = [.width, .height]
            scene.speed = wallpaper.speed
            scene.dimming = 0
            scene.isPaused = !autoplay
            addSubview(scene)
            sceneView = scene
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
    }
    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        if paused { queue?.pause() } else { queue?.playImmediately(atRate: desiredRate) }
        sceneView?.isPaused = paused
    }
    func updateParameters(_ w: Wallpaper) {
        if w.kind == "video", currentWallpaper?.videoEdit?.start != w.videoEdit?.start || currentWallpaper?.videoEdit?.end != w.videoEdit?.end {
            configure(w, url: currentURL, autoplay: !isPaused)
            return
        }
        currentWallpaper = w
        desiredRate = Float(w.speed)
        queue?.isMuted = w.volume == 0 || w.videoEdit?.includeAudio == false
        queue?.volume = Float(w.volume)
        if !isPaused, queue?.currentItem?.status == .readyToPlay { queue?.rate = desiredRate }
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
    }
    deinit { queue?.pause(); looper?.disableLooping() }
}

func displayID(_ screen: NSScreen) -> String {
    let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
        return CFUUIDCreateString(nil, uuid) as String
    }
    return String(id)
}

final class DesktopEngine {
    struct Slot { let window: WallpaperWindow; let surface: MediaSurface; var wallpaperID: String }
    private var slots: [String: Slot] = [:]
    var manuallyPaused = false
    var pauseOnBattery = false
    var pauseOnLowPower = false
    var pauseOnFullscreen = true
    var onError: ((String) -> Void)?
    private var sleeping = false
    private var locked = false
    private var observers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var timer: Timer?
    var activeCount: Int { slots.count }
    var activeKeys: [String] { Array(slots.keys) }
    var windowDiagnostics: [[String: Any]] {
        slots.map { key, slot in ["display": key, "visible": slot.window.isVisible, "ignoresMouseEvents": slot.window.ignoresMouseEvents, "level": slot.window.level.rawValue, "wallpaper": slot.wallpaperID] }
    }
    init() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.sleeping = true; self?.updatePowerState()
            })
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.sleeping = false; self?.updatePowerState()
            })
        }
        let dc = DistributedNotificationCenter.default()
        distributedObservers.append(dc.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.locked = true; self?.updatePowerState()
        })
        distributedObservers.append(dc.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.locked = false; self?.updatePowerState()
        })
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.updatePowerState() }
        RunLoop.main.add(timer!, forMode: .common)
    }
    func apply(_ wallpaper: Wallpaper, url: URL?, to screen: NSScreen) {
        let key = displayID(screen)
        stop(display: key)
        let window = WallpaperWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = "Flua Desktop"
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.backgroundColor = .black
        let surface = MediaSurface(frame: NSRect(origin: .zero, size: screen.frame.size))
        surface.onError = { [weak self] in self?.onError?($0) }
        window.contentView = surface
        surface.configure(wallpaper, url: url, autoplay: !(manuallyPaused || sleeping || locked))
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        slots[key] = Slot(window: window, surface: surface, wallpaperID: wallpaper.id)
        updatePowerState()
    }
    func stop(display: String) {
        guard let slot = slots.removeValue(forKey: display) else { return }
        slot.surface.cleanup()
        slot.window.orderOut(nil)
        slot.window.close()
    }
    func update(_ wallpaper: Wallpaper) {
        for slot in slots.values where slot.wallpaperID == wallpaper.id { slot.surface.updateParameters(wallpaper) }
    }
    func stopAll() { for key in Array(slots.keys) { stop(display: key) } }
    func updatePowerState() {
        let battery: Bool
        if pauseOnBattery, let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() {
            battery = (source as String) == kIOPSBatteryPowerValue
        } else { battery = false }
        let base = manuallyPaused || sleeping || locked || battery || (pauseOnLowPower && ProcessInfo.processInfo.isLowPowerModeEnabled)
        var covering = Set<String>()
        if pauseOnFullscreen && !base,
           let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for w in windows {
                guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                      let pid = w[kCGWindowOwnerPID as String] as? Int32, pid != getpid(),
                      let alpha = w[kCGWindowAlpha as String] as? Double, alpha > 0.9,
                      let b = w[kCGWindowBounds as String] as? [String: Any],
                      let rect = CGRect(dictionaryRepresentation: b as CFDictionary) else { continue }
                for screen in NSScreen.screens {
                    // CGWindow coordinates start at the top of the main display.
                    let top = NSScreen.screens.first?.frame.maxY ?? 0
                    let sf = CGRect(x: screen.frame.minX, y: top - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
                    let intersection = rect.intersection(sf)
                    if intersection.width >= sf.width * 0.98 && intersection.height >= sf.height * 0.98 {
                        covering.insert(displayID(screen))
                    }
                }
            }
        }
        for (key, slot) in slots { slot.surface.setPaused(base || covering.contains(key)) }
    }
    deinit {
        timer?.invalidate()
        for o in observers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        for o in distributedObservers { DistributedNotificationCenter.default().removeObserver(o) }
    }
}
