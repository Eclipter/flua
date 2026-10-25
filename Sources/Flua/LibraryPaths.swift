import Foundation

/// Resolve the application's local library directory.
enum LibraryPaths {
    static func isVerification(arguments: [String]) -> Bool {
        ["--smoke-test", "--startup-smoke", "--preview-smoke", "--scroll-benchmark", "--accessibility-audit"].contains { arguments.contains($0) }
    }

    static func launchConfiguration(arguments: [String], applicationSupport: URL, boundCatalog: URL? = nil) throws -> (root: URL, systemPlaybackEnabled: Bool) {
        let verification = isVerification(arguments: arguments)
        let index = arguments.firstIndex(of: "--data-dir")
        let path = index.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        if verification {
            guard let path, !path.isEmpty, !path.hasPrefix("--") else {
                throw LaunchError("Smoke verification requires an isolated --data-dir.")
            }
            guard isIsolatedVerificationRoot(URL(fileURLWithPath: path, isDirectory: true), applicationSupport: applicationSupport) else {
                throw LaunchError("Verification --data-dir must not overlap the Flua Application Support library.")
            }
        }
        let root = path.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? resolve(applicationSupport: applicationSupport, boundCatalog: boundCatalog)
        return (root, !verification)
    }

    private struct LaunchError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

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
