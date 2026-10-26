import AppKit

/// A small, self-contained renderer for Flua's original procedural scenes.
final class AmbientSceneView: NSView {
    static let scenes: [(id: String, name: String, subtitle: String)] = [
        ("aurora", "Northern Lights", "Silk ribbons above a quiet alpine lake"),
        ("cosmos", "Deep Space", "A drifting nebula and a distant dark planet"),
        ("ocean", "Midnight Tide", "Luminous waves beneath a soft moon"),
        ("ember", "Ember Glow", "Warm currents and slowly rising sparks"),
        ("ink", "Ink Mountains", "Drifting mist and distant birds"),
        ("dunes", "Sahara", "Windblown grains and dust plumes"),
        ("contour", "Contour Atlas", "Streamlets trace the waterways"),
        ("opal", "Optical Current", "Ink blooms and flowing pigment trails")
    ]

    let scene: String
    var isPaused = false { didSet { updatePlayback() } }
    var speed: Double = 1 { didSet { renderer?.updateSpeed(speed) } }
    var dimming: Double = 0.12 {
        didSet { renderer?.updateDimming(dimming) }
    }
    var frameCount: Int { renderer?.frameCount ?? 0 }
    private(set) var previewError: String?
    private var renderer: ScenePreviewRenderer?

    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    init(frame: NSRect, scene: String) {
        self.scene = scene
        super.init(frame: frame)
        do {
            let renderer = try ScenePreviewRenderer(view: self, scene: scene)
            renderer.updateDimming(dimming)
            self.renderer = renderer
            updateDrawableSize()
        } catch {
            previewError = "Scene preview could not start: " + error.localizedDescription
            wantsLayer = true
            let image = Self.thumbnail(scene: scene, size: NSSize(width: 480, height: 300))
            layer?.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
    }

    required init?(coder: NSCoder) { fatalError() }
    isolated deinit {
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
        }
        renderer?.setPaused(true)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed { updateDrawableSize() }
    }
    private func updateDrawableSize() {
        // Keep animated scene shaders near the previous 480 x 300 pixel budget.
        let scale = min(1, min(1280 / max(max(bounds.width, bounds.height), 1), sqrt(144_000 / max(bounds.width * bounds.height, 1))))
        let size = CGSize(width: max(1, ceil(bounds.width * scale)), height: max(1, ceil(bounds.height * scale)))
        renderer?.resize(frame: bounds, drawableSize: size)
    }

    private var occlusionObserver: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePlayback() }
            }
        }
        updatePlayback()
    }
    override func viewDidHide() {
        super.viewDidHide()
        updatePlayback()
    }
    override func viewDidUnhide() {
        super.viewDidUnhide()
        updatePlayback()
    }
    private func updatePlayback() {
        let paused = isPaused || isHiddenOrHasHiddenAncestor || window?.occlusionState.contains(.visible) != true
        renderer?.setPaused(paused)
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
