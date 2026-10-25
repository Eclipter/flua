import Foundation

enum NativeWallpaperStore {
    static let maximumSize = 16 * 1024 * 1024

    private static func defaultSurface() throws -> [String: Any] {
        let options = try PropertyListSerialization.data(fromPropertyList: ["values": [String: String]()], format: .binary, options: 0)
        let choice: [String: Any] = ["Provider": "default", "Files": [[String: String]](), "Configuration": Data()]
        let now = Date()
        return ["Content": ["Choices": [choice], "Shuffle": "$null", "EncodedOptionValues": options], "LastSet": now, "LastUse": now]
    }

    private static func isRestorableSurface(_ value: [String: Any]?, provider: String) -> Bool {
        guard let content = value?["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]], !choices.isEmpty else { return false }
        return choices.allSatisfy { choice in
            guard let candidate = choice["Provider"] as? String, !candidate.isEmpty else { return false }
            return candidate != provider
        }
    }

    static func choice(_ item: ProviderCatalog.Item, root: URL, provider: String) throws -> [String: Any] {
        guard item.kind == "image" || item.kind == "video" || builtInSceneKinds.contains(item.kind) else {
            throw NativeWallpaperError("Choose an available image, video or scene.")
        }
        var configuration: [String: Any] = [
            "version": 1, "kind": item.kind, "fit": item.fit,
            "speed": item.speed, "dimming": item.dimming,
            "modes": ["desktop": item.desktop.rawValue, "lockScreen": item.lockScreen.rawValue]
        ]
        if let policy = item.playbackPolicy?.clampedForExport {
            configuration["playbackPolicy"] = [
                "pauseOnBattery": policy.pauseOnBattery,
                "pauseOnLowPower": policy.pauseOnLowPower,
                "pauseOnLowBattery": policy.pauseOnLowBattery,
                "lowPowerThreshold": policy.lowPowerThreshold,
                "pauseOnFullscreen": policy.pauseOnFullscreen
            ]
        }
        var files: [[String: String]] = []
        if item.kind == "video" || item.kind == "image" {
            let media = root.appendingPathComponent("Media", isDirectory: true).resolvingSymlinksInPath()
            let url = root.appendingPathComponent(item.file).resolvingSymlinksInPath()
            guard item.file.hasPrefix("Media/"), !item.file.contains(".."),
                  url.deletingLastPathComponent() == media,
                  media.deletingLastPathComponent() == root.resolvingSymlinksInPath(),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  FileManager.default.isReadableFile(atPath: url.path) else {
                throw NativeWallpaperError("The selected media is missing or outside Flua’s media folder. Reimport it.")
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

    struct Assignment {
        var desktop: [String: Any]?
        var lockScreen: [String: Any]?
    }

    /// Freezes property-list dictionaries so worker tasks never share Foundation objects with the UI.
    struct AssignmentSnapshot: Sendable {
        private let data: Data

        init(_ assignments: [String: Assignment]) throws {
            let values = assignments.mapValues { assignment in
                var value: [String: Any] = [:]
                value["desktop"] = assignment.desktop
                value["lockScreen"] = assignment.lockScreen
                return value
            }
            data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        }

        func assignments() throws -> [String: Assignment] {
            guard let values = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: [String: Any]] else {
                throw NativeWallpaperError("The saved wallpaper choices could not be decoded.")
            }
            return values.mapValues { Assignment(desktop: $0["desktop"] as? [String: Any], lockScreen: $0["lockScreen"] as? [String: Any]) }
        }
    }

    static func assignments(from state: LibraryState, displays: [String], root: URL, provider: String, surface: WallpaperSurface? = nil) throws -> [String: Assignment] {
        let catalog = providerCatalog(from: state)
        var result: [String: Assignment] = [:]
        for display in displays {
            guard let saved = state.displays[display] else { continue }
            func resolve(_ selection: SurfaceAssignment?) throws -> [String: Any]? {
                guard let selection, let id = selection.wallpaperID else { return nil }
                guard var item = catalog.items.first(where: { $0.id == id }) else {
                    throw NativeWallpaperError("A saved wallpaper is unavailable or blocked. Update the saved choice before applying.")
                }
                item.desktop = selection.mode
                item.lockScreen = selection.mode
                return try choice(item, root: root, provider: provider)
            }
            let desktop = try resolve(saved.desktop)
            let lockScreen = try resolve(saved.lockScreen)
            let assignment: Assignment
            // macOS reuses Desktop sessions on lock, so each session needs both sources.
            if let desktop, let lockScreen {
                let paired = try pairedChoice(desktop: desktop, lockScreen: lockScreen)
                assignment = Assignment(desktop: paired, lockScreen: paired)
            } else {
                assignment = Assignment(desktop: surface == .lockScreen ? nil : desktop,
                                        lockScreen: surface == .desktop ? nil : lockScreen)
            }
            if assignment.desktop != nil || assignment.lockScreen != nil { result[display] = assignment }
        }
        guard !result.isEmpty else { throw NativeWallpaperError("Save a wallpaper choice for the targeted displays first.") }
        return result
    }

    static func pairedChoice(desktop: [String: Any], lockScreen: [String: Any]) throws -> [String: Any] {
        guard let provider = desktop["Provider"] as? String, lockScreen["Provider"] as? String == provider else { throw unsupported() }
        var files: [[String: String]] = []
        func configuration(_ choice: [String: Any]) throws -> [String: Any] {
            guard let data = choice["Configuration"] as? Data,
                  var value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  value["version"] as? Int == 1,
                  let sourceFiles = choice["Files"] as? [[String: String]] else { throw unsupported() }
            if let index = value["fileIndex"] as? Int {
                guard sourceFiles.indices.contains(index) else { throw unsupported() }
                let file = sourceFiles[index]
                if !files.contains(file) { files.append(file) }
                value["fileIndex"] = files.firstIndex(of: file)!
            }
            return value
        }
        let desktopConfiguration = try configuration(desktop)
        let lockConfiguration = try configuration(lockScreen)
        var paired: [String: Any] = ["version": 2, "surfaces": ["desktop": desktopConfiguration, "lockScreen": lockConfiguration]]
        paired["playbackPolicy"] = desktopConfiguration["playbackPolicy"]
        return ["Provider": provider, "Files": files,
                "Configuration": try JSONSerialization.data(withJSONObject: paired, options: [.sortedKeys])]
    }

    static func applying(_ assignments: [String: Assignment], mirrored: Bool, to data: Data,
                         spaceIDs: [String] = [], now: Date = Date()) throws -> Data {
        var store = try decode(data)
        guard let systemDefault = store["SystemDefault"] as? [String: Any],
              (store["AllSpacesAndDisplays"] == nil || store["AllSpacesAndDisplays"] as? String == "$null" || store["AllSpacesAndDisplays"] is [String: Any]),
              var displays = store["Displays"] as? [String: Any],
              var spaces = store["Spaces"] as? [String: Any], !assignments.isEmpty else { throw unsupported() }
        if mirrored, let first = assignments.values.first {
            for assignment in assignments.values {
                for (left, right) in [(first.desktop, assignment.desktop), (first.lockScreen, assignment.lockScreen)] {
                    guard NSDictionary(dictionary: left ?? [:]).isEqual(to: right ?? [:]) else {
                        throw NativeWallpaperError("Mirrored displays have different saved choices. Select Mirrored again to synchronize them before applying.")
                    }
                }
            }
        }
        let options = try PropertyListSerialization.data(fromPropertyList: ["values": [String: String]()], format: .binary, options: 0)
        func update(_ value: [String: Any], with assignment: Assignment) throws -> [String: Any] {
            var dictionary = value
            guard let type = dictionary["Type"] as? String,
                  ["individual", "linked", "desktop", "idle"].contains(type) else { throw unsupported() }
            if type == "linked" {
                guard let linked = dictionary["Linked"] as? [String: Any] else { throw unsupported() }
                dictionary["Desktop"] = linked
                dictionary["Idle"] = linked
            }
            for (surface, choice) in [("Desktop", assignment.desktop), ("Idle", assignment.lockScreen)] {
                guard let choice else { continue }
                var settings = dictionary[surface] as? [String: Any] ?? [:]
                settings["Content"] = ["Choices": [choice], "Shuffle": "$null", "EncodedOptionValues": options]
                settings["LastSet"] = now
                settings["LastUse"] = now
                dictionary[surface] = settings
            }
            dictionary.removeValue(forKey: "Linked")
            dictionary["Type"] = "individual"
            return dictionary
        }
        let global = store["AllSpacesAndDisplays"] as? [String: Any] ?? [:]
        let fallback = global.isEmpty ? systemDefault : global
        guard let fallbackType = fallback["Type"] as? String,
              ["individual", "linked", "desktop", "idle"].contains(fallbackType) else { throw unsupported() }
        let inheritedDisplays = displays
        for id in spaceIDs where spaces[id] == nil {
            spaces[id] = ["Default": fallback, "Displays": inheritedDisplays]
        }
        // Resolve inheritance before writing overrides so untargeted displays keep their choices.
        for (id, assignment) in assignments {
            guard displays[id] == nil || displays[id] is [String: Any] else { throw unsupported() }
            displays[id] = try update(displays[id] as? [String: Any] ?? fallback, with: assignment)
        }
        for (id, value) in spaces {
            guard var space = value as? [String: Any],
                  var overrides = space["Displays"] as? [String: Any] else { throw unsupported() }
            for (display, assignment) in assignments {
                guard overrides[display] == nil || overrides[display] is [String: Any] else { throw unsupported() }
                let inherited = (store["Displays"] as? [String: Any])?[display] as? [String: Any] ?? fallback
                overrides[display] = try update(overrides[display] as? [String: Any] ?? space["Default"] as? [String: Any] ?? inherited, with: assignment)
            }
            if mirrored, let assignment = assignments.values.first, let value = space["Default"] as? [String: Any] {
                space["Default"] = try update(value, with: assignment)
            }
            space["Displays"] = overrides
            spaces[id] = space
        }
        if mirrored, let assignment = assignments.values.first {
            store["SystemDefault"] = try update(systemDefault, with: assignment)
            store["AllSpacesAndDisplays"] = try update(fallback, with: assignment)
        }
        if !mirrored {
            store["SystemDefault"] = fallback
            store["AllSpacesAndDisplays"] = "$null"
        }
        store["Displays"] = displays
        store["Spaces"] = spaces
        return try PropertyListSerialization.data(fromPropertyList: store, format: .binary, options: 0)
    }

    static func replacing(_ assignments: [String: Assignment], displays: [String], provider: String,
                         mirrored: Bool, in data: Data, baseline: Data?, clearingUnassigned: Bool = true,
                         spaceIDs: [String] = []) throws -> Data {
        if !clearingUnassigned {
            guard !assignments.isEmpty else { return data }
            return try applying(assignments, mirrored: mirrored, to: data, spaceIDs: spaceIDs)
        }
        let restored = try stopping(displays: displays, provider: provider, in: data, baseline: baseline,
                                    mirrored: mirrored)
        guard !assignments.isEmpty else { return restored }
        return try applying(assignments, mirrored: mirrored, to: restored, spaceIDs: spaceIDs)
    }

    static func matches(_ assignments: [String: Assignment], mirrored: Bool, in data: Data) -> Bool {
        guard let store = try? decode(data), !assignments.isEmpty,
              let displays = store["Displays"] as? [String: Any],
              let spaces = store["Spaces"] as? [String: Any] else { return false }
        if !mirrored, store["AllSpacesAndDisplays"] != nil && store["AllSpacesAndDisplays"] as? String != "$null" { return false }
        func check(_ value: Any?, _ assignment: Assignment) -> Bool {
            guard let dictionary = value as? [String: Any] else { return false }
            for (surface, expected) in [("Desktop", assignment.desktop), ("Idle", assignment.lockScreen)] {
                guard let expected else { continue }
                guard let settings = dictionary[surface] as? [String: Any],
                      let content = settings["Content"] as? [String: Any],
                      let choices = content["Choices"] as? [[String: Any]], choices.count == 1,
                      NSDictionary(dictionary: choices[0]).isEqual(to: expected) else { return false }
            }
            return true
        }
        for (id, assignment) in assignments {
            guard check(displays[id], assignment) else { return false }
            for value in spaces.values {
                guard let space = value as? [String: Any], let overrides = space["Displays"] as? [String: Any],
                      check(overrides[id], assignment) else { return false }
                if mirrored, let value = space["Default"], !check(value, assignment) { return false }
            }
            if mirrored && (!check(store["SystemDefault"], assignment) || !check(store["AllSpacesAndDisplays"], assignment)) { return false }
        }
        return true
    }

    static func applicationMatches(_ assignments: [String: Assignment], mirrored: Bool, expected: Data, in actual: Data) -> Bool {
        guard matches(assignments, mirrored: mirrored, in: actual) else { return false }
        if mirrored { return stopMatches(expected, in: actual) }
        guard var expectedStore = try? decode(expected), let actualStore = try? decode(actual) else { return false }
        // macOS can copy targeted choices into defaults when reconciling per-display assignments.
        func reconcile(_ expected: Any?, with actual: Any?) -> Any? {
            guard var expected = expected as? [String: Any], let actual = actual as? [String: Any] else { return expected }
            for surface in ["Desktop", "Idle"] {
                guard var settings = expected[surface] as? [String: Any],
                      var content = settings["Content"] as? [String: Any],
                      let actualSettings = actual[surface] as? [String: Any],
                      let actualContent = actualSettings["Content"] as? [String: Any],
                      let choices = actualContent["Choices"] as? [[String: Any]], choices.count == 1,
                      assignments.values.contains(where: {
                          guard let choice = surface == "Desktop" ? $0.desktop : $0.lockScreen else { return false }
                          return NSDictionary(dictionary: choice).isEqual(to: choices[0])
                      }) else { continue }
                content["Choices"] = choices
                settings["Content"] = content
                expected[surface] = settings
            }
            return expected
        }
        expectedStore["SystemDefault"] = reconcile(expectedStore["SystemDefault"], with: actualStore["SystemDefault"])
        if var spaces = expectedStore["Spaces"] as? [String: Any], let actualSpaces = actualStore["Spaces"] as? [String: Any] {
            for (id, value) in spaces {
                guard var space = value as? [String: Any], let actualSpace = actualSpaces[id] as? [String: Any] else { continue }
                space["Default"] = reconcile(space["Default"], with: actualSpace["Default"])
                spaces[id] = space
            }
            expectedStore["Spaces"] = spaces
        }
        guard let reconciled = try? PropertyListSerialization.data(fromPropertyList: expectedStore, format: .binary, options: 0) else { return false }
        return stopMatches(reconciled, in: actual)
    }

    static func stopping(displays targets: [String], provider: String, in data: Data, baseline: Data?, captureBaseline: Bool = false,
                         mirrored: Bool = false) throws -> Data {
        var store = try decode(data)
        let saved = baseline.flatMap { try? decode($0) }
        func fallback(_ store: [String: Any]) throws -> [String: Any] {
            guard store["AllSpacesAndDisplays"] == nil || store["AllSpacesAndDisplays"] as? String == "$null" || store["AllSpacesAndDisplays"] is [String: Any] else { throw unsupported() }
            let global = store["AllSpacesAndDisplays"] as? [String: Any] ?? [:]
            guard let value = global.isEmpty ? store["SystemDefault"] as? [String: Any] : global,
                  let type = value["Type"] as? String, ["individual", "linked", "desktop", "idle"].contains(type) else { throw unsupported() }
            return value
        }
        let inherited = try fallback(store)
        let macOSDefaultSurface = try Self.defaultSurface()
        guard var displays = store["Displays"] as? [String: Any], var spaces = store["Spaces"] as? [String: Any] else { throw unsupported() }
        func surface(_ key: String, in value: [String: Any]) -> [String: Any]? {
            value[value["Type"] as? String == "linked" ? "Linked" : key] as? [String: Any]
        }
        func owned(_ value: [String: Any]?) -> Bool {
            guard let content = value?["Content"] as? [String: Any], let choices = content["Choices"] as? [[String: Any]] else { return false }
            return choices.contains { $0["Provider"] as? String == provider }
        }
        func restoredSurface(_ key: String, current: [String: Any], previous: [String: Any]?) -> [String: Any] {
            guard var content = current["Content"] as? [String: Any],
                  let choices = content["Choices"] as? [[String: Any]] else { return macOSDefaultSurface }
            let foreign = choices.filter { $0["Provider"] as? String != provider }
            if !foreign.isEmpty {
                content["Choices"] = foreign
                var result = current
                result["Content"] = content
                return result
            }
            if let previous, let replacement = surface(key, in: previous),
               Self.isRestorableSurface(replacement, provider: provider) {
                return replacement
            }
            return macOSDefaultSurface
        }
        func restore(_ current: [String: Any], from previous: [String: Any]?) throws -> [String: Any] {
            guard let type = current["Type"] as? String, ["individual", "linked", "desktop", "idle"].contains(type) else { throw unsupported() }
            var result = current
            for key in ["Desktop", "Idle"] where owned(surface(key, in: current)) {
                let replacement = restoredSurface(key, current: surface(key, in: current) ?? [:], previous: previous)
                if result["Type"] as? String == "linked" {
                    result["Desktop"] = result["Linked"]
                    result["Idle"] = result["Linked"]
                    result.removeValue(forKey: "Linked")
                    result["Type"] = "individual"
                }
                result[key] = replacement
            }
            return result
        }
        func preservingInheritedProviderChoices(in current: [String: Any]?, from source: [String: Any]) throws -> [String: Any]? {
            var result = current ?? ["Type": "individual"]
            guard let type = result["Type"] as? String, ["individual", "linked", "desktop", "idle"].contains(type) else { throw unsupported() }
            var inheritedSurfaces: [(String, [String: Any])] = []
            for key in ["Desktop", "Idle"] where surface(key, in: result) == nil {
                if let choice = surface(key, in: source), owned(choice) { inheritedSurfaces.append((key, choice)) }
            }
            guard !inheritedSurfaces.isEmpty else { return current }
            if result["Type"] as? String == "linked", let linked = result["Linked"] as? [String: Any] {
                result["Desktop"] = linked
                result["Idle"] = linked
                result.removeValue(forKey: "Linked")
            }
            for (key, choice) in inheritedSurfaces { result[key] = choice }
            result["Type"] = "individual"
            return result
        }
        func inheritedSource(_ preferred: [String: Any]?, over fallback: [String: Any]?) -> [String: Any] {
            var result: [String: Any] = ["Type": "individual"]
            for key in ["Desktop", "Idle"] {
                if let choice = preferred.flatMap({ surface(key, in: $0) }) ?? fallback.flatMap({ surface(key, in: $0) }) {
                    result[key] = choice
                }
            }
            return result
        }
        let savedFallback = saved.flatMap { try? fallback($0) }
        var changed = false
        var targetIDs = Set(targets)
        if captureBaseline {
            targetIDs.formUnion(displays.keys)
            for value in spaces.values {
                if let space = value as? [String: Any], let overrides = space["Displays"] as? [String: Any] { targetIDs.formUnion(overrides.keys) }
            }
        }
        for id in targetIDs {
            guard displays[id] == nil || displays[id] is [String: Any] else { throw unsupported() }
            let current = displays[id] as? [String: Any] ?? inherited
            let previous = (saved?["Displays"] as? [String: Any])?[id] as? [String: Any] ?? savedFallback
            let restored = try restore(current, from: previous)
            if !NSDictionary(dictionary: restored).isEqual(to: current) { displays[id] = restored; changed = true }
            for (spaceID, value) in spaces {
                guard var space = value as? [String: Any], var overrides = space["Displays"] as? [String: Any],
                      overrides[id] == nil || overrides[id] is [String: Any] else { throw unsupported() }
                let current = overrides[id] as? [String: Any] ?? space["Default"] as? [String: Any] ?? current
                let savedSpace = (saved?["Spaces"] as? [String: Any])?[spaceID] as? [String: Any]
                let prior = (savedSpace?["Displays"] as? [String: Any])?[id] as? [String: Any] ?? savedSpace?["Default"] as? [String: Any] ?? previous
                let restored = try restore(current, from: prior)
                if !NSDictionary(dictionary: restored).isEqual(to: current) {
                    overrides[id] = restored
                    space["Displays"] = overrides
                    spaces[spaceID] = space
                    changed = true
                }
            }
        }
        let hasProvider = try containsProvider(provider, in: data)
        if captureBaseline || mirrored || hasProvider {
            // Save the effective provider choices before restoring defaults that untargeted displays inherit.
            let currentFallback = try fallback(store)
            var untargetedIDs = Set(displays.keys)
            for value in spaces.values {
                guard let space = value as? [String: Any], let overrides = space["Displays"] as? [String: Any] else { throw unsupported() }
                untargetedIDs.formUnion(overrides.keys)
            }
            untargetedIDs.subtract(targetIDs)
            for id in displays.keys where !targetIDs.contains(id) {
                guard let current = displays[id] as? [String: Any] else { throw unsupported() }
                if let preserved = try preservingInheritedProviderChoices(in: current, from: currentFallback) { displays[id] = preserved }
            }
            for (spaceID, value) in spaces {
                guard var space = value as? [String: Any], var overrides = space["Displays"] as? [String: Any] else { throw unsupported() }
                let spaceDefault = space["Default"] as? [String: Any]
                for id in untargetedIDs {
                    guard overrides[id] == nil || overrides[id] is [String: Any] else { throw unsupported() }
                    let displaySource = inheritedSource(displays[id] as? [String: Any], over: currentFallback)
                    let source = inheritedSource(spaceDefault, over: displaySource)
                    if let preserved = try preservingInheritedProviderChoices(in: overrides[id] as? [String: Any], from: source) {
                        overrides[id] = preserved
                    }
                }
                space["Displays"] = overrides
                spaces[spaceID] = space
            }
            for key in ["SystemDefault", "AllSpacesAndDisplays"] {
                if let current = store[key] as? [String: Any], !current.isEmpty {
                    let previous = saved?[key] as? [String: Any]
                    store[key] = try restore(current, from: previous?.isEmpty == true ? savedFallback : previous ?? savedFallback)
                }
            }
            for (id, value) in spaces {
                guard var space = value as? [String: Any] else { throw unsupported() }
                if let current = space["Default"] as? [String: Any] {
                    let previous = (saved?["Spaces"] as? [String: Any])?[id] as? [String: Any]
                    space["Default"] = try restore(current, from: previous?["Default"] as? [String: Any] ?? savedFallback)
                }
                spaces[id] = space
            }
            store["Displays"] = displays
            store["Spaces"] = spaces
            if NSDictionary(dictionary: store).isEqual(to: try decode(data)) { return data }
            return try PropertyListSerialization.data(fromPropertyList: store, format: .binary, options: 0)
        }
        guard changed else { return data }
        // Materialize targeted overrides before removing the global override.
        store["SystemDefault"] = inherited
        store["AllSpacesAndDisplays"] = "$null"
        store["Displays"] = displays
        store["Spaces"] = spaces
        return try PropertyListSerialization.data(fromPropertyList: store, format: .binary, options: 0)
    }

    static func stopMatches(_ expected: Data, in actual: Data) -> Bool {
        storesMatch(expected, actual)
    }

    static func refreshing(_ replacement: [String: Any], provider: String, in data: Data) throws -> Data {
        let store = try decode(data)
        guard let defaults = store["SystemDefault"] as? [String: Any],
              let type = defaults["Type"] as? String,
              ["individual", "linked", "desktop", "idle"].contains(type),
              (store["AllSpacesAndDisplays"] is [String: Any] || store["AllSpacesAndDisplays"] as? String == "$null"),
              store["Displays"] is [String: Any], store["Spaces"] is [String: Any] else { throw unsupported() }
        guard let configuration = replacement["Configuration"] as? Data,
              let updated = try JSONSerialization.jsonObject(with: configuration) as? [String: Any] else { throw unsupported() }
        func refresh(_ value: Any) throws -> Any {
            if let values = value as? [Any] { return try values.map(refresh) }
            guard var dictionary = value as? [String: Any] else { return value }
            if dictionary["Provider"] as? String == provider,
               let oldData = dictionary["Configuration"] as? Data,
               var old = try? JSONSerialization.jsonObject(with: oldData) as? [String: Any],
               old["version"] as? Int == 2,
               var surfaces = old["surfaces"] as? [String: [String: Any]],
               let files = dictionary["Files"] as? [[String: String]],
               let replacementFiles = replacement["Files"] as? [[String: String]] {
                var changed = false
                for key in ["desktop", "lockScreen"] {
                    guard var configuration = surfaces[key], configuration["kind"] as? String == updated["kind"] as? String else { continue }
                    let sourceFiles: [[String: String]]
                    if let index = configuration["fileIndex"] as? Int {
                        guard files.indices.contains(index) else { throw unsupported() }
                        sourceFiles = [files[index]]
                    } else { sourceFiles = [] }
                    guard sourceFiles == replacementFiles else { continue }
                    let previous = configuration
                    for field in ["fit", "speed", "dimming", "trim", "still"] { configuration[field] = updated[field] }
                    if !NSDictionary(dictionary: previous).isEqual(to: configuration) {
                        surfaces[key] = configuration
                        changed = true
                    }
                }
                if changed {
                    old["surfaces"] = surfaces
                    dictionary["Configuration"] = try JSONSerialization.data(withJSONObject: old, options: [.sortedKeys])
                }
                return dictionary
            }
            if dictionary["Provider"] as? String == provider,
               let oldData = dictionary["Configuration"] as? Data,
               let old = try? JSONSerialization.jsonObject(with: oldData) as? [String: Any],
               old["version"] as? Int == 1,
               old["kind"] as? String == updated["kind"] as? String,
               let files = dictionary["Files"] as? [[String: String]],
               let replacementFiles = replacement["Files"] as? [[String: String]], files == replacementFiles {
                var configuration = old
                for key in ["fit", "speed", "dimming", "trim", "still"] { configuration[key] = updated[key] }
                let encoded = try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys])
                if !NSDictionary(dictionary: old).isEqual(to: configuration) { dictionary["Configuration"] = encoded }
                return dictionary
            }
            for (key, child) in dictionary { dictionary[key] = try refresh(child) }
            return dictionary
        }
        var refreshed = store
        for key in ["SystemDefault", "AllSpacesAndDisplays", "Displays", "Spaces"] {
            refreshed[key] = try refresh(store[key]!)
        }
        if NSDictionary(dictionary: store).isEqual(to: refreshed) { return data }
        return try PropertyListSerialization.data(fromPropertyList: refreshed, format: .binary, options: 0)
    }

    static func refreshMatches(_ expected: Data, in actual: Data, provider: String) -> Bool {
        guard let expected = try? decode(expected), let actual = try? decode(actual) else { return false }
        func check(_ expected: Any, _ actual: Any?) -> Bool {
            if let dictionary = expected as? [String: Any] {
                guard let actual = actual as? [String: Any] else { return false }
                if dictionary["Provider"] as? String == provider {
                    return NSDictionary(dictionary: dictionary).isEqual(to: actual)
                }
                return dictionary.allSatisfy { check($0.value, actual[$0.key]) }
            }
            if let values = expected as? [Any] {
                guard let actual = actual as? [Any], values.count == actual.count else { return false }
                return zip(values, actual).allSatisfy { check($0.0, $0.1) }
            }
            return true
        }
        return check(expected, actual)
    }

    static func containsProvider(_ provider: String, in data: Data) throws -> Bool {
        contains(provider, in: try decode(data))
    }

    private static func contains(_ provider: String, in value: Any) -> Bool {
        if let values = value as? [Any] { return values.contains { contains(provider, in: $0) } }
        guard let dictionary = value as? [String: Any] else { return false }
        return dictionary["Provider"] as? String == provider || dictionary.values.contains { contains(provider, in: $0) }
    }

    static func restoring(_ baseline: Data?, provider: String, in data: Data) throws -> Data {
        let current = try decode(data)
        let original = baseline.flatMap { try? decode($0) }
        let macOSDefaultSurface = try Self.defaultSurface()
        let defaultAssignment: [String: Any] = ["Type": "individual", "Desktop": macOSDefaultSurface, "Idle": macOSDefaultSurface]
        func validAssignment(_ value: [String: Any]?) -> [String: Any]? {
            guard let value, let type = value["Type"] as? String,
                  ["individual", "linked", "desktop", "idle"].contains(type) else { return nil }
            return value
        }
        let global = original?["AllSpacesAndDisplays"] as? [String: Any] ?? [:]
        let inherited = validAssignment(global.isEmpty ? original?["SystemDefault"] as? [String: Any] : global) ?? defaultAssignment
        func restore(_ value: Any, from saved: Any?, inherited: [String: Any]) throws -> Any {
            guard var dictionary = value as? [String: Any] else { throw unsupported() }
            if dictionary["Type"] != nil {
                let saved = validAssignment(saved as? [String: Any]) ?? inherited
                let affected = ["Desktop", "Idle", "Linked"].filter { surface in
                    guard let settings = dictionary[surface] else { return false }
                    return contains(provider, in: settings)
                }
                guard !affected.isEmpty else { return dictionary }
                guard let currentType = dictionary["Type"] as? String,
                      ["individual", "linked", "desktop", "idle"].contains(currentType) else { throw unsupported() }
                func replacement(_ surface: String) -> [String: Any] {
                    let key = saved["Type"] as? String == "linked" ? "Linked" : surface
                    guard let settings = saved[key] as? [String: Any],
                          Self.isRestorableSurface(settings, provider: provider) else { return macOSDefaultSurface }
                    return settings
                }
                var mixed = false
                for surface in affected {
                    if let settings = dictionary[surface] as? [String: Any],
                       var content = settings["Content"] as? [String: Any],
                       let choices = content["Choices"] as? [[String: Any]] {
                        let foreign = choices.filter { $0["Provider"] as? String != provider }
                        if !foreign.isEmpty {
                            content["Choices"] = foreign
                            var cleaned = settings
                            cleaned["Content"] = content
                            dictionary[surface] = cleaned
                            mixed = true
                        }
                    }
                }
                if mixed {
                    for surface in affected where contains(provider, in: dictionary[surface] ?? [:]) {
                        dictionary[surface] = replacement(surface)
                    }
                    return dictionary
                }
                if affected.contains("Linked") || (affected.contains("Desktop") && affected.contains("Idle")) {
                    let source = validAssignment(saved) ?? defaultAssignment
                    if source["Type"] as? String == "linked",
                       let linked = source["Linked"] as? [String: Any],
                       Self.isRestorableSurface(linked, provider: provider) {
                        dictionary["Type"] = source["Type"]
                        for surface in ["Desktop", "Idle", "Linked"] {
                            if let value = source[surface] as? [String: Any], Self.isRestorableSurface(value, provider: provider) {
                                dictionary[surface] = value
                            } else {
                                dictionary.removeValue(forKey: surface)
                            }
                        }
                    } else {
                        dictionary["Type"] = source["Type"]
                        for surface in ["Desktop", "Idle"] {
                            if let settings = source[surface] as? [String: Any],
                               Self.isRestorableSurface(settings, provider: provider) {
                                dictionary[surface] = settings
                            } else if affected.contains(surface) || affected.contains("Linked") {
                                dictionary[surface] = macOSDefaultSurface
                            } else {
                                dictionary.removeValue(forKey: surface)
                            }
                        }
                        if let linked = source["Linked"] as? [String: Any],
                           Self.isRestorableSurface(linked, provider: provider) {
                            dictionary["Linked"] = linked
                        } else {
                            dictionary.removeValue(forKey: "Linked")
                        }
                        if source["Type"] as? String == "linked" { dictionary["Type"] = "individual" }
                    }
                } else {
                    for surface in affected { dictionary[surface] = replacement(surface) }
                }
                return dictionary
            }
            let savedDictionary = saved as? [String: Any]
            let fallback = validAssignment(savedDictionary?["Default"] as? [String: Any]) ?? inherited
            for (key, child) in dictionary { dictionary[key] = try restore(child, from: savedDictionary?[key], inherited: fallback) }
            return dictionary
        }
        var result = current
        for key in ["SystemDefault", "AllSpacesAndDisplays", "Displays", "Spaces"] {
            if key == "AllSpacesAndDisplays", current[key] == nil || current[key] as? String == "$null" { continue }
            guard let value = current[key],
                  key != "SystemDefault" || validAssignment(value as? [String: Any]) != nil,
                  key != "Displays" || value is [String: Any], key != "Spaces" || value is [String: Any] else { throw unsupported() }
            let savedValue = original?[key]
            let fallback = key == "AllSpacesAndDisplays" && (savedValue as? [String: Any])?.isEmpty == true
                ? original?["SystemDefault"] : savedValue
            let restored = try restore(value, from: fallback, inherited: inherited)
            if key == "AllSpacesAndDisplays", contains(provider, in: value),
               (original?["AllSpacesAndDisplays"] as? [String: Any])?.isEmpty == true,
               let restored = restored as? [String: Any], let fallback = fallback as? [String: Any],
               NSDictionary(dictionary: restored).isEqual(to: fallback) {
                result[key] = [String: Any]()
            } else { result[key] = restored }
        }
        let encoded = try PropertyListSerialization.data(fromPropertyList: result, format: .binary, options: 0)
        guard !(try containsProvider(provider, in: encoded)) else { throw unsupported() }
        return NSDictionary(dictionary: current).isEqual(to: result) ? data : encoded
    }

    static func restorationMatches(_ expected: Data, in actual: Data) -> Bool {
        storesMatch(expected, actual)
    }

    private static func storesMatch(_ expected: Data, _ actual: Data) -> Bool {
        guard let expected = try? decode(expected), let actual = try? decode(actual) else { return false }
        return NSDictionary(dictionary: normalizedTimestamps(expected) as! [String: Any]).isEqual(to: normalizedTimestamps(actual) as! [String: Any])
    }

    private static func normalizedTimestamps(_ value: Any) -> Any {
        if let values = value as? [Any] { return values.map(normalizedTimestamps) }
        guard var dictionary = value as? [String: Any] else { return value }
        dictionary.removeValue(forKey: "LastSet")
        dictionary.removeValue(forKey: "LastUse")
        for (key, child) in dictionary { dictionary[key] = normalizedTimestamps(child) }
        return dictionary
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
