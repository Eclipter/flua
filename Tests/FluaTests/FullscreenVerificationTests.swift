import AppKit

// Builds the app through smoke; fullscreen is supported but not required.
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
let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
try Data().write(to: start)
precondition(!fluaIsRunning, "Quit Flua before verification")
var sawPlayback = false
var failure: String?
let deadline = Date().addingTimeInterval(180)
while lock.isRunning && Date() < deadline {
    let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []).filter {
        $0[kCGWindowOwnerName as String] as? String == "Flua" && ($0[kCGWindowAlpha as String] as? Double ?? 0) > 0.01
    }
    if windows.count > 1 { failure = "Verification exposed more than one window at once" }
    for window in windows {
        if window[kCGWindowName as String] as? String != "Flua playback verification" {
            failure = "Verification exposed a non-playback window: \(window[kCGWindowName as String] ?? "unknown")"
        }
        sawPlayback = true
    }
    if NSWorkspace.shared.frontmostApplication?.processIdentifier != foreground { failure = "Verification changed the foreground application" }
    Thread.sleep(forTimeInterval: 0.02)
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
