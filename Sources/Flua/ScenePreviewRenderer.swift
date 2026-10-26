import AppKit
import Metal
import QuartzCore

// The SDK does not mark MTLBuffer Sendable; seeds are written only during construction.
private final class ScenePreviewResources: @unchecked Sendable {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let seeds: MTLBuffer

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let source = Bundle.module.url(forResource: "ScenePreview", withExtension: "metal") else {
            throw NativeWallpaperError("The graphics device for scene previews is unavailable.")
        }
        self.device = device
        self.queue = queue
        let library = try device.makeLibrary(source: String(contentsOf: source, encoding: .utf8), options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "sceneVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "sceneFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let noise = (0..<1024).map { Float(SceneDrawing.noise($0)) }
        guard let seeds = device.makeBuffer(bytes: noise, length: noise.count * MemoryLayout<Float>.stride) else {
            throw NativeWallpaperError("The graphics buffer for scene previews is unavailable.")
        }
        self.seeds = seeds
    }
}

private struct ScenePreviewFrameState: Sendable {
    let speed: Double
    let dimming: Double
    let resetClock: Bool
}

// Clock and drawable size are confined to renderQueue; short locks protect size handoff and frame counts.
private final class ScenePreviewWorker: @unchecked Sendable {
    private let layer = CAMetalLayer()
    private let resources: ScenePreviewResources
    private let inFlight = DispatchSemaphore(value: 1)
    private let sizeLock = NSLock()
    private var pendingDrawableSize: CGSize?
    private let countLock = NSLock()
    private let renderQueue = DispatchQueue(label: "Flua.ScenePreviewRenderer", qos: .userInteractive)
    private var elapsed: Double = 0
    private var previousFrameTime: CFTimeInterval?
    private var submittedFrames = 0
    private let kind: UInt32

    @MainActor init(resources: ScenePreviewResources, scene: String) {
        self.resources = resources
        kind = UInt32(["aurora", "cosmos", "ocean", "ember", "ink", "dunes", "contour", "opal"].firstIndex(of: scene) ?? 0)
        layer.device = resources.device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.backgroundColor = NSColor.black.cgColor
        layer.displaySyncEnabled = true
    }

    @MainActor var presentationLayer: CAMetalLayer { layer }

    var frameCount: Int {
        countLock.lock()
        defer { countLock.unlock() }
        return submittedFrames
    }

    @MainActor func resize(frame: CGRect, drawableSize: CGSize) {
        // Core Animation owns presentation synchronization; view geometry stays on the main actor.
        layer.frame = frame
        sizeLock.lock()
        pendingDrawableSize = drawableSize
        sizeLock.unlock()
    }

    @MainActor func submit(_ state: ScenePreviewFrameState) -> Bool {
        guard inFlight.wait(timeout: .now()) == .success else { return false }
        renderQueue.async { [self] in
            drawFrame(state: state, semaphore: inFlight)
        }
        return true
    }

    private func drawFrame(state: ScenePreviewFrameState, semaphore: DispatchSemaphore) {
        dispatchPrecondition(condition: .onQueue(renderQueue))
        let now = CACurrentMediaTime()
        if state.resetClock { previousFrameTime = nil }
        sizeLock.lock()
        let drawableSize = pendingDrawableSize
        pendingDrawableSize = nil
        sizeLock.unlock()
        if let drawableSize, layer.drawableSize != drawableSize { layer.drawableSize = drawableSize }
        let drawable = layer.nextDrawable()
        guard let drawable, let command = resources.queue.makeCommandBuffer() else {
            semaphore.signal()
            return
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            semaphore.signal()
            return
        }

        if let previousFrameTime {
            elapsed += min(max(now - previousFrameTime, 0), 0.1) * (state.speed.isFinite ? min(max(state.speed, 0), 4) : 1)
        }
        var uniforms = SIMD4<Float>(Float(drawable.texture.width), Float(drawable.texture.height), Float(elapsed), Float(kind))
        var shade = Float(state.dimming.isFinite ? min(max(state.dimming, 0), 0.9) : 0.12)
        encoder.setRenderPipelineState(resources.pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentBuffer(resources.seeds, offset: 0, index: 1)
        encoder.setFragmentBytes(&shade, length: MemoryLayout<Float>.stride, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        command.addCompletedHandler { _ in semaphore.signal() }
        command.present(drawable)
        command.commit()
        previousFrameTime = now

        countLock.lock()
        submittedFrames += 1
        countLock.unlock()
    }
}

@MainActor
final class ScenePreviewRenderer: NSObject {
    @MainActor private final class DisplayLinkContext {
        weak var renderer: ScenePreviewRenderer?

        @objc func displayLinkDidRefresh(_ _: CADisplayLink) {
            renderer?.scheduleFrame()
        }
    }

    private static let resources = Result { try ScenePreviewResources() }
    private let worker: ScenePreviewWorker
    private var displayLink: CADisplayLink?
    private var displayLinkContext: DisplayLinkContext?
    private var paused = true
    private var speed: Double = 1
    private var dimming: Double = 0
    private var resetClockPending = true

    var frameCount: Int { worker.frameCount }

    init(view: NSView, scene: String) throws {
        worker = ScenePreviewWorker(resources: try Self.resources.get(), scene: scene)
        super.init()
        let context = DisplayLinkContext()
        context.renderer = self
        displayLinkContext = context
        let link = view.displayLink(target: context, selector: #selector(DisplayLinkContext.displayLinkDidRefresh(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        displayLink = link
        view.wantsLayer = true
        view.layer = worker.presentationLayer
    }

    isolated deinit {
        displayLink?.invalidate()
    }

    func resize(frame: CGRect, drawableSize: CGSize) {
        worker.resize(frame: frame, drawableSize: drawableSize)
    }

    func setPaused(_ paused: Bool) {
        guard self.paused != paused else { return }
        self.paused = paused
        resetClockPending = true
        displayLink?.isPaused = paused
    }

    func updateSpeed(_ speed: Double) { self.speed = speed }

    func updateDimming(_ dimming: Double) { self.dimming = dimming }

    private func scheduleFrame() {
        guard !paused else { return }
        let state = ScenePreviewFrameState(speed: speed, dimming: dimming, resetClock: resetClockPending)
        if worker.submit(state) { resetClockPending = false }
    }
}
