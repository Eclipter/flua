import AppKit
import SwiftUI

enum AppAccent: String, CaseIterable {
    case system = "System"
    case blue = "Blue", purple = "Purple", pink = "Pink", red = "Red"
    case orange = "Orange", yellow = "Yellow", green = "Green", gray = "Gray"

    var swatch: NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            nativeColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    var color: Color { Color(nsColor: nativeColor) }

    var nativeColor: NSColor {
        // shortcut: AppKit exposes only the current accent; update these swatches if its palette changes.
        let rgb: (light: Int, dark: Int)
        switch self {
        case .system: return .controlAccentColor
        case .blue: rgb = (0x007AFF, 0x007AFF)
        case .purple: rgb = (0x953D96, 0xA550A7)
        case .pink: rgb = (0xF74F9E, 0xF74F9E)
        case .red: rgb = (0xE0383E, 0xFF5257)
        case .orange: rgb = (0xF7821B, 0xF7821B)
        case .yellow: rgb = (0xFFC726, 0xFFC600)
        case .green: rgb = (0x62BA46, 0x62BA46)
        case .gray: rgb = (0x989898, 0x8C8C8C)
        }
        return NSColor(name: "FluaAccent.\(rawValue)") { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb.dark : rgb.light
            return NSColor(srgbRed: Double((value >> 16) & 255) / 255,
                           green: Double((value >> 8) & 255) / 255,
                           blue: Double(value & 255) / 255, alpha: 1)
        }
    }
}
