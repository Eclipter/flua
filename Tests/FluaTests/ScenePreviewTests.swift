import CoreGraphics
import Foundation
import Metal

@main struct ScenePreviewTests {
    static func main() throws {
        let device = MTLCreateSystemDefaultDevice()!
        let library = try device.makeLibrary(source: String(contentsOfFile: "Sources/Flua/ScenePreview.metal", encoding: .utf8), options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "sceneVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "sceneFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let queue = device.makeCommandQueue()!
        let noise = (0..<1024).map { Float(SceneDrawing.noise($0)) }
        let seeds = device.makeBuffer(bytes: noise, length: noise.count * MemoryLayout<Float>.stride)!
        let size = 256, height = 160
        let specification = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size, height: height, mipmapped: false)
        specification.storageMode = .shared
        specification.usage = [.renderTarget]
        let texture = device.makeTexture(descriptor: specification)!
        func render(kind: Int, time: Float = 7, shade: Float = 0) throws -> [UInt8] {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            let command = queue.makeCommandBuffer()!
            let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
            var uniforms = SIMD4<Float>(Float(size), Float(height), time, Float(kind))
            var dimming = shade
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.setFragmentBuffer(seeds, offset: 0, index: 1)
            encoder.setFragmentBytes(&dimming, length: MemoryLayout<Float>.stride, index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            if let error = command.error { throw error }
            var pixels = [UInt8](repeating: 0, count: size * height * 4)
            texture.getBytes(&pixels, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, height), mipmapLevel: 0)
            return pixels
        }
        for (kind, scene) in ["aurora", "cosmos", "ocean", "ember", "ink", "dunes", "contour", "opal"].enumerated() {
            let pixels = try render(kind: kind)
            let context = CGContext(data: nil, width: size, height: height, bitsPerComponent: 8, bytesPerRow: size * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            SceneDrawing.render(scene: scene, time: 7, dimming: 0, in: context, bounds: CGRect(x: 0, y: 0, width: size, height: height))
            let cpu = context.data!.assumingMemoryBound(to: UInt8.self)
            var error = 0.0
            for y in 0..<height {
                for x in 0..<size {
                    for c in 0..<3 {
                        let value = Double(pixels[(y * size + x) * 4 + 2 - c])
                        error += abs(value - Double(cpu[(y * size + x) * 4 + c]))
                    }
                }
            }
            let divisor = Double(size * height * 3 * 255)
            precondition(error / divisor < 0.04, "GPU scene differs too much from the reference: " + scene)
            let moved = try render(kind: kind, time: 8)
            let dimmed = try render(kind: kind, shade: 0.5)
            precondition(pixels != moved, "Scene must animate: " + scene)
            for index in pixels.indices {
                if index % 4 == 3 {
                    precondition(pixels[index] == 255 && dimmed[index] == 255, "Scene must remain opaque")
                } else {
                    precondition(abs(Int(dimmed[index]) * 2 - Int(pixels[index])) <= 2, "Dimming must preserve scene colors")
                }
            }
            print("PASS:", scene, "GPU rendering, motion, dimming and reference appearance; mean RGB difference", error / divisor)
        }
    }
}
