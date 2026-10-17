import AppKit

enum MenuBarIcon {
    static let sakura: NSImage = {
        guard let url = Bundle.module.url(forResource: "MenuBarSakura", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            preconditionFailure("The bundled sakura menu bar icon is missing or unreadable")
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = "Flua"
        return image
    }()
}
