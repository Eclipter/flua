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
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27 &&
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
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion != 27 {
            return "Native Lock Screen playback has been verified on macOS 27. Other macOS versions are unavailable."
        }
        if !available { return "Lock Screen playback needs the wallpaper extension inside Flua.app." }
        return "Apply a video or scene directly from Flua. It animates on the Lock Screen on all displays, even after Flua quits. The underlying desktop shows a still frame. Applying briefly reloads the macOS wallpaper service."
    }
    static func register() throws {
        guard available else { throw NativeWallpaperError(explanation) }
        try run(registrationTool, ["-f", Bundle.main.bundlePath])
        try run("/usr/bin/pluginkit", ["-a", extensionURL.path])
        try run("/usr/bin/pluginkit", ["-e", "use", "-i", identifier])
        let result = try run("/usr/bin/pluginkit", ["-m", "-A", "-D", "-v", "-i", identifier])
        guard result.contains(extensionURL.path) || result.contains(extensionURL.resolvingSymlinksInPath().path) else {
            throw NativeWallpaperError("macOS did not register this copy of Flua. Keep the app in a permanent folder and retry setup.")
        }
    }
    static func apply(_ item: ProviderCatalog.Item, root: URL) throws {
        let choice = try NativeWallpaperStore.choice(item, root: root, provider: identifier)
        try register()
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
        let updated = try NativeWallpaperStore.applying(choice, to: previous)
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
        guard NativeWallpaperStore.matches(choice, in: try Data(contentsOf: store)) else {
            throw NativeWallpaperError("macOS did not keep the selected wallpaper. The previous settings are saved in NativeWallpaperBackup.plist in your library.")
        }
    }
    static func agentPID(_ status: String) -> pid_t? {
        guard let line = status.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("pid = ") }),
              let pid = Int32(line.split(separator: "=").last?.trimmingCharacters(in: .whitespaces) ?? ""), pid > 1 else { return nil }
        return pid
    }
    @discardableResult private static func run(_ executable: String, _ arguments: [String]) throws -> String {
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
        guard process.terminationStatus == 0 else {
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
