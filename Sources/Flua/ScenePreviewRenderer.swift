import AppKit
import Metal
import QuartzCore

final class ScenePreviewRenderer: NSObject {
    private final class Resources {
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

    private final class DisplayLinkContext {
        weak var renderer: ScenePreviewRenderer?

        @objc func displayLinkDidRefresh(_ _: CADisplayLink) {
            renderer?.scheduleFrame()
        }
    }

    private struct FrameState {
        let paused: Bool
        let speed: Double
        let dimming: Double
        let resetClock: Bool
    }

    private static let resources = Result { try Resources() }
    private let resources: Resources
    private let layer = CAMetalLayer()
    private let inFlight = DispatchSemaphore(value: 1)
    private let stateLock = NSLock()
    private let renderQueue = DispatchQueue(label: "Flua.ScenePreviewRenderer", qos: .userInteractive)
    private var displayLink: CADisplayLink?
    private var displayLinkContext: DisplayLinkContext?
    private var paused = true
    private var speed: Double = 1
    private var dimming: Double = 0
    private var resetClockPending = true
    private var elapsed: Double = 0
    private var previousFrameTime: CFTimeInterval?
    private var submittedFrames = 0
    private let kind: UInt32

    var frameCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return submittedFrames
    }

    init(view: NSView, scene: String) throws {
        resources = try Self.resources.get()
        kind = UInt32(["aurora", "cosmos", "ocean", "ember"].firstIndex(of: scene) ?? 0)
        super.init()

        layer.device = resources.device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.backgroundColor = NSColor.black.cgColor
        layer.displaySyncEnabled = true

        let context = DisplayLinkContext()
        context.renderer = self
        displayLinkContext = context
        let link = view.displayLink(target: context, selector: #selector(DisplayLinkContext.displayLinkDidRefresh(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        displayLink = link
        view.wantsLayer = true
        view.layer = layer
    }

    deinit {
        displayLink?.invalidate()
    }

    func resize(frame: CGRect, drawableSize: CGSize) {
        layer.frame = frame
        if layer.drawableSize != drawableSize { layer.drawableSize = drawableSize }
    }

    func setPaused(_ paused: Bool) {
        stateLock.lock()
        let changed = self.paused != paused
        self.paused = paused
        if changed { resetClockPending = true }
        stateLock.unlock()
        if changed { displayLink?.isPaused = paused }
    }

    func updateSpeed(_ speed: Double) {
        stateLock.lock()
        self.speed = speed
        stateLock.unlock()
    }

    func updateDimming(_ dimming: Double) {
        stateLock.lock()
        self.dimming = dimming
        stateLock.unlock()
    }

    private func takeFrameState() -> FrameState {
        stateLock.lock()
        defer { stateLock.unlock() }
        let state = FrameState(paused: paused, speed: speed, dimming: dimming, resetClock: resetClockPending)
        resetClockPending = false
        return state
    }

    private func scheduleFrame() {
        guard inFlight.wait(timeout: .now()) == .success else { return }
        let semaphore = inFlight
        renderQueue.async { [weak self, semaphore] in
            guard let self else { semaphore.signal(); return }
            self.drawFrame(semaphore: semaphore)
        }
    }

    private func drawFrame(semaphore: DispatchSemaphore) {
        let state = takeFrameState()
        guard !state.paused else {
            previousFrameTime = nil
            semaphore.signal()
            return
        }
        let now = CACurrentMediaTime()
        if state.resetClock { previousFrameTime = nil }
        guard let drawable = layer.nextDrawable(), let command = resources.queue.makeCommandBuffer() else {
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

        stateLock.lock()
        submittedFrames += 1
        stateLock.unlock()
    }
}
