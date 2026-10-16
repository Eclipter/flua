import Foundation
import AVFoundation
import ImageIO
import CoreGraphics

struct MediaInspection: Sendable {
    let facts: MediaFacts
    let color: String?

    static func load(url: URL, kind: String, thumbnail: Double = 0) async -> MediaInspection {
        var facts = MediaFacts()
        facts.bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        var image: CGImage?
        if kind == "image", let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                facts.width = properties[kCGImagePropertyPixelWidth] as? Int
                facts.height = properties[kCGImagePropertyPixelHeight] as? Int
                let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
                if [5, 6, 7, 8].contains(orientation) { swap(&facts.width, &facts.height) }
            }
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 64
            ] as CFDictionary)
        } else if kind == "video" {
            let asset = AVURLAsset(url: url)
            if let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0 {
                facts.sourceDuration = duration
            }
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) {
                let rect = CGRect(origin: .zero, size: size).applying(transform)
                if rect.width.isFinite, rect.height.isFinite, abs(rect.width) < Double(Int32.max), abs(rect.height) < Double(Int32.max) {
                    facts.width = Int(abs(rect.width).rounded())
                    facts.height = Int(abs(rect.height).rounded())
                }
            }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 64, height: 64)
            let time = thumbnail.isFinite ? max(0, min(thumbnail, max(0, (facts.sourceDuration ?? 0) - 1.0 / 600))) : 0
            image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
        }
        return MediaInspection(facts: facts, color: image.flatMap(averageColor))
    }

    private static func averageColor(_ image: CGImage) -> String? {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard rendered else { return nil }
        var red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            red += Double(pixels[i]); green += Double(pixels[i + 1]); blue += Double(pixels[i + 2]); alpha += Double(pixels[i + 3])
        }
        guard alpha > 0 else { return nil }
        return classifiedColor(red: red / alpha, green: green / alpha, blue: blue / alpha)
    }
}
