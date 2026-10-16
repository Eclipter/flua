import Foundation

/// Resolve the application's local library directory.
enum LibraryPaths {
    static func resolve(applicationSupport base: URL) -> URL {
        base.appendingPathComponent("Flua", isDirectory: true)
    }
}
