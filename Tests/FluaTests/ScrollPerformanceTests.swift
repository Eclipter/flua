import AppKit
import ScreenCaptureKit

private final class ScrollFrames: NSObject, SCStreamOutput {
    var times: [Double] = []

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              attachments.first?[.status] as? Int == SCFrameStatus.complete.rawValue else { return }
        times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
    }
}

@main struct ScrollPerformanceTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let app = Process()
        app.executableURL = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("Contents/MacOS/Flua")
        let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let phasesURL = directory.appendingPathComponent("scroll-phases.json")
        app.arguments = ["--data-dir", directory.appendingPathComponent("library").path,
                         "--preview-smoke", phasesURL.path, "--scroll-benchmark"]
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        try app.run()
        defer {
            if app.isRunning { app.terminate(); app.waitUntilExit() }
        }
        let ready = phasesURL.appendingPathExtension("ready")
        let deadline = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: ready.path), app.isRunning, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let value = try? String(contentsOf: ready, encoding: .utf8), let windowID = UInt32(value) else {
            throw NSError(domain: "ScrollPerformanceTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Flua did not publish a benchmark window within 30 seconds"])
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw NSError(domain: "ScrollPerformanceTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Benchmark window is unavailable"])
        }
        let configuration = SCStreamConfiguration()
        configuration.width = 720
        configuration.height = 480
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.showsCursor = false
        let frames = ScrollFrames()
        let queue = DispatchQueue(label: "Flua.ScrollFrameCapture")
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration, delegate: nil)
        try stream.addStreamOutput(frames, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        try Data().write(to: phasesURL.appendingPathExtension("start"))
        let completion = Date().addingTimeInterval(45)
        while app.isRunning, Date() < completion { try await Task.sleep(for: .milliseconds(50)) }
        // Closing the benchmark window can stop the stream before this call.
        try? await stream.stopCapture()
        let times = queue.sync { frames.times }
        guard !app.isRunning else {
            throw NSError(domain: "ScrollPerformanceTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Scroll benchmark exceeded 45 seconds"])
        }
        precondition(app.terminationStatus == 0, "Scroll benchmark did not complete")
        precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground, "Benchmark activated Flua")
        let phases = try JSONDecoder().decode([[Double]].self, from: Data(contentsOf: phasesURL))
        precondition(phases.count == 2, "Expected grid and inspector scroll phases")
        var metrics: [[String: Any]] = []
        for (name, phase) in zip(["grid", "inspector"], phases) {
            let samples = times.filter { $0 >= phase[0] + 0.5 && $0 < phase[1] - 0.5 }
            guard samples.count > 1 else {
                throw NSError(domain: "ScrollPerformanceTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "No captured frames for the " + name + " scroll phase"])
            }
            let gaps = zip(samples.dropFirst(), samples).map(-).sorted()
            let fps = Double(samples.count - 1) / (samples.last! - samples.first!)
            let p95 = gaps[Int(Double(gaps.count - 1) * 0.95)]
            let longest = gaps.last!
            metrics.append(["pane": name, "fps": fps, "p95Milliseconds": p95 * 1000, "longestGapMilliseconds": longest * 1000,
                            "passed": fps >= 45 && longest < 0.1])
        }
        let report = directory.appendingPathComponent("scroll-results.json")
        try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]).write(to: report)
        print(String(decoding: try Data(contentsOf: report), as: UTF8.self))
        fflush(stdout)
        precondition(metrics.allSatisfy { $0["passed"] as? Bool == true }, "Scrolling fell below 45 fps or stalled for 100 ms; see \(report.path)")
        print("PASS: visible grid and inspector scrolling; results:", report.path)
    }
}
