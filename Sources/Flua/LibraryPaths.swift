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

    static func isIsolatedVerificationRoot(_ root: URL, applicationSupport: URL) -> Bool {
        let protected = resolve(applicationSupport: applicationSupport).standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = root.standardizedFileURL.resolvingSymlinksInPath().path
        return !contains(protected, candidate) && !contains(candidate, protected)
    }

    private static func contains(_ parent: String, _ child: String) -> Bool {
        child.compare(parent, options: .caseInsensitive) == .orderedSame
            || child.range(of: parent.hasSuffix("/") ? parent : parent + "/", options: [.anchored, .caseInsensitive]) != nil
    }
}
