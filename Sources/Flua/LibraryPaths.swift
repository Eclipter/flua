import Foundation

/// Resolve the application's local library directory.
enum LibraryPaths {
    static func resolve(applicationSupport base: URL, boundCatalog: URL? = nil) -> URL {
        // The provider can read only this catalog, so its parent is the library the build can play.
        if let boundCatalog, boundCatalog.lastPathComponent == "catalog.json" {
            return boundCatalog.deletingLastPathComponent()
        }
        return base.appendingPathComponent("Flua", isDirectory: true)
    }
}
