import AppKit

// Builds the app through smoke; fullscreen is supported but not required.
func intersectsDisplay(_ window: [String: Any], displays: [CGRect]) -> Bool {
    guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
          let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return true }
    return displays.contains { frame.intersects($0) }
}

func backgroundWindows(_ windows: [[String: Any]], process: inout Int?) -> [[String: Any]] {
    if process == nil { process = windows.first?[kCGWindowOwnerPID as String] as? Int }
    guard let process else { return [] }
    return windows.filter { $0[kCGWindowOwnerPID as String] as? Int == process }
}

// An unexpected first window must remain visible to the strict checks below.
do {
    var process: Int?
    let unexpected: [String: Any] = [kCGWindowOwnerPID as String: 10, kCGWindowName as String: "Flua"]
    let playback: [String: Any] = [kCGWindowOwnerPID as String: 10, kCGWindowName as String: "Flua playback verification"]
    let startup: [String: Any] = [kCGWindowOwnerPID as String: 20, kCGWindowName as String: "Flua"]
    precondition(backgroundWindows([unexpected], process: &process).count == 1 && process == 10)
    precondition(backgroundWindows([playback, unexpected], process: &process).count == 2)
    precondition(backgroundWindows([startup], process: &process).isEmpty)
}
do {
    let displays = [CGRect(x: 0, y: 0, width: 1470, height: 956), CGRect(x: -1440, y: 0, width: 1440, height: 900)]
    func window(_ frame: CGRect) -> [String: Any] { [kCGWindowBounds as String: frame.dictionaryRepresentation] }
    precondition(!intersectsDisplay(window(CGRect(x: -20000, y: 20032, width: 1320, height: 892)), displays: displays))
    precondition(intersectsDisplay(window(CGRect(x: 1460, y: 20, width: 100, height: 100)), displays: displays))
    precondition(intersectsDisplay(window(CGRect(x: -1200, y: 20, width: 100, height: 100)), displays: displays))
    precondition(intersectsDisplay([:], displays: displays))
}
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let ready = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("flua-lock-\(UUID().uuidString)")
let start = ready.appendingPathExtension("start")
let lock = Process()
lock.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
lock.arguments = [root.appendingPathComponent("scripts/system-test-lock.py").path,
                  "fullscreen smoke observation", "/bin/zsh",
                  root.appendingPathComponent("scripts/smoke.sh").path]
lock.environment = ProcessInfo.processInfo.environment
lock.environment?["FLUA_SYSTEM_TEST_LOCK_READY_FILE"] = ready.path
lock.environment?["FLUA_SYSTEM_TEST_LOCK_START_FILE"] = start.path
try lock.run()
while lock.isRunning && !FileManager.default.fileExists(atPath: ready.path) {
    Thread.sleep(forTimeInterval: 0.02)
}
precondition(FileManager.default.fileExists(atPath: ready.path), "Could not acquire the Flua system-test lock")
try? FileManager.default.removeItem(at: ready)
let fluaIsRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "local.flua.desktop").isEmpty
_ = NSWorkspace.shared.frontmostApplication
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
try Data().write(to: start)
precondition(!fluaIsRunning, "Quit Flua before verification")
var lastForeground = foreground
var sawPlayback = false
var playbackProcess: Int?
var failure: String?
let deadline = Date().addingTimeInterval(180)
while lock.isRunning && Date() < deadline {
    let displays = NSScreen.screens.compactMap { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }.map(CGDisplayBounds)
    let visibleFluaWindows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []).filter {
        $0[kCGWindowOwnerName as String] as? String == "Flua" && ($0[kCGWindowAlpha as String] as? Double ?? 0) > 0.01
            && intersectsDisplay($0, displays: displays)
    }
    // Later startup checks intentionally show normal windows in separate processes.
    let windows = backgroundWindows(visibleFluaWindows, process: &playbackProcess)
    if windows.count > 1 { failure = "Verification exposed more than one window at once" }
    for window in windows {
        if window[kCGWindowName as String] as? String != "Flua playback verification" {
            failure = "Verification exposed a non-playback window: \(window[kCGWindowName as String] ?? "unknown")"
        }
        sawPlayback = true
    }
    let currentApplication = NSWorkspace.shared.frontmostApplication
    let currentForeground = currentApplication?.processIdentifier
    if currentForeground != lastForeground {
        let change = "Foreground changed from PID \(lastForeground.map(String.init) ?? "unknown") to \(currentApplication?.bundleIdentifier ?? "unknown") PID \(currentForeground.map(String.init) ?? "unknown")\n"
        FileHandle.standardError.write(Data(change.utf8))
        lastForeground = currentForeground
    }
    if currentForeground != foreground { failure = "Verification changed the foreground application" }
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
}
if lock.isRunning {
    lock.terminate()
    lock.waitUntilExit()
    fatalError("Smoke did not complete within three minutes")
}
lock.waitUntilExit()
precondition(lock.terminationStatus == 0, "Full smoke failed")
precondition(failure == nil, failure ?? "")
precondition(sawPlayback, "The observer did not see live playback")
print("PASS: full smoke completed with only one playback window exposed and no application activation")
