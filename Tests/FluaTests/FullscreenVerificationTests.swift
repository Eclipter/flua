import AppKit

// Run after make build; fullscreen is supported but not required.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
precondition(NSRunningApplication.runningApplications(withBundleIdentifier: "local.flua.desktop").isEmpty, "Quit Flua before verification")
let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
let process = Process()
process.executableURL = URL(fileURLWithPath: "/bin/zsh")
process.arguments = [root.appendingPathComponent("scripts/smoke.sh").path]
try process.run()
var sawPlayback = false
var failure: String?
let deadline = Date().addingTimeInterval(180)
while process.isRunning && Date() < deadline {
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
if process.isRunning {
    process.terminate()
    process.waitUntilExit()
    fatalError("Smoke did not complete within three minutes")
}
process.waitUntilExit()
precondition(process.terminationStatus == 0, "Full smoke failed")
precondition(failure == nil, failure ?? "")
precondition(sawPlayback, "The observer did not see live playback")
print("PASS: full smoke completed with only one playback window exposed and no application activation")
