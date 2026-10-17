import Foundation

@main struct NativeWallpaperTests {
    static func main() throws {
        precondition(NativeWallpaper.agentPID("gui/501/com.apple.wallpaper.agent = {\n\tpid = 1234\n}") == 1234)
        for value in ["", "last exit reason = pid = 1234", "pid = 0", "pid = 1", "pid = -20", "pid = bad", "pid = 999999999999"] {
            precondition(NativeWallpaper.agentPID(value) == nil, value)
        }
        precondition(!NativeWallpaper.available)
        print("PASS: wallpaper-service PID parsing rejects missing, invalid and unsafe process IDs; the test process has no wallpaper extension")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Media"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Media/video.mov")
        let sourceData = Data("source must stay intact".utf8)
        try sourceData.write(to: source)
        var item = ProviderCatalog.Item(id: "clip", title: "Clip", kind: "video", file: "Media/video.mov", fit: "fit", speed: 1.5, dimming: 0.2, trimStart: 1, trimEnd: 3, still: 2)
        let choice = try NativeWallpaperStore.choice(item, root: root, provider: "local.flua.desktop.wallpaper")
        let configuration = try JSONSerialization.jsonObject(with: choice["Configuration"] as! Data) as! [String: Any]
        precondition(configuration["kind"] as? String == "video")
        precondition(configuration["trim"] as? [Double] == [1, 3])
        precondition(configuration["modes"] as? [String: String] == ["desktop": "still", "lockScreen": "animated"])
        precondition((choice["Files"] as? [[String: String]])?.first?["relative"] == source.resolvingSymlinksInPath().absoluteString)
        let preserved = try Data(contentsOf: source)
        precondition(preserved == sourceData)
        let old: [String: Any] = ["Type": "individual", "Desktop": ["Content": ["Choices": [["Provider": "old-desktop"]]]], "Idle": ["Content": ["Choices": [["Provider": "old-idle"]]]], "Keep": "metadata"]
        let store: [String: Any] = ["SystemDefault": old, "AllSpacesAndDisplays": [:], "Displays": ["display": old], "Spaces": ["space": ["Default": old, "Displays": ["display": old]]], "Keep": "root metadata"]
        func encode(_ value: Any) throws -> Data { try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0) }
        for type in ["individual", "linked", "desktop", "idle"] {
            var assignment = old
            assignment["Type"] = type
            assignment["Linked"] = ["Content": ["Choices": [["Provider": "old-linked"]]]]
            var variant = store
            variant["SystemDefault"] = assignment
            let converted = try NativeWallpaperStore.applying(choice, to: encode(variant))
            precondition(NativeWallpaperStore.matches(choice, in: converted))
            let decoded = try PropertyListSerialization.propertyList(from: converted, format: nil) as! [String: Any]
            let defaultAssignment = decoded["SystemDefault"] as! [String: Any]
            precondition(defaultAssignment["Type"] as? String == "individual" && defaultAssignment["Linked"] == nil)
        }
        let original = try encode(store)
        let updated = try NativeWallpaperStore.applying(choice, to: original, now: Date(timeIntervalSince1970: 100))
        precondition(NativeWallpaperStore.matches(choice, in: updated))
        let saved = try PropertyListSerialization.propertyList(from: updated, format: nil) as! [String: Any]
        precondition(saved["Keep"] as? String == "root metadata")
        precondition((saved["SystemDefault"] as? [String: Any])?["Keep"] as? String == "metadata")
        var changed = saved
        changed["Displays"] = ["display": old]
        let changedData = try encode(changed)
        precondition(!NativeWallpaperStore.matches(choice, in: changedData))
        for invalid: Any in [[], ["SystemDefault": [:]], ["SystemDefault": ["Type": "future"], "AllSpacesAndDisplays": [:], "Spaces": [:], "Displays": [:]], ["SystemDefault": old, "AllSpacesAndDisplays": [:], "Spaces": [], "Displays": [:]], ["SystemDefault": old, "AllSpacesAndDisplays": [], "Spaces": [:], "Displays": [:]]] {
            do { _ = try NativeWallpaperStore.applying(choice, to: encode(invalid)); preconditionFailure("Accepted unsupported store") }
            catch is NativeWallpaperError {}
        }
        do { _ = try NativeWallpaperStore.applying(choice, to: Data(repeating: 0, count: NativeWallpaperStore.maximumSize + 1)); preconditionFailure("Accepted oversized store") }
        catch is NativeWallpaperError {}
        for file in ["../video.mov", "Media/../../video.mov", source.path, "Other/video.mov", "Media/missing.mov"] {
            item.file = file
            do { _ = try NativeWallpaperStore.choice(item, root: root, provider: "test"); preconditionFailure("Accepted unsafe media") }
            catch is NativeWallpaperError {}
        }
        let outside = root.appendingPathComponent("outside.mov")
        try sourceData.write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Media/escape.mov"), withDestinationURL: outside)
        item.file = "Media/escape.mov"
        do { _ = try NativeWallpaperStore.choice(item, root: root, provider: "test"); preconditionFailure("Accepted escaped symlink") }
        catch is NativeWallpaperError {}
        item.kind = "aurora"
        item.file = ""
        let scene = try NativeWallpaperStore.choice(item, root: root, provider: "test")
        precondition((scene["Files"] as? [[String: String]])?.isEmpty == true)
        item.kind = "image"
        do { _ = try NativeWallpaperStore.choice(item, root: root, provider: "test"); preconditionFailure("Accepted still image as live wallpaper") }
        catch is NativeWallpaperError {}
        let finalSource = try Data(contentsOf: source)
        precondition(finalSource == sourceData)
        print("PASS: direct native choices, safe media paths, preserved source files, all display/Space assignments, metadata retention, verification and unsupported-store rejection")
    }
}
