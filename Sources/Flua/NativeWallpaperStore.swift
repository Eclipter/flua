import Foundation

enum NativeWallpaperStore {
    static let maximumSize = 16 * 1024 * 1024

    static func choice(_ item: ProviderCatalog.Item, root: URL, provider: String) throws -> [String: Any] {
        guard item.kind == "video" || builtInSceneKinds.contains(item.kind) else {
            throw NativeWallpaperError("Choose a video or animated scene for the Lock Screen.")
        }
        var configuration: [String: Any] = [
            "version": 1, "kind": item.kind, "fit": item.fit,
            "speed": item.speed, "dimming": item.dimming,
            "modes": ["desktop": "still", "lockScreen": "animated"]
        ]
        var files: [[String: String]] = []
        if item.kind == "video" {
            let media = root.appendingPathComponent("Media", isDirectory: true).resolvingSymlinksInPath()
            let url = root.appendingPathComponent(item.file).resolvingSymlinksInPath()
            guard item.file.hasPrefix("Media/"), !item.file.contains(".."),
                  url.deletingLastPathComponent() == media,
                  media.deletingLastPathComponent() == root.resolvingSymlinksInPath(),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  FileManager.default.isReadableFile(atPath: url.path) else {
                throw NativeWallpaperError("The selected video is missing or outside Flua’s media folder. Reimport it.")
            }
            files = [["relative": url.absoluteString]]
            configuration["fileIndex"] = 0
        }
        if let start = item.trimStart, let end = item.trimEnd, start >= 0, end > start {
            configuration["trim"] = [start, end]
        }
        if let still = item.still { configuration["still"] = still }
        return ["Provider": provider, "Files": files,
                "Configuration": try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys])]
    }

    static func applying(_ choice: [String: Any], to data: Data, now: Date = Date()) throws -> Data {
        var store = try decode(data)
        guard let systemDefault = store["SystemDefault"] as? [String: Any],
              systemDefault["Type"] is String else { throw unsupported() }
        let options = try PropertyListSerialization.data(fromPropertyList: ["values": [String: String]()], format: .binary, options: 0)
        let content: [String: Any] = ["Choices": [choice], "Shuffle": "$null", "EncodedOptionValues": options]
        func update(_ value: Any) throws -> Any {
            guard var dictionary = value as? [String: Any] else { throw unsupported() }
            if let type = dictionary["Type"] as? String {
                guard ["individual", "linked", "desktop", "idle"].contains(type) else { throw unsupported() }
                for surface in ["Desktop", "Idle"] {
                    var settings = dictionary[surface] as? [String: Any] ?? [:]
                    settings["Content"] = content
                    settings["LastSet"] = now
                    settings["LastUse"] = now
                    dictionary[surface] = settings
                }
                dictionary.removeValue(forKey: "Linked")
                dictionary["Type"] = "individual"
            } else {
                for (key, child) in dictionary { dictionary[key] = try update(child) }
            }
            return dictionary
        }
        store["SystemDefault"] = try update(systemDefault)
        guard let global = store["AllSpacesAndDisplays"] as? [String: Any] else { throw unsupported() }
        store["AllSpacesAndDisplays"] = try update(global.isEmpty ? systemDefault : global)
        for key in ["Displays", "Spaces"] {
            guard let values = store[key] as? [String: Any] else { throw unsupported() }
            store[key] = try update(values)
        }
        return try PropertyListSerialization.data(fromPropertyList: store, format: .binary, options: 0)
    }

    static func matches(_ choice: [String: Any], in data: Data) -> Bool {
        guard let store = try? decode(data) else { return false }
        var count = 0
        func check(_ value: Any) -> Bool {
            guard let dictionary = value as? [String: Any] else { return false }
            if dictionary["Type"] != nil {
                for surface in ["Desktop", "Idle"] {
                    guard let settings = dictionary[surface] as? [String: Any],
                          let content = settings["Content"] as? [String: Any],
                          let choices = content["Choices"] as? [[String: Any]], choices.count == 1,
                          NSDictionary(dictionary: choices[0]).isEqual(to: choice) else { return false }
                }
                count += 1
                return true
            }
            return dictionary.values.allSatisfy(check)
        }
        return ["SystemDefault", "AllSpacesAndDisplays", "Displays", "Spaces"].allSatisfy {
            guard let value = store[$0] else { return false }
            return check(value)
        } && count >= 2
    }

    private static func decode(_ data: Data) throws -> [String: Any] {
        guard data.count <= maximumSize,
              let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { throw unsupported() }
        return value
    }
    private static func unsupported() -> NativeWallpaperError {
        NativeWallpaperError("This macOS wallpaper store has an unsupported format. Your existing wallpaper was preserved.")
    }
}
