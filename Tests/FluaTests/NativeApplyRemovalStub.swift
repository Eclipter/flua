import Foundation

struct NativeWallpaperError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum NativeWallpaper {
    static var catalogURL = URL(fileURLWithPath: "/unused")
    static let available = true
    static let explanation = "test stub"
    static let identifier = "test.flua"
    static let started = DispatchSemaphore(value: 0)
    static let release = DispatchSemaphore(value: 0)
    static func hasStarted() -> Bool { started.wait(timeout: .now()) == .success }
    static func apply(_ assignments: [String: NativeWallpaperStore.Assignment], targeting displays: [String], mirrored: Bool, root: URL, reloadUnchanged: Bool = true, clearingUnassigned: Bool = false) throws {
        started.signal()
        release.wait()
    }
    static func stop(displays: [String], mirrored: Bool, root: URL) throws -> Bool { true }
    static func remove(root: URL) throws {}
    static func refresh(_ item: ProviderCatalog.Item, root: URL) throws {}
}
