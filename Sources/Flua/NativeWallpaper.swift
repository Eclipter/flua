import AppKit
import Darwin

enum NativeWallpaper {
    static var identifier: String {
        let info = NSDictionary(contentsOf: extensionURL.appendingPathComponent("Contents/Info.plist"))
        return info?["CFBundleIdentifier"] as? String ?? "local.flua.desktop.wallpaper"
    }
    static let registrationTool = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    static var extensionURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Extensions/FluaWallpaperExtension.appex")
    }
    static var available: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 &&
            FileManager.default.fileExists(atPath: extensionURL.path) &&
            FileManager.default.isExecutableFile(atPath: guardURL.path)
    }
    static var guardURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/FluaWallpaperGuard") }
    static var catalogURL: URL {
        let info = NSDictionary(contentsOf: extensionURL.appendingPathComponent("Contents/Info.plist"))
        if let path = info?["FLUACatalogPath"] as? String { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Flua/catalog.json")
    }
    static var explanation: String {
        if !available { return "Wallpaper playback needs the wallpaper extension inside Flua.app on macOS 27." }
        return "Apply the saved Desktop and Lock Screen choices and modes for the targeted displays. Saved choices and mode changes sync to displays with active native playback. Native playback continues after Flua quits. Unassigned surfaces keep their system wallpaper. Applying briefly reloads the macOS wallpaper service."
    }
    static func pluginPaths(in listing: String) -> [String] {
        listing.split(separator: "\n").compactMap { line in
            guard let path = line.split(separator: "\t").last, path.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: String(path)).resolvingSymlinksInPath().path
        }
    }
    static func register() throws {
        guard available else { throw NativeWallpaperError(explanation) }
        let current = extensionURL.resolvingSymlinksInPath().path
        let listed = try run("/usr/bin/pluginkit", ["-m", "-A", "-D", "-v", "-i", identifier], allowedStatuses: [0, 1])
        for path in pluginPaths(in: listed) where path != current {
            try run("/usr/bin/pluginkit", ["-r", path], allowedStatuses: [0, 1])
        }
        try run(registrationTool, ["-f", Bundle.main.bundlePath])
        try run("/usr/bin/pluginkit", ["-a", extensionURL.path])
        try run("/usr/bin/pluginkit", ["-e", "use", "-i", identifier])
        let elected = try run("/usr/bin/pluginkit", ["-m", "-v", "-i", identifier])
        guard pluginPaths(in: elected).contains(current) else {
            throw NativeWallpaperError("macOS did not register this copy of Flua. Keep the app in a permanent folder and retry setup.")
        }
    }
    static func apply(_ assignments: [String: NativeWallpaperStore.Assignment], targeting displays: [String], mirrored: Bool, root: URL) throws {
        guard !assignments.isEmpty else {
            _ = try stop(displays: displays, mirrored: mirrored, root: root)
            return
        }
        try register()
        let baselineURL = root.appendingPathComponent("NativeWallpaperBaseline.plist")
        try updateStore(root: root, baselineDisplays: displays, transform: { current in
            let baseline = FileManager.default.fileExists(atPath: baselineURL.path) ? try Data(contentsOf: baselineURL) : nil
            return try NativeWallpaperStore.replacing(assignments, displays: displays, provider: identifier,
                mirrored: mirrored, in: current, baseline: baseline)
        }, verify: { actual, expected in
            NativeWallpaperStore.matches(assignments, mirrored: mirrored, in: actual)
                && NativeWallpaperStore.stopMatches(expected, in: actual)
        })
    }
    static func stop(displays: [String], mirrored: Bool, root: URL) throws -> Bool {
        guard available else { throw NativeWallpaperError(explanation) }
        let url = root.appendingPathComponent("NativeWallpaperBaseline.plist")
        let baseline = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        let store = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        let current = try Data(contentsOf: store)
        guard try NativeWallpaperStore.stopping(displays: displays, provider: identifier, in: current, baseline: baseline, mirrored: mirrored) != current else { return false }
        try updateStore(root: root, transform: {
            try NativeWallpaperStore.stopping(displays: displays, provider: identifier, in: $0, baseline: baseline, mirrored: mirrored)
        }, verify: { actual, expected in NativeWallpaperStore.stopMatches(expected, in: actual) })
        return true
    }

    static func refresh(_ item: ProviderCatalog.Item, root: URL) throws {
        let replacement = try NativeWallpaperStore.choice(item, root: root, provider: identifier)
        let store = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        let attributes = try FileManager.default.attributesOfItem(atPath: store.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= NativeWallpaperStore.maximumSize else {
            throw NativeWallpaperError("The macOS wallpaper store could not be read safely.")
        }
        let current = try Data(contentsOf: store)
        guard try NativeWallpaperStore.refreshing(replacement, provider: identifier, in: current) != current else { return }
        try updateStore(root: root, transform: { try NativeWallpaperStore.refreshing(replacement, provider: identifier, in: $0) },
                        verify: { actual, expected in NativeWallpaperStore.refreshMatches(expected, in: actual, provider: identifier) })
    }
    static func remove(root: URL) throws {
        guard available else { throw NativeWallpaperError(explanation) }
        let secondaryStore = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index_v2.plist")
        if FileManager.default.fileExists(atPath: secondaryStore.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: secondaryStore.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= NativeWallpaperStore.maximumSize,
                  try !NativeWallpaperStore.containsProvider(identifier, in: Data(contentsOf: secondaryStore)) else {
                throw NativeWallpaperError("Another macOS wallpaper store still uses Flua. Choose another wallpaper in System Settings, then retry removal.")
            }
        }
        let baseline = root.appendingPathComponent("NativeWallpaperBaseline.plist")
        let restore: (Data) throws -> Data = { current in
            guard try NativeWallpaperStore.containsProvider(identifier, in: current) else { return current }
            guard FileManager.default.fileExists(atPath: baseline.path) else {
                throw NativeWallpaperError("No original wallpaper was saved by this library. Choose another wallpaper in System Settings, then retry removal.")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: baseline.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= NativeWallpaperStore.maximumSize else {
                throw NativeWallpaperError("The original wallpaper backup could not be read safely. Choose another wallpaper in System Settings, then retry removal.")
            }
            return try NativeWallpaperStore.restoring(Data(contentsOf: baseline), provider: identifier, in: current)
        }
        let verify: (Data, Data) -> Bool = { NativeWallpaperStore.restorationMatches($1, in: $0) }
        try updateStore(root: root, transform: restore, verify: verify)
        try run("/usr/bin/pluginkit", ["-r", extensionURL.path])
        try run(registrationTool, ["-u", Bundle.main.bundlePath])
        let registered = try run("/usr/bin/pluginkit", ["-m", "-A", "-D", "-v", "-i", identifier], allowedStatuses: [0, 1])
        guard !registered.contains(extensionURL.path),
              !registered.contains(extensionURL.resolvingSymlinksInPath().path) else {
            throw NativeWallpaperError("The previous wallpaper was restored, but macOS still lists this provider. Retry removal.")
        }
        // Unregistration can make the host persist a cached per-display choice after the first reload.
        Thread.sleep(forTimeInterval: 1)
        try updateStore(root: root, transform: restore, verify: verify)
    }
    private static func updateStore(root: URL, baselineDisplays: [String]? = nil, transform: (Data) throws -> Data, verify: (Data, Data) -> Bool) throws {
        let store = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        let lockURL = store.deletingLastPathComponent().appendingPathComponent(".flua-apply.lock")
        let lock = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw NativeWallpaperError("Could not lock the wallpaper store. No wallpaper was changed.") }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw NativeWallpaperError("Another Flua instance is applying a wallpaper. Retry shortly.") }
        let agent = try run("/bin/launchctl", ["print", "gui/\(getuid())/com.apple.wallpaper.agent"])
        guard let pid = agentPID(agent) else { throw NativeWallpaperError("The macOS wallpaper service is unavailable. Retry shortly.") }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = guardURL
        process.arguments = [String(pid)]
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
        }
        guard output.fileHandleForReading.readData(ofLength: 6) == Data("ready\n".utf8) else {
            throw NativeWallpaperError("Could not pause the wallpaper service safely. Your wallpaper was preserved.")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: store.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= NativeWallpaperStore.maximumSize else {
            throw NativeWallpaperError("The macOS wallpaper store could not be read safely.")
        }
        let previous = try Data(contentsOf: store)
        if let baselineDisplays {
            let url = root.appendingPathComponent("NativeWallpaperBaseline.plist")
            let saved = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
            if try NativeWallpaperStore.shouldCaptureBaseline(saved, provider: identifier, in: previous) {
                let baseline = try NativeWallpaperStore.stopping(displays: baselineDisplays, provider: identifier, in: previous, baseline: saved, captureBaseline: true)
                try baseline.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
        let updated = try transform(previous)
        guard updated != previous else { return }
        let backup = root.appendingPathComponent("NativeWallpaperBackup.plist")
        try previous.write(to: backup, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        guard process.isRunning else { throw NativeWallpaperError("Applying took too long. Your wallpaper was preserved; retry shortly.") }
        try updated.write(to: store, options: .atomic)
        try input.fileHandleForWriting.write(contentsOf: Data("k".utf8))
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NativeWallpaperError("macOS could not reload the wallpaper. The previous settings are saved in NativeWallpaperBackup.plist in your library.")
        }
        // The restarted host rewrites rejected stores after decoding them.
        Thread.sleep(forTimeInterval: 1)
        guard verify(try Data(contentsOf: store), updated) else {
            throw NativeWallpaperError("macOS did not keep the selected wallpaper. The previous settings are saved in NativeWallpaperBackup.plist in your library.")
        }
    }
    static func agentPID(_ status: String) -> pid_t? {
        guard let line = status.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("pid = ") }),
              let pid = Int32(line.split(separator: "=").last?.trimmingCharacters(in: .whitespaces) ?? ""), pid > 1 else { return nil }
        return pid
    }
    @discardableResult private static func run(_ executable: String, _ arguments: [String], allowedStatuses: [Int32] = [0]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard allowedStatuses.contains(process.terminationStatus) else {
            throw NativeWallpaperError(message.isEmpty ? "macOS could not register the wallpaper provider. Retry setup." : message)
        }
        return message
    }
}

struct NativeWallpaperError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
