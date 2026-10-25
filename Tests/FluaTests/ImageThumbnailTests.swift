import Foundation
import ImageIO
import CoreGraphics

@main struct ImageThumbnailTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FluaImageThumbnailTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("rotated.jpg")
        let width = 2400
        let height = 1200
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(sourceURL as CFURL, "public.jpeg" as CFString, 1, nil) else {
            fatalError("Could not create oriented image fixture")
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyOrientation: 6,
            kCGImageDestinationLossyCompressionQuality: 1
        ] as CFDictionary)
        precondition(CGImageDestinationFinalize(destination), "Could not write oriented image fixture")

        let sourceBytes = try Data(contentsOf: sourceURL)
        let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        precondition(properties[kCGImagePropertyOrientation] as? Int == 6, "Fixture must carry EXIF orientation 6")
        precondition(properties[kCGImagePropertyPixelWidth] as? Int == width
                     && properties[kCGImagePropertyPixelHeight] as? Int == height,
                     "Fixture must remain landscape before its EXIF rotation")

        guard let thumbnail = ImageThumbnail.create(url: sourceURL) else {
            fatalError("ImageIO did not create a thumbnail")
        }
        precondition(max(thumbnail.width, thumbnail.height) <= ImageThumbnail.maximumDisplayPixelSize,
                     "Thumbnail exceeded its maximum pixel dimension")
        precondition(thumbnail.width == 240 && thumbnail.height == 480,
                     "Thumbnail did not apply the EXIF rotation at the expected size")
        let bytesAfterThumbnail = try Data(contentsOf: sourceURL)
        precondition(bytesAfterThumbnail == sourceBytes, "Thumbnail generation changed the source image")
        print("PASS: image thumbnails stay within \(ImageThumbnail.maximumDisplayPixelSize) pixels, apply EXIF orientation, and preserve source bytes")
    }
}
