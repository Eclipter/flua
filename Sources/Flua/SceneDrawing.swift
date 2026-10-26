import CoreGraphics
import Foundation
import ImageIO

struct SceneMotionSprite: Sendable {
    var rect: SIMD4<Float>
    var style: SIMD4<Float>
}

enum SceneDrawing {
    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(red: r, green: g, blue: b, alpha: a)
    }

    static func render(scene: String, time: Double, dimming: Double, in c: CGContext, bounds: CGRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        c.saveGState()
        c.translateBy(x: bounds.minX, y: bounds.minY)
        c.scaleBy(x: bounds.width, y: bounds.height)
        c.clip(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        switch scene {
        case "cosmos": cosmos(c, time)
        case "ocean": ocean(c, time)
        case "ember": ember(c, time)
        case "ink", "dunes", "contour", "opal": artwork(scene: scene, time: time, in: c, size: bounds.size)
        default: aurora(c, time)
        }
        let shade = dimming.isFinite ? CGFloat(min(max(dimming, 0), 0.9)) : 0.12
        c.setFillColor(rgb(0, 0, 0, shade))
        c.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        c.restoreGState()
    }

    static func linear(_ c: CGContext, colors: [CGColor], from: CGPoint, to: CGPoint) {
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil) else { return }
        c.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    static func glow(_ c: CGContext, x: CGFloat, y: CGFloat, rx: CGFloat, ry: CGFloat, color: CGColor) {
        c.saveGState()
        c.translateBy(x: x, y: y)
        c.scaleBy(x: rx, y: ry)
        let transparent = color.copy(alpha: 0) ?? rgb(0, 0, 0, 0)
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color, transparent] as CFArray, locations: [0, 1]) {
            c.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
        }
        c.restoreGState()
    }

    static func noise(_ seed: Int) -> CGFloat {
        let n = sin(Double(seed) * 127.1 + 311.7) * 43758.5453123
        return CGFloat(n - floor(n))
    }

    static func stars(_ c: CGContext, _ t: Double, count: Int, minimumY: CGFloat = 0.25) {
        for i in 0..<count {
            let x = noise(i * 3 + 1)
            let y = minimumY + noise(i * 3 + 2) * (1 - minimumY)
            let radius = 0.00045 + noise(i * 3 + 3) * 0.00075
            let alpha = 0.18 + 0.54 * (0.5 + 0.5 * sin(t * 0.35 + Double(i)))
            c.setFillColor(rgb(0.8, 0.9, 1, alpha))
            c.fillEllipse(in: CGRect(x: x, y: y, width: radius, height: radius * 1.7))
        }
    }

    static let artworkScenes = ["ink", "dunes", "contour", "opal"]

    private static func loadSceneImage(_ name: String) -> CGImage? {
        #if SWIFT_PACKAGE
        let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "SceneAssets")
        #else
        let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "SceneAssets")
        #endif
        guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let original = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = CGContext(data: nil, width: original.width, height: original.height,
                bitsPerComponent: 8, bytesPerRow: original.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Decode once into the same RGB space used by the preview texture.
        context.draw(original, in: CGRect(x: 0, y: 0, width: original.width, height: original.height))
        return context.makeImage()
    }

    private static let artworkImages: [String: CGImage] = Dictionary(uniqueKeysWithValues: artworkScenes.compactMap { scene in
        guard let image = loadSceneImage(scene) else { return nil }
        return (scene, image)
    })

    static func artworkImage(scene: String) -> CGImage? { artworkImages[scene] }

    static func artworkFrame(time t: Double, size: CGSize, image: CGImage) -> CGRect {
        let scale = max(size.width / CGFloat(image.width), size.height / CGFloat(image.height))
        let width = CGFloat(image.width) * scale / size.width
        let height = CGFloat(image.height) * scale / size.height
        return CGRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
    }

    static func previewPixelSize(scene: String, size: CGSize, backingScale: CGFloat) -> CGSize {
        let maximumEdge: CGFloat = artworkScenes.contains(scene) ? 2048 : 1280
        let maximumPixels: CGFloat = artworkScenes.contains(scene) ? 2_073_600 : 144_000
        let scale = backingScale.isFinite && backingScale > 0 ? backingScale : 1
        let width = size.width.isFinite && size.width > 0 ? min(1_000_000, size.width) : 1
        let height = size.height.isFinite && size.height > 0 ? min(1_000_000, size.height) : 1
        let pixelScale = min(scale, min(maximumEdge / max(width, height), sqrt(maximumPixels / (width * height))))
        return CGSize(width: max(1, floor(width * pixelScale)), height: max(1, floor(height * pixelScale)))
    }

    private struct PineImage {
        let image: CGImage
        let root: SIMD2<Float>
    }

    private static let pineImages: [PineImage] = {
        guard let atlas = loadSceneImage("ink-pines"), let data = atlas.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return [] }
        return (0..<3).compactMap { column in
            let start = column * atlas.width / 3, end = (column + 1) * atlas.width / 3
            var left = end, right = start, top = atlas.height, bottom = 0
            for y in 0..<atlas.height {
                for x in start..<end where bytes[y * atlas.bytesPerRow + x * 4 + 3] > 2 {
                    left = min(left, x); right = max(right, x)
                    top = min(top, y); bottom = max(bottom, y)
                }
            }
            guard right > left, bottom > top,
                  let crop = atlas.cropping(to: CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)),
                  let context = CGContext(data: nil, width: crop.width + 4, height: crop.height + 4,
                    bitsPerComponent: 8, bytesPerRow: (crop.width + 4) * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            var rootX = 0.0, weight = 0.0
            for y in max(top, bottom - 4)...bottom {
                for x in left...right {
                    let alpha = Double(bytes[y * atlas.bytesPerRow + x * 4 + 3])
                    rootX += (Double(x) + 0.5) * alpha
                    weight += alpha
                }
            }
            context.draw(crop, in: CGRect(x: 2, y: 2, width: crop.width, height: crop.height))
            guard let image = context.makeImage(), weight > 0 else { return nil }
            return PineImage(image: image, root: SIMD2(Float((rootX / weight - Double(left) + 2) / Double(image.width)),
                                                      2 / Float(image.height)))
        }
    }()

    static let motionImages: [CGImage] = (0..<5).map(makeMotionImage) + pineImages.map(\.image)

    static let treePlacements: [SIMD4<Float>] = [
        SIMD4(0.805, 0.015, 0.14, 0), SIMD4(0.875, 0.025, 0.20, 1),
        SIMD4(0.960, 0.055, 0.23, 2), SIMD4(0.655, 0.350, 0.10, 0),
        SIMD4(0.282, 0.120, 0.075, 1), SIMD4(0.595, 0.627, 0.065, 2)
    ]

    static func treeSprites(time: Double) -> [SceneMotionSprite] {
        let t = (time.isFinite ? time : 0) * 2
        return treePlacements.enumerated().compactMap { index, placement in
            let texture = Int(placement.w)
            guard pineImages.indices.contains(texture) else { return nil }
            let pine = pineImages[texture]
            let phase = Double(index) * 1.73
            let angle = Float(0.025 * sin(t * 0.85 + phase) + 0.008 * sin(t * 1.47 + phase * 0.63))
            let height = placement.z
            let width = height * Float(pine.image.width) / Float(pine.image.height) * 992 / 1586
            let offset = (SIMD2<Float>(repeating: 0.5) - pine.root) * SIMD2(width, height)
            let center = SIMD2(placement.x, placement.y) + SIMD2(offset.x * cos(angle) - offset.y * sin(angle),
                                                              offset.x * sin(angle) + offset.y * cos(angle))
            return SceneMotionSprite(rect: SIMD4(center.x, center.y, width, height),
                                     style: SIMD4(angle, 1, Float(texture + 5), 0))
        }
    }

    private static let motionMasks: [String: CGImage] = Dictionary(uniqueKeysWithValues: artworkScenes.compactMap { scene in
        guard let image = artworkImages[scene] else { return nil }
        return (scene, makeMotionMask(scene: scene, image: image))
    })

    private static let motionClipMasks: [String: CGImage] = Dictionary(uniqueKeysWithValues: motionMasks.compactMap { scene, image in
        guard let provider = image.dataProvider, let data = provider.data,
              let source = CFDataGetBytePtr(data) else { return nil }
        let count = image.width * image.height
        var alpha = [UInt8](repeating: 0, count: count)
        for index in 0..<count { alpha[index] = source[index * 4 + 3] }
        guard let alphaProvider = CGDataProvider(data: Data(alpha) as CFData),
              let clipMask = CGImage(width: image.width, height: image.height, bitsPerComponent: 8,
                                     bitsPerPixel: 8, bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(),
                                     bitmapInfo: [], provider: alphaProvider, decode: nil, shouldInterpolate: true,
                                     intent: .defaultIntent) else { return nil }
        return (scene, clipMask)
    })

    static func motionMask(scene: String) -> CGImage? { motionMasks[scene] }

    static func motionSprites(scene: String, time: Double) -> [SceneMotionSprite] {
        let t = (time.isFinite ? time : 0) * (scene == "ink" || scene == "dunes" ? 2 : 1)
        var result: [SceneMotionSprite] = []
        func add(_ x: Double, _ y: Double, _ width: Double, _ height: Double, _ angle: Double,
                 _ opacity: Double, _ texture: Int, masked: Bool) {
            guard [x, y, width, height, angle, opacity].allSatisfy(\.isFinite), width > 0, height > 0 else { return }
            let alpha = min(1, max(0, opacity))
            guard alpha > 0.001 else { return }
            result.append(SceneMotionSprite(
                rect: SIMD4(Float(x), Float(y), Float(width), Float(height)),
                style: SIMD4(Float(angle), Float(alpha), Float(texture), masked ? 1 : 0)
            ))
        }
        func phase(_ seed: Double, speed: Double) -> Double {
            let value = t * speed + seed
            return value - floor(value)
        }
        func fade(_ p: Double, edge: Double = 0.12) -> Double {
            smoothstep(0, edge, p) * (1 - smoothstep(1 - edge, 1, p))
        }

        switch scene {
        case "ink":
            for i in 0..<26 {
                let seed = noise(i * 17 + 31)
                let p = phase(seed, speed: 0.010 + Double(noise(i + 101)) * 0.006)
                let lane = Double(i % 6)
                let x = -0.18 + p * 1.36
                let y = 0.22 + lane * 0.045 + 0.018 * sin(t * 0.16 + Double(i) * 1.7)
                let alpha = fade(p) * (0.19 + Double(noise(i + 7)) * 0.16)
                add(x, y, 0.13 + Double(noise(i + 3)) * 0.12, 0.035 + Double(noise(i + 8)) * 0.032,
                    0.035 * sin(t * 0.11 + Double(i)), alpha, 0, masked: true)
            }
            for i in 0..<9 {
                let p = phase(Double(i) / 9, speed: 0.0035 + Double(noise(i + 211)) * 0.0015)
                let x = -0.08 + p * 1.16
                let y = 0.73 + Double(noise(i + 19)) * 0.21 + 0.012 * sin(t * 0.65 + Double(i))
                let wing = 0.65 + 0.35 * abs(sin(t * 1.5 + Double(i) * 2.1))
                add(x, y, 0.020 + Double(noise(i + 43)) * 0.018, (0.012 + Double(noise(i + 53)) * 0.006) * wing,
                    0.10 * sin(t * 0.22 + Double(i)), fade(p, edge: 0.18) * 0.72, 4, masked: false)
            }
            result += treeSprites(time: time)
        case "dunes":
            for i in 0..<20 {
                let p = phase(Double(i) / 20, speed: 0.019 + Double(noise(i + 307)) * 0.009)
                let lane = Double(i % 5)
                let x = -0.10 + p * 1.20
                let y = 0.22 + lane * 0.082 + 0.045 * sin(p * 6.2 + Double(i) * 1.4)
                let alpha = fade(p, edge: 0.15) * (0.16 + Double(noise(i + 11)) * 0.13)
                add(x, y, 0.11 + Double(noise(i + 12)) * 0.11, 0.018 + Double(noise(i + 26)) * 0.018,
                    -0.24 + 0.08 * sin(t * 0.14 + Double(i)), alpha, 1, masked: true)
            }
            for i in 0..<250 {
                let p = phase(Double(noise(i * 13 + 9)), speed: 0.025 + Double(noise(i + 401)) * 0.045)
                let x = -0.04 + p * 1.08
                let lane = Double(noise(i * 7 + 2))
                let y = 0.19 + lane * 0.47 + 0.035 * sin(x * 7 + t * 0.25 + Double(i))
                let alpha = fade(p, edge: 0.08) * (0.18 + Double(noise(i + 82)) * 0.34)
                let width = 0.003 + Double(noise(i + 1)) * 0.006
                add(x, y, width, width * (0.42 + Double(noise(i + 55)) * 0.48),
                    -0.30 + 0.14 * sin(t * 0.19 + Double(i)), alpha, 1, masked: true)
            }
        case "contour":
            let routes: [[CGPoint]] = [
                [CGPoint(x: 0.36, y: 0.91), CGPoint(x: 0.39, y: 0.82), CGPoint(x: 0.40, y: 0.72), CGPoint(x: 0.50, y: 0.61), CGPoint(x: 0.57, y: 0.50), CGPoint(x: 0.54, y: 0.39), CGPoint(x: 0.56, y: 0.25), CGPoint(x: 0.63, y: 0.095)],
                [CGPoint(x: 0.15, y: 0.77), CGPoint(x: 0.26, y: 0.75), CGPoint(x: 0.36, y: 0.72), CGPoint(x: 0.43, y: 0.68), CGPoint(x: 0.49, y: 0.62), CGPoint(x: 0.50, y: 0.54)],
                [CGPoint(x: 0.76, y: 0.83), CGPoint(x: 0.68, y: 0.76), CGPoint(x: 0.62, y: 0.69), CGPoint(x: 0.57, y: 0.60), CGPoint(x: 0.55, y: 0.46)],
                [CGPoint(x: 0.27, y: 0.34), CGPoint(x: 0.37, y: 0.38), CGPoint(x: 0.46, y: 0.42), CGPoint(x: 0.53, y: 0.46), CGPoint(x: 0.56, y: 0.36)]
            ]
            for (routeIndex, route) in routes.enumerated() {
                let count = routeIndex == 0 ? 48 : 24
                for i in 0..<count {
                    let p = phase(Double(i) / Double(count) + Double(routeIndex) * 0.19, speed: 0.032 + Double(noise(i + routeIndex * 73)) * 0.014)
                    let point = routePoint(route, progress: p)
                    let before = routePoint(route, progress: max(0, p - 0.008))
                    let after = routePoint(route, progress: min(1, p + 0.008))
                    let angle = atan2(Double(after.y - before.y), Double(after.x - before.x))
                    let spread = (Double(noise(i * 5 + routeIndex + 8)) - 0.5) * 0.020
                    let alpha = fade(p, edge: 0.09) * (0.32 + Double(noise(i + routeIndex * 41)) * 0.42)
                    let width = 0.014 + Double(noise(i + 27)) * 0.025
                    add(Double(point.x) + spread, Double(point.y) + spread * 0.55, width, 0.005 + Double(noise(i + 61)) * 0.006,
                        angle, alpha, 3, masked: true)
                }
            }
        case "opal":
            for i in 0..<192 {
                let lane = i % 6
                let count = 32.0
                let p = phase(Double(i) / count, speed: 0.021 + Double(noise(i + 503)) * 0.014)
                let x = -0.12 + p * 1.24
                let lanePhase = Double(lane) * 0.82
                let y = 0.53 + 0.22 * sin(p * 5.4 + lanePhase) + 0.075 * sin(p * 12.0 - lanePhase * 0.8)
                let angle = atan2(0.22 * 5.4 * cos(p * 5.4 + lanePhase) + 0.075 * 12 * cos(p * 12 - lanePhase * 0.8), 1.24)
                let size = 0.045 + Double(noise(i + 37)) * 0.075
                let alpha = fade(p, edge: 0.10) * (0.25 + Double(noise(i + 107)) * 0.45)
                add(x, y, size, size * (0.45 + Double(noise(i + 3)) * 0.45), angle, alpha,
                    i % 5 == 0 ? 0 : 2, masked: true)
            }
        default:
            break
        }
        return result
    }

    private static func smoothstep(_ lower: Double, _ upper: Double, _ value: Double) -> Double {
        let x = min(1, max(0, (value - lower) / (upper - lower)))
        return x * x * (3 - 2 * x)
    }

    private static func routePoint(_ points: [CGPoint], progress: Double) -> CGPoint {
        let scaled = min(1, max(0, progress)) * Double(points.count - 1)
        let index = min(points.count - 2, Int(scaled))
        let t = CGFloat(scaled - Double(index))
        let p0 = points[max(0, index - 1)]
        let p1 = points[index]
        let p2 = points[index + 1]
        let p3 = points[min(points.count - 1, index + 2)]
        func interpolate(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
            0.5 * ((2 * b) + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t * t + (-a + 3 * b - 3 * c + d) * t * t * t)
        }
        return CGPoint(x: interpolate(p0.x, p1.x, p2.x, p3.x), y: interpolate(p0.y, p1.y, p2.y, p3.y))
    }

    private static func makeMotionMask(scene: String, image: CGImage) -> CGImage {
        let width = image.width, height = image.height
        guard let sourceContext = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        sourceContext.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let sourceData = sourceContext.data else { return image }
        let sourcePixels = sourceData.assumingMemoryBound(to: UInt8.self)
        var output = [UInt8](repeating: 0, count: width * height * 4)
        for pixel in 0..<(width * height) {
            let offset = pixel * 4
            let red = Double(sourcePixels[offset]) / 255
            let green = Double(sourcePixels[offset + 1]) / 255
            let blue = Double(sourcePixels[offset + 2]) / 255
            let luminance = red * 0.2126 + green * 0.7152 + blue * 0.0722
            let alpha: Double
            switch scene {
            case "dunes": alpha = 1
            case "ink": alpha = smoothstep(0.30, 0.76, luminance)
            case "contour":
                let teal = min(green, blue) - red
                let blueBias = blue - red
                let balanced = 1 - min(1, abs(green - blue) * 5)
                alpha = smoothstep(0.025, 0.12, teal) * smoothstep(0.012, 0.085, blueBias) * (0.25 + balanced * 0.75)
            case "opal": alpha = smoothstep(0.42, 0.78, luminance)
            default: alpha = 0
            }
            let value = UInt8((min(1, max(0, alpha)) * 255).rounded())
            output[offset] = value
            output[offset + 1] = value
            output[offset + 2] = value
            output[offset + 3] = value
        }
        return makeRGBAImage(width: width, height: height, pixels: output) ?? image
    }

    private static func makeMotionImage(_ index: Int) -> CGImage {
        let side = index == 4 ? 128 : 256
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let u = (Double(x) + 0.5) / Double(side)
                let v = (Double(y) + 0.5) / Double(side)
                let broad = fractalNoise(u * 4, v * 4, seed: UInt32(index * 91 + 7))
                let mid = fractalNoise(u * 11, v * 8, seed: UInt32(index * 137 + 19))
                let fine = fractalNoise(u * 29, v * 23, seed: UInt32(index * 211 + 37))
                var color = SIMD3<Double>(1, 1, 1)
                var alpha = 0.0
                switch index {
                case 0:
                    let strand = 0.5 + 0.5 * sin((u * 5 + v * 1.2 + broad * 0.7) * 22)
                    alpha = smoothstep(0.24, 0.66, broad) * (0.52 + mid * 0.42) * (0.72 + strand * 0.28)
                    color = SIMD3(0.91, 0.94, 0.93)
                case 1:
                    let filament = exp(-abs(sin((u * 8 + v * 2 + broad * 0.4) * 48)) * 13)
                    alpha = min(0.88, 0.22 + broad * 0.42 + mid * 0.19 + filament * 0.28) * (0.76 + fine * 0.24)
                    color = SIMD3(0.98, 0.67 + fine * 0.12, 0.39 + fine * 0.08)
                case 2:
                    let brush = 0.5 + 0.5 * sin((u * 1.4 + v * 0.34 + broad * 0.34) * 64)
                    alpha = smoothstep(0.28, 0.65, broad * 0.72 + mid * 0.28) * (0.38 + brush * 0.62)
                    color = SIMD3(0.055 + fine * 0.025, 0.06 + fine * 0.025, 0.058 + fine * 0.024)
                case 3:
                    let center = 0.5 + 0.075 * sin(u * 12 + broad * 2)
                    let filament = exp(-pow((v - center) * 5, 2))
                    alpha = filament * (0.60 + mid * 0.35)
                    color = SIMD3(0.48 + fine * 0.10, 0.84 + fine * 0.08, 0.81 + fine * 0.08)
                default:
                    alpha = inBirdShape(u, v) ? 1 : 0
                    color = SIMD3(0.055, 0.065, 0.064)
                }
                if index < 4 {
                    let dx = (u - 0.5) * 2
                    let dy = (v - 0.5) * 2
                    let radius = sqrt(dx * dx + dy * dy)
                    let angle = atan2(dy, dx)
                    let boundary = 0.69 + broad * 0.24 + mid * 0.12
                        + 0.045 * sin(angle * 3 + 0.55 * sin(angle * 5 + broad * 4))
                    alpha *= 1 - smoothstep(boundary - 0.12, boundary + 0.025, radius)
                }
                let a = min(1, max(0, alpha))
                let offset = (y * side + x) * 4
                pixels[offset] = UInt8((color.x * a * 255).rounded())
                pixels[offset + 1] = UInt8((color.y * a * 255).rounded())
                pixels[offset + 2] = UInt8((color.z * a * 255).rounded())
                pixels[offset + 3] = UInt8((a * 255).rounded())
            }
        }
        return makeRGBAImage(width: side, height: side, pixels: pixels)!
    }

    private static func inBirdShape(_ x: Double, _ y: Double) -> Bool {
        let leftWing = [(0.50, 0.50), (0.43, 0.57), (0.17, 0.77), (0.29, 0.53), (0.44, 0.42)]
        let rightWing = leftWing.map { (1 - $0.0, $0.1) }
        func inside(_ polygon: [(Double, Double)]) -> Bool {
            var value = false
            var previous = polygon.count - 1
            for current in polygon.indices {
                let a = polygon[current], b = polygon[previous]
                if (a.1 > y) != (b.1 > y), x < (b.0 - a.0) * (y - a.1) / (b.1 - a.1) + a.0 { value.toggle() }
                previous = current
            }
            return value
        }
        let body = (x - 0.5) * (x - 0.5) / 0.0005 + (y - 0.47) * (y - 0.47) / 0.012 < 1
        return body || inside(leftWing) || inside(rightWing)
    }

    private static func fractalNoise(_ x: Double, _ y: Double, seed: UInt32) -> Double {
        var amplitude = 0.5
        var frequency = 1.0
        var total = 0.0
        var normalization = 0.0
        for octave in 0..<4 {
            total += valueNoise(x * frequency, y * frequency, seed: seed &+ UInt32(octave * 71)) * amplitude
            normalization += amplitude
            amplitude *= 0.5
            frequency *= 2
        }
        return total / normalization
    }

    private static func valueNoise(_ x: Double, _ y: Double, seed: UInt32) -> Double {
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        let fx = x - floor(x), fy = y - floor(y)
        let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
        let a = lattice(x0, y0, seed), b = lattice(x0 + 1, y0, seed)
        let c = lattice(x0, y0 + 1, seed), d = lattice(x0 + 1, y0 + 1, seed)
        let lower = a + (b - a) * sx
        let upper = c + (d - c) * sx
        return lower + (upper - lower) * sy
    }

    private static func lattice(_ x: Int, _ y: Int, _ seed: UInt32) -> Double {
        var value = UInt32(truncatingIfNeeded: x) &* 0x8da6b343
        value ^= UInt32(truncatingIfNeeded: y) &* 0xd8163841
        value ^= seed &* 0xcb1ab31f
        value ^= value >> 13
        value &*= 0x85ebca6b
        value ^= value >> 16
        value &*= 0xc2b2ae35
        value ^= value >> 16
        return Double(value) / Double(UInt32.max)
    }

    private static func makeRGBAImage(width: Int, height: Int, pixels: [UInt8]) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func drawMotion(scene: String, time: Double, frame: CGRect, in c: CGContext) {
        let sprites = motionSprites(scene: scene, time: time)
        guard !sprites.isEmpty else { return }
        let mask = motionClipMasks[scene]
        let masked = sprites.filter { $0.style.w > 0.5 }
        let unmasked = sprites.filter { $0.style.w <= 0.5 }
        if !masked.isEmpty, let mask {
            c.saveGState()
            c.clip(to: CGRect(x: 0, y: 0, width: 1, height: 1))
            c.clip(to: frame, mask: mask)
            drawSprites(masked, frame: frame, in: c)
            c.restoreGState()
        }
        drawSprites(unmasked, frame: frame, in: c)
    }

    private static func drawSprites(_ sprites: [SceneMotionSprite], frame: CGRect, in c: CGContext) {
        for sprite in sprites {
            let texture = Int(sprite.style.z.rounded())
            guard motionImages.indices.contains(texture) else { continue }
            let x = CGFloat(sprite.rect.x), y = CGFloat(sprite.rect.y)
            let width = CGFloat(sprite.rect.z), height = CGFloat(sprite.rect.w)
            c.saveGState()
            c.translateBy(x: frame.minX + x * frame.width, y: frame.minY + y * frame.height)
            c.scaleBy(x: frame.width, y: frame.height)
            c.rotate(by: CGFloat(sprite.style.x))
            c.setAlpha(CGFloat(sprite.style.y))
            c.interpolationQuality = .high
            c.draw(motionImages[texture], in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
            c.restoreGState()
        }
    }

    static func artwork(scene: String, time t: Double, in c: CGContext, size: CGSize) {
        guard let image = artworkImage(scene: scene) else {
            c.setFillColor(rgb(0.025, 0.045, 0.055))
            c.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            return
        }
        let frame = artworkFrame(time: t, size: size, image: image)
        c.interpolationQuality = .high
        c.draw(image, in: frame)
        drawMotion(scene: scene, time: t, frame: frame, in: c)
    }

    static func aurora(_ c: CGContext, _ t: Double) {
        linear(c, colors: [rgb(0.012, 0.025, 0.065), rgb(0.025, 0.11, 0.16), rgb(0.025, 0.04, 0.10)], from: CGPoint(x: 0, y: 1), to: .zero)
        glow(c, x: 0.65, y: 0.65, rx: 0.65, ry: 0.55, color: rgb(0.05, 0.36, 0.33, 0.3))
        stars(c, t, count: 135, minimumY: 0.39)
        for ribbon in stride(from: 6, through: 0, by: -1) {
            let r = Double(ribbon)
            let phase = t * 0.10 + r * 0.22
            let base = 0.64 + r * 0.025
            let path = CGMutablePath()
            func height(_ x: Double) -> Double {
                base + 0.10 * sin(x * 5.0 + phase) + 0.075 * sin(x * 8.2 - phase * 0.6)
            }
            path.move(to: CGPoint(x: -0.05, y: height(-0.05)))
            for step in 0...90 {
                let x = Double(step) / 90 * 1.1 - 0.05
                path.addLine(to: CGPoint(x: x, y: height(x)))
            }
            for step in stride(from: 90, through: 0, by: -1) {
                let x = Double(step) / 90 * 1.1 - 0.05
                let thickness = 0.06 + 0.07 * (0.5 + 0.5 * sin(x * 7 + phase))
                path.addLine(to: CGPoint(x: x, y: height(x) + thickness))
            }
            path.closeSubpath()
            c.saveGState()
            c.addPath(path)
            c.clip()
            let hue = CGFloat(r / 6)
            linear(c, colors: [rgb(0.10 + hue * 0.2, 0.9 - hue * 0.3, 0.62 + hue * 0.35, 0), rgb(0.1, 0.95, 0.69, 0.15), rgb(0.35, 0.6, 1, 0)], from: CGPoint(x: 0.2, y: 0.54), to: CGPoint(x: 0.8, y: 0.98))
            c.restoreGState()
        }
        // Low distant ridges anchor the flowing sky.
        for ridge in 0..<3 {
            let path = CGMutablePath()
            path.move(to: .zero)
            for step in 0...60 {
                let x = Double(step) / 60
                let h = 0.20 + Double(ridge) * 0.034 + 0.03 * sin(x * 16 + Double(ridge) * 2) + 0.014 * sin(x * 43)
                path.addLine(to: CGPoint(x: x, y: h))
            }
            path.addLine(to: CGPoint(x: 1, y: 0))
            path.closeSubpath()
            c.addPath(path)
            c.setFillColor(rgb(0.012, 0.025 + CGFloat(2 - ridge) * 0.008, 0.045 + CGFloat(2 - ridge) * 0.014))
            c.fillPath()
        }
        // Thin reflected light on the lake, in front of the silhouette.
        glow(c, x: 0.6, y: 0.075, rx: 0.55, ry: 0.14, color: rgb(0.06, 0.45, 0.40, 0.26))
        for i in 0..<28 {
            let y = CGFloat(i) * 0.0057
            let width = 0.18 + noise(i + 77) * 0.4
            let x = 0.55 - width / 2 + CGFloat(sin(t * 0.12 + Double(i))) * 0.012
            c.setStrokeColor(rgb(0.2, 0.8, 0.65, 0.025 + noise(i + 10) * 0.04))
            c.setLineWidth(0.00065)
            c.move(to: CGPoint(x: x, y: y))
            c.addLine(to: CGPoint(x: x + width, y: y))
            c.strokePath()
        }
    }

    static func cosmos(_ c: CGContext, _ t: Double) {
        linear(c, colors: [rgb(0.008, 0.012, 0.04), rgb(0.025, 0.018, 0.08)], from: .zero, to: CGPoint(x: 1, y: 1))
        let drift = CGFloat(sin(t * 0.055)) * 0.035
        for i in 0..<9 {
            let p = CGFloat(i) / 8
            let x = -0.05 + p * 1.15 + drift
            let y = 0.28 + p * 0.4 + CGFloat(sin(Double(i) * 1.3 + t * 0.045)) * 0.055
            glow(c, x: x, y: y, rx: 0.25, ry: 0.27, color: rgb(0.19 + p * 0.10, 0.08 + p * 0.13, 0.55, 0.18))
            glow(c, x: x + 0.045, y: y, rx: 0.15, ry: 0.12, color: rgb(0.05, 0.3, 0.6, 0.14))
        }
        stars(c, t, count: 230, minimumY: 0)
        // A quiet, shadowed planet with a luminous atmospheric rim.
        let px: CGFloat = 0.76 + drift * 0.15
        let py: CGFloat = 0.47
        glow(c, x: px, y: py, rx: 0.139, ry: 0.241, color: rgb(0.25, 0.39, 0.75, 0.22))
        c.saveGState()
        c.addEllipse(in: CGRect(x: px - 0.11, y: py - 0.19, width: 0.22, height: 0.38))
        c.clip()
        linear(c, colors: [rgb(0.22, 0.3, 0.47), rgb(0.035, 0.048, 0.10), rgb(0.006, 0.009, 0.024)], from: CGPoint(x: px - 0.12, y: py + 0.16), to: CGPoint(x: px + 0.08, y: py - 0.03))
        c.restoreGState()
        glow(c, x: 0.23, y: 0.71, rx: 0.032, ry: 0.055, color: rgb(0.65, 0.75, 1, 0.65))
        c.setFillColor(rgb(0.92, 0.94, 1, 0.95))
        c.fillEllipse(in: CGRect(x: 0.2289, y: 0.708, width: 0.0022, height: 0.0038))
    }

    static func ocean(_ c: CGContext, _ t: Double) {
        linear(c, colors: [rgb(0.018, 0.043, 0.10), rgb(0.045, 0.15, 0.19), rgb(0.008, 0.04, 0.075)], from: CGPoint(x: 0, y: 1), to: .zero)
        stars(c, t, count: 75, minimumY: 0.57)
        glow(c, x: 0.69, y: 0.77, rx: 0.17, ry: 0.29, color: rgb(0.50, 0.77, 0.85, 0.12))
        c.setFillColor(rgb(0.78, 0.87, 0.86, 0.9))
        c.fillEllipse(in: CGRect(x: 0.671, y: 0.738, width: 0.038, height: 0.065))
        glow(c, x: 0.66, y: 0.46, rx: 0.65, ry: 0.20, color: rgb(0.09, 0.47, 0.53, 0.2))
        for row in 0..<34 {
            let depth = Double(row) / 33
            let base = 0.49 - pow(depth, 1.5) * 0.57
            let amplitude = 0.0015 + pow(depth, 1.7) * 0.025
            let path = CGMutablePath()
            for step in 0...120 {
                let x = Double(step) / 120
                let phase = x * (24 - depth * 16) + t * (0.22 + depth * 0.28) + Double(row) * 1.7
                let y = base + sin(phase) * amplitude + sin(x * 19 - t * 0.13 + depth * 7) * amplitude * 0.4
                if step == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            let surface = CGMutablePath()
            surface.addPath(path)
            surface.addLine(to: CGPoint(x: 1, y: -0.1))
            surface.addLine(to: CGPoint(x: 0, y: -0.1))
            surface.closeSubpath()
            c.addPath(surface)
            c.setFillColor(rgb(0.013, 0.09 + CGFloat(depth) * 0.025, 0.14 + CGFloat(depth) * 0.025))
            c.fillPath()
            c.addPath(path)
            c.setLineWidth(0.0007 + CGFloat(depth) * 0.0012)
            c.setStrokeColor(rgb(0.19, 0.64, 0.68, 0.10 + CGFloat(depth) * 0.22))
            c.strokePath()
            if row % 2 == 0 {
                let reflection = 0.02 + depth * 0.17
                let x = 0.69 + sin(t * 0.2 + Double(row)) * reflection * 0.2
                c.setStrokeColor(rgb(0.66, 0.84, 0.81, 0.17 * (1 - CGFloat(depth) * 0.6)))
                c.setLineWidth(0.001)
                c.move(to: CGPoint(x: x - reflection, y: base))
                c.addLine(to: CGPoint(x: x + reflection, y: base))
                c.strokePath()
            }
        }
    }

    static func ember(_ c: CGContext, _ t: Double) {
        linear(c, colors: [rgb(0.028, 0.012, 0.025), rgb(0.11, 0.025, 0.025), rgb(0.19, 0.038, 0.015)], from: CGPoint(x: 0, y: 1), to: .zero)
        glow(c, x: 0.46, y: 0.02, rx: 0.8, ry: 0.75, color: rgb(0.75, 0.18, 0.025, 0.32))
        for i in 0..<7 {
            let phase = t * 0.12 + Double(i) * 0.9
            let x = 0.5 + CGFloat(sin(phase)) * 0.2
            let y = 0.13 + CGFloat(i) * 0.055
            glow(c, x: x, y: y, rx: 0.36, ry: 0.15, color: rgb(0.70, 0.15, 0.045, 0.08))
        }
        // Slow ribbons of hot air, with fine amber edges.
        for i in 0..<8 {
            let path = CGMutablePath()
            for step in 0...100 {
                let x = Double(step) / 100
                let y = 0.07 + Double(i) * 0.025 + 0.045 * sin(x * 9 + t * 0.16 + Double(i) * 0.3) + 0.018 * sin(x * 19 - t * 0.09)
                if step == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            c.addPath(path)
            c.setLineWidth(0.001 + CGFloat(i) * 0.00025)
            c.setStrokeColor(rgb(1, 0.36 + CGFloat(i) * 0.035, 0.10, 0.055))
            c.strokePath()
        }
        for i in 0..<95 {
            let seed = Double(noise(i * 7 + 1))
            let travel = seed + t * (0.012 + Double(noise(i + 42)) * 0.023)
            let y = travel - floor(travel)
            let x = Double(noise(i * 7 + 3)) + sin(t * 0.15 + Double(i)) * 0.027 * y
            let radius = CGFloat(0.0006 + Double(noise(i + 8)) * 0.0012)
            let alpha = CGFloat(sin(y * .pi)) * (0.3 + noise(i + 33) * 0.6)
            if i % 7 == 0 {
                glow(c, x: x, y: y, rx: radius * 5, ry: radius * 9, color: rgb(1, 0.34, 0.06, alpha * 0.45))
            }
            c.setFillColor(rgb(1, 0.45 + noise(i) * 0.4, 0.15, alpha))
            c.fillEllipse(in: CGRect(x: x, y: y, width: radius, height: radius * (1.7 + noise(i) * 1.7)))
        }
    }
}
