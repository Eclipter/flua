import CoreGraphics
import Foundation
import Metal
import MetalKit

@main struct ScenePreviewTests {
    static func main() throws {
        precondition(SceneDrawing.previewPixelSize(scene: "contour", size: CGSize(width: 220, height: 138), backingScale: 2)
            == CGSize(width: 440, height: 276), "Artwork previews must render at Retina resolution")
        precondition(SceneDrawing.previewPixelSize(scene: "contour", size: CGSize(width: 220, height: 138), backingScale: 1)
            == CGSize(width: 220, height: 138), "Artwork previews must preserve 1x resolution")
        for scene in ["contour", "aurora"] {
            let size = SceneDrawing.previewPixelSize(scene: scene, size: CGSize(width: 10_000, height: 5_000), backingScale: 2)
            precondition(abs(size.width / size.height - 2) < 0.01, "Preview limits must preserve the view aspect ratio")
            let maximumEdge: CGFloat = scene == "contour" ? 2048 : 1280
            let maximumPixels: CGFloat = scene == "contour" ? 2_073_600 : 144_000
            precondition(size.width <= maximumEdge && size.height <= maximumEdge && size.width * size.height <= maximumPixels,
                         "Preview dimensions must stay within the scene rendering budget: " + scene)
        }
        for invalidScale: CGFloat in [0, -1, .infinity, .nan] {
            let size = SceneDrawing.previewPixelSize(scene: "contour", size: CGSize(width: 220, height: 138), backingScale: invalidScale)
            precondition(size == CGSize(width: 220, height: 138), "Invalid backing scales must safely fall back to 1x")
        }
        let invalidSize = SceneDrawing.previewPixelSize(scene: "contour", size: CGSize(width: .nan, height: -.infinity), backingScale: 2)
        precondition(invalidSize == CGSize(width: 2, height: 2), "Invalid preview dimensions must safely fall back to one point")

        let device = MTLCreateSystemDefaultDevice()!
        let library = try device.makeLibrary(source: String(contentsOfFile: "Sources/Flua/ScenePreview.metal", encoding: .utf8), options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "sceneVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "sceneFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.fragmentFunction = library.makeFunction(name: "sceneComposite")
        let compositePipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let motionDescriptor = MTLRenderPipelineDescriptor()
        motionDescriptor.vertexFunction = library.makeFunction(name: "motionVertex")
        motionDescriptor.fragmentFunction = library.makeFunction(name: "motionFragment")
        let attachment = motionDescriptor.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let motionPipeline = try device.makeRenderPipelineState(descriptor: motionDescriptor)
        let queue = device.makeCommandQueue()!
        let noise = (0..<1024).map { Float(SceneDrawing.noise($0)) }
        let seeds = device.makeBuffer(bytes: noise, length: noise.count * MemoryLayout<Float>.stride)!
        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: false, .origin: MTKTextureLoader.Origin.bottomLeft, .generateMipmaps: true
        ]
        let motionTextures = try SceneDrawing.motionImages.map { try loader.newTexture(cgImage: $0, options: options) }
        precondition(motionTextures.count == 11, "Motion rendering must provide eight scene textures and three pine textures")
        for image in SceneDrawing.motionImages {
            let bytes = image.dataProvider!.data!
            let data = CFDataGetBytePtr(bytes)!
            defer { withExtendedLifetime(bytes) {} }
            for y in 0..<image.height {
                for x in 0..<image.width where x == 0 || y == 0 || x == image.width - 1 || y == image.height - 1 {
                    precondition(data[y * image.bytesPerRow + x * 4 + 3] <= 1, "Motion textures must fade before their rectangle edges")
                }
            }
        }
        for image in SceneDrawing.motionImages[5..<8] {
            let bytes = image.dataProvider!.data!
            let data = CFDataGetBytePtr(bytes)!
            defer { withExtendedLifetime(bytes) {} }
            var transparentPixels = 0
            for y in 0..<image.height {
                for x in 0..<image.width where data[y * image.bytesPerRow + x * 4 + 3] == 0 {
                    transparentPixels += 1
                }
            }
            precondition(transparentPixels > image.width * image.height / 5,
                         "Pine textures must preserve transparent space around their cutouts")
        }
        var masks: [String: MTLTexture] = [:]
        var artworks: [String: MTLTexture] = [:]
        for scene in SceneDrawing.artworkScenes {
            guard let image = SceneDrawing.artworkImage(scene: scene) else { fatalError("Missing bundled artwork: " + scene) }
            precondition(image.width >= 1500 && image.height >= 900, "Wallpaper artwork must preserve its source detail")
            artworks[scene] = try loader.newTexture(cgImage: image, options: [
                .SRGB: false, .origin: MTKTextureLoader.Origin.bottomLeft, .generateMipmaps: true
            ])
            masks[scene] = try loader.newTexture(cgImage: SceneDrawing.motionMask(scene: scene)!, options: options)
            precondition(SceneDrawing.artworkFrame(time: 0, size: CGSize(width: 256, height: 160), image: image)
                == SceneDrawing.artworkFrame(time: 90, size: CGSize(width: 256, height: 160), image: image),
                "Artwork must remain fixed while separate scene elements animate")
        }
        let size = 256, height = 160
        let specification = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size, height: height, mipmapped: false)
        specification.storageMode = .shared
        specification.usage = [.renderTarget]
        let texture = device.makeTexture(descriptor: specification)!
        specification.usage = [.renderTarget, .shaderRead]
        let composition = device.makeTexture(descriptor: specification)!
        func render(kind: Int, time: Float = 7, shade: Float = 0,
                    spritesOverride: [SceneMotionSprite]? = nil) throws -> [UInt8] {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = composition
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            let command = queue.makeCommandBuffer()!
            let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
            var uniforms = SIMD4<Float>(Float(size), Float(height), time, Float(kind))
            var dimming = shade
            var unshaded: Float = 0
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.setFragmentBuffer(seeds, offset: 0, index: 1)
            encoder.setFragmentBytes(&unshaded, length: MemoryLayout<Float>.stride, index: 2)
            let scene = kind < 4 ? "ink" : SceneDrawing.artworkScenes[kind - 4]
            encoder.setFragmentTexture(artworks[scene], index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            let sprites = spritesOverride ?? SceneDrawing.motionSprites(scene: scene, time: Double(time))
            if kind >= 4, !sprites.isEmpty {
                let frame = SceneDrawing.artworkFrame(time: Double(time), size: CGSize(width: size, height: height),
                    image: SceneDrawing.artworkImage(scene: scene)!)
                var geometry = SIMD4<Float>(Float(frame.minX), Float(frame.minY), Float(frame.width), Float(frame.height))
                let buffer = device.makeBuffer(bytes: sprites, length: sprites.count * MemoryLayout<SceneMotionSprite>.stride)!
                encoder.setRenderPipelineState(motionPipeline)
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                encoder.setVertexBytes(&geometry, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
                for (index, texture) in motionTextures.enumerated() { encoder.setFragmentTexture(texture, index: index) }
                encoder.setFragmentTexture(masks[scene], index: 11)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: sprites.count)
            }
            encoder.endEncoding()
            let outputPass = MTLRenderPassDescriptor()
            outputPass.colorAttachments[0].texture = texture
            outputPass.colorAttachments[0].loadAction = .dontCare
            outputPass.colorAttachments[0].storeAction = .store
            let output = command.makeRenderCommandEncoder(descriptor: outputPass)!
            output.setRenderPipelineState(compositePipeline)
            output.setFragmentTexture(composition, index: 0)
            output.setFragmentBytes(&dimming, length: MemoryLayout<Float>.stride, index: 2)
            output.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            output.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            if let error = command.error { throw error }
            var pixels = [UInt8](repeating: 0, count: size * height * 4)
            texture.getBytes(&pixels, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, height), mipmapLevel: 0)
            return pixels
        }
        let inkBackground7 = try render(kind: 4, time: 7, spritesOverride: [])
        let inkBackground10 = try render(kind: 4, time: 10, spritesOverride: [])
        precondition(inkBackground7 == inkBackground10,
                     "Ink background artwork must remain pixel-identical without motion sprites")
        let trees7 = SceneDrawing.treeSprites(time: 7)
        let trees10 = SceneDrawing.treeSprites(time: 10)
        precondition(trees7.count == 6 && trees10.count == 6, "Ink tree sprites must remain present")
        let treeFrame7 = try render(kind: 4, time: 7, spritesOverride: trees7)
        let treeFrame10 = try render(kind: 4, time: 10, spritesOverride: trees10)
        let treeMotionPixels = (0..<size * height).filter { pixel in
            (0..<3).contains { abs(Int(treeFrame7[pixel * 4 + $0]) - Int(treeFrame10[pixel * 4 + $0])) > 3 }
        }.count
        precondition(treeMotionPixels > 30, "Pine sprites must visibly sway over time")
        let inkImage = SceneDrawing.artworkImage(scene: "ink")!
        let treeFrame = SceneDrawing.artworkFrame(time: 7, size: CGSize(width: size, height: height), image: inkImage)
        let treeMarginX = 2.0 / Double(size), treeMarginY = 2.0 / Double(height)
        func treeBounds(_ sprites: [SceneMotionSprite]) -> [CGRect] {
            sprites.map { sprite in
                let angle = Double(sprite.style.x)
                let halfWidth = Double(sprite.rect.z) / 2
                let halfHeight = Double(sprite.rect.w) / 2
                let points = [SIMD2(-halfWidth, -halfHeight), SIMD2(halfWidth, -halfHeight),
                              SIMD2(halfWidth, halfHeight), SIMD2(-halfWidth, halfHeight)].map { point in
                    let x = Double(sprite.rect.x) + point.x * cos(angle) - point.y * sin(angle)
                    let y = Double(sprite.rect.y) + point.x * sin(angle) + point.y * cos(angle)
                    return CGPoint(x: treeFrame.minX + x * treeFrame.width, y: treeFrame.minY + y * treeFrame.height)
                }
                let minX = points.map(\.x).min()! - treeMarginX
                let maxX = points.map(\.x).max()! + treeMarginX
                let minY = points.map(\.y).min()! - treeMarginY
                let maxY = points.map(\.y).max()! + treeMarginY
                return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            }
        }
        let coveredTreeBounds = treeBounds(trees7) + treeBounds(trees10)
        for pixel in 0..<size * height {
            let x = (Double(pixel % size) + 0.5) / Double(size)
            let y = 1 - (Double(pixel / size) + 0.5) / Double(height)
            let insideTreeBounds = coveredTreeBounds.contains { bounds in
                bounds.contains(CGPoint(x: x, y: y))
            }
            if !insideTreeBounds {
                for channel in 0..<3 {
                    precondition(treeFrame7[pixel * 4 + channel] == inkBackground7[pixel * 4 + channel]
                                 && treeFrame10[pixel * 4 + channel] == inkBackground10[pixel * 4 + channel],
                                 "Pine sway must not change pixels outside the rotated sprite bounds")
                }
            }
        }
        for time in [0.0, 1, 7, 10, 100, .infinity, .nan] {
            for (index, tree) in SceneDrawing.treeSprites(time: time).enumerated() {
                let image = SceneDrawing.motionImages[Int(tree.style.z)]
                let data = image.dataProvider!.data!
                let bytes = CFDataGetBytePtr(data)!
                var rootX = 0.0, weight = 0.0
                for y in (image.height - 7)..<(image.height - 2) {
                    for x in 0..<image.width {
                        let alpha = Double(bytes[y * image.bytesPerRow + x * 4 + 3])
                        rootX += (Double(x) + 0.5) * alpha
                        weight += alpha
                    }
                }
                let root = SIMD2(Float(rootX / weight / Double(image.width)), 2 / Float(image.height))
                let local = (root - SIMD2<Float>(repeating: 0.5)) * SIMD2(tree.rect.z, tree.rect.w)
                let angle = tree.style.x
                let actual = SIMD2(tree.rect.x, tree.rect.y) + SIMD2(local.x * cos(angle) - local.y * sin(angle),
                                                                   local.x * sin(angle) + local.y * cos(angle))
                let expected = SceneDrawing.treePlacements[index]
                precondition(actual.x.isFinite && actual.y.isFinite
                    && abs(actual.x - expected.x) < 0.00001 && abs(actual.y - expected.y) < 0.00001,
                    "Pine roots must remain anchored while tree layers rotate")
                withExtendedLifetime(data) {}
            }
        }
        print("PASS: original background is pixel-identical; only transparent pine layers move, with anchored roots")
        for (kind, scene) in ["aurora", "cosmos", "ocean", "ember", "ink", "dunes", "contour", "opal",
                              "pelagic", "lanterns", "rain"].enumerated() {
            let pixels = try render(kind: kind)
            let context = CGContext(data: nil, width: size, height: height, bitsPerComponent: 8, bytesPerRow: size * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            SceneDrawing.render(scene: scene, time: 7, dimming: 0, in: context, bounds: CGRect(x: 0, y: 0, width: size, height: height))
            let cpu = context.data!.assumingMemoryBound(to: UInt8.self)
            var error = 0.0
            for y in 0..<height {
                for x in 0..<size {
                    precondition(cpu[(y * size + x) * 4 + 3] == 255, "Reference frame must remain opaque: " + scene)
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
            if kind >= 4 {
                let later = try render(kind: kind, time: 10)
                let visibleMotion = (0..<size * height).filter { pixel in
                    (0..<3).contains { abs(Int(pixels[pixel * 4 + $0]) - Int(later[pixel * 4 + $0])) > 3 }
                }.count
                print("MOTION:", scene, visibleMotion, "pixels changed while artwork stayed fixed")
                if ["pelagic", "lanterns", "rain"].contains(scene) {
                    let oneSecondLater = try render(kind: kind, time: 8)
                    let substantialMotion = (0..<size * height).filter { pixel in
                        (0..<3).contains { abs(Int(pixels[pixel * 4 + $0]) - Int(oneSecondLater[pixel * 4 + $0])) > 8 }
                    }.count
                    precondition(substantialMotion >= size * height / 20,
                                 "New scene motion must change at least five percent of pixels over one second: " + scene)
                    let repeated = try render(kind: kind, time: 7)
                    precondition(repeated == pixels, "Scene motion must be deterministic: " + scene)
                    let fixed7 = try render(kind: kind, time: 7, spritesOverride: [])
                    let fixed8 = try render(kind: kind, time: 8, spritesOverride: [])
                    precondition(fixed7 == fixed8, "Scene artwork must remain fixed without motion sprites: " + scene)
                    for invalidTime: Float in [.infinity, .nan] {
                        let invalidSprites = SceneDrawing.motionSprites(scene: scene, time: Double(invalidTime))
                        let repeatedInvalidSprites = SceneDrawing.motionSprites(scene: scene, time: Double(invalidTime))
                        precondition(invalidSprites.count == repeatedInvalidSprites.count
                            && zip(invalidSprites, repeatedInvalidSprites).allSatisfy { pair in
                                pair.0.rect == pair.1.rect && pair.0.style == pair.1.style
                            },
                                     "Invalid motion times must produce deterministic sprites: " + scene)
                        for sprite in invalidSprites {
                            precondition((0..<4).allSatisfy { sprite.rect[$0].isFinite && sprite.style[$0].isFinite },
                                         "Invalid motion times must not produce non-finite sprite values: " + scene)
                        }
                    }
                }
                for time in [0.0, 7, 17, 45, 120] {
                    let particles = SceneDrawing.motionSprites(scene: scene, time: time)
                    precondition(!particles.isEmpty && particles.count < 1024, "Scene motion must remain bounded")
                    for particle in particles {
                        precondition((0..<4).allSatisfy { particle.rect[$0].isFinite && particle.style[$0].isFinite })
                        precondition(particle.rect.z > 0 && particle.rect.w > 0 && (0...1).contains(particle.style.y))
                        precondition((0..<motionTextures.count).contains(Int(particle.style.z)))
                    }
                }
            }
            for index in pixels.indices {
                if index % 4 == 3 {
                    precondition(pixels[index] == 255 && dimmed[index] == 255, "Scene must remain opaque")
                } else {
                    precondition(abs(Int(dimmed[index]) * 2 - Int(pixels[index])) <= 2, "Dimming must preserve scene colors")
                }
            }
            print("PASS:", scene, "GPU rendering, motion, dimming and reference appearance; mean RGB difference", error / divisor)
        }
        for scene in SceneDrawing.artworkScenes {
            for (width, height) in [(64, 96), (192, 64)] {
                let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                for time in [0.0, 93.0] {
                    context.clear(CGRect(x: 0, y: 0, width: width, height: height))
                    SceneDrawing.render(scene: scene, time: time, dimming: 0, in: context,
                                        bounds: CGRect(x: 0, y: 0, width: width, height: height))
                    let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
                    precondition((0..<width * height).allSatisfy { pixels[$0 * 4 + 3] == 255 },
                                 "Animated artwork must fill portrait and wide frames without gaps: " + scene)
                }
            }
        }
        print("PASS: fixed artwork fills portrait and wide frames while separate scene elements animate")
    }
}
