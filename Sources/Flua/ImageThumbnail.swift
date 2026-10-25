import Foundation
import ImageIO
import CoreGraphics

enum ImageThumbnail {
    static let maximumDisplayPixelSize = 480

    static func create(url: URL, maxPixelSize: Int = maximumDisplayPixelSize) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return create(source: source, maxPixelSize: maxPixelSize)
    }

    static func create(source: CGImageSource, maxPixelSize: Int = maximumDisplayPixelSize) -> CGImage? {
        guard maxPixelSize > 0 else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary)
    }
}
