import AppKit
import QuartzCore

/// A small, self-contained renderer for Flua's original procedural scenes.
final class AmbientSceneView: NSView {
    static let scenes: [(id: String, name: String, subtitle: String)] = [
        ("aurora", "Northern Lights", "Silk ribbons above a quiet alpine lake"),
        ("cosmos", "Deep Space", "A drifting nebula and a distant dark planet"),
        ("ocean", "Midnight Tide", "Luminous waves beneath a soft moon"),
        ("ember", "Ember Glow", "Warm currents and slowly rising sparks")
    ]

    let scene: String
    var isPaused = false { didSet { updateTimer() } }
    var speed: Double = 1
    var dimming: Double = 0.12 { didSet { needsDisplay = true } }
    private var timer: Timer?
    private var lastTick: CFTimeInterval = CACurrentMediaTime()
    private var elapsed: Double = 0
    private var renderContext: CGContext?

    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    init(frame: NSRect, scene: String) {
        self.scene = scene
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) {
        scene = "aurora"
        super.init(coder: coder)
    }

    deinit { timer?.invalidate() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTimer()
    }

    private func updateTimer() {
        timer?.invalidate()
        timer = nil
        lastTick = CACurrentMediaTime()
        guard !isPaused, window != nil else { return }
        let newTimer = Timer(timeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = CACurrentMediaTime()
            // Cap long gaps after sleep or a busy run loop; do not jump through a scene.
            let delta = min(max(now - self.lastTick, 0), 0.1)
            self.lastTick = now
            let rate = self.speed.isFinite ? min(max(self.speed, 0), 4) : 1
            self.elapsed += delta * rate
            self.needsDisplay = true
        }
        newTimer.tolerance = 0.006
        timer = newTimer
        RunLoop.main.add(newTimer, forMode: .common)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // Gradients remain smooth when scaled. Bound the animation surface to 1280
        // pixels so a Retina or external 5K display does not multiply drawing work.
        let scale = min(1, 1280 / max(max(bounds.width, bounds.height), 1))
        let width = max(1, Int(ceil(bounds.width * scale)))
        let height = max(1, Int(ceil(bounds.height * scale)))
        if renderContext?.width != width || renderContext?.height != height {
            renderContext = CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        if let canvas = renderContext {
            SceneDrawing.render(scene: scene, time: elapsed, dimming: dimming, in: canvas,
                bounds: CGRect(x: 0, y: 0, width: width, height: height))
            if let frame = canvas.makeImage() {
                context.interpolationQuality = .high
                context.draw(frame, in: bounds)
            }
        } else {
            SceneDrawing.render(scene: scene, time: elapsed, dimming: dimming, in: context, bounds: bounds)
        }
    }

    static func thumbnail(scene: String, size: NSSize) -> NSImage {
        let safeSize = NSSize(width: max(1, size.width), height: max(1, size.height))
        return NSImage(size: safeSize, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            SceneDrawing.render(scene: scene, time: 7, dimming: 0.02, in: context, bounds: rect)
            return true
        }
    }

}
