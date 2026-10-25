import Foundation

@main struct NativeWallpaperTests {
    static func main() throws {
        precondition(NativeWallpaper.agentPID("gui/501/com.apple.wallpaper.agent = {\n\tpid = 1234\n}") == 1234)
        for value in ["", "last exit reason = pid = 1234", "pid = 0", "pid = 1", "pid = -20", "pid = bad", "pid = 999999999999"] {
            precondition(NativeWallpaper.agentPID(value) == nil, value)
        }
        precondition(!NativeWallpaper.available)
        let plugins = NativeWallpaper.pluginPaths(in: "+    local.flua.desktop.wallpaper(0.1)\tUUID\t2026-10-17 17:34:16 +0000\t/tmp/Other.app/Contents/Extensions/FluaWallpaperExtension.appex\nnot a plugin\n")
        precondition(plugins == [URL(fileURLWithPath: "/tmp/Other.app/Contents/Extensions/FluaWallpaperExtension.appex").resolvingSymlinksInPath().path])
        let desktopSpace = "01A02D9D-E47A-49BD-B318-40AB354F7BE1"
        let fullscreenSpace = "C14AF1A4-DEF2-D13C-9ADA-DC0C8ACEF575"
        precondition(NativeWallpaper.spaceIDs(in: [
            ["Spaces": [["uuid": desktopSpace], ["uuid": fullscreenSpace], ["uuid": desktopSpace], ["uuid": "bad"], ["uuid": 7]]],
            ["Spaces": [["uuid": "E0A8918C-AC46-4E34-954D-4B17B65FF17E"]]],
            ["Spaces": "invalid"], ["uuid": "EB62FE8A-A020-4084-BD38-F48844D9C499"]
        ]) == [desktopSpace, fullscreenSpace, "E0A8918C-AC46-4E34-954D-4B17B65FF17E"].sorted())
        print("PASS: wallpaper-service PID parsing rejects missing, invalid and unsafe process IDs; the test process has no wallpaper extension")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Media"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let baselineURL = root.appendingPathComponent("baseline.plist")
        precondition(NativeWallpaper.readBaseline(at: baselineURL) == nil)
        let baselineBytes = Data("baseline".utf8)
        try baselineBytes.write(to: baselineURL)
        precondition(NativeWallpaper.readBaseline(at: baselineURL) == baselineBytes)
        let baselineDirectory = root.appendingPathComponent("baseline-directory")
        try FileManager.default.createDirectory(at: baselineDirectory, withIntermediateDirectories: false)
        precondition(NativeWallpaper.readBaseline(at: baselineDirectory) == nil)
        let baselineSymlink = root.appendingPathComponent("baseline-symlink.plist")
        try FileManager.default.createSymbolicLink(at: baselineSymlink, withDestinationURL: baselineURL)
        precondition(NativeWallpaper.readBaseline(at: baselineSymlink) == nil)
        let oversizedBaseline = root.appendingPathComponent("baseline-oversized.plist")
        precondition(FileManager.default.createFile(atPath: oversizedBaseline.path, contents: Data()))
        let oversizedHandle = try FileHandle(forWritingTo: oversizedBaseline)
        try oversizedHandle.truncate(atOffset: UInt64(NativeWallpaperStore.maximumSize + 1))
        try oversizedHandle.close()
        precondition(NativeWallpaper.readBaseline(at: oversizedBaseline) == nil)
        print("PASS: baseline loading accepts bounded regular files and rejects missing files, directories, symlinks and oversized files")
        let source = root.appendingPathComponent("Media/video.mov")
        let sourceData = Data("source must stay intact".utf8)
        try sourceData.write(to: source)
        let imageSource = root.appendingPathComponent("Media/image.png")
        try Data("image source".utf8).write(to: imageSource)
        var item = ProviderCatalog.Item(id: "clip", title: "Clip", kind: "video", file: "Media/video.mov", fit: "fit", speed: 1.5, dimming: 0.2, trimStart: 1, trimEnd: 3, still: 2)
        item.desktop = .still
        item.playbackPolicy = PlaybackPolicy(pauseOnBattery: true, pauseOnLowPower: true, pauseOnLowBattery: true,
                                             lowPowerThreshold: -5, pauseOnFullscreen: false)
        let choice = try NativeWallpaperStore.choice(item, root: root, provider: "local.flua.desktop.wallpaper")
        let configuration = try JSONSerialization.jsonObject(with: choice["Configuration"] as! Data) as! [String: Any]
        precondition(configuration["kind"] as? String == "video")
        precondition(configuration["trim"] as? [Double] == [1, 3])
        precondition(configuration["modes"] as? [String: String] == ["desktop": "still", "lockScreen": "animated"])
        let descriptorPolicy = configuration["playbackPolicy"] as! [String: Any]
        precondition(descriptorPolicy["pauseOnBattery"] as? Bool == true)
        precondition(descriptorPolicy["pauseOnLowPower"] as? Bool == true)
        precondition(descriptorPolicy["pauseOnLowBattery"] as? Bool == true)
        precondition(descriptorPolicy["lowPowerThreshold"] as? Int == 0)
        precondition(descriptorPolicy["pauseOnFullscreen"] as? Bool == false)
        precondition((choice["Files"] as? [[String: String]])?.first?["relative"] == source.resolvingSymlinksInPath().absoluteString)
        var imageItem = item
        imageItem.id = "image"
        imageItem.kind = "image"
        imageItem.file = "Media/image.png"
        imageItem.speed = 0.4
        imageItem.desktop = .animated
        imageItem.lockScreen = .still
        let imageChoice = try NativeWallpaperStore.choice(imageItem, root: root, provider: "local.flua.desktop.wallpaper")
        let paired = try NativeWallpaperStore.pairedChoice(desktop: choice, lockScreen: imageChoice)
        let pairedConfiguration = try JSONSerialization.jsonObject(with: paired["Configuration"] as! Data) as! [String: Any]
        let pairedSurfaces = pairedConfiguration["surfaces"] as! [String: [String: Any]]
        precondition(pairedConfiguration["version"] as? Int == 2)
        precondition((paired["Files"] as? [[String: String]])?.count == 2)
        precondition(pairedSurfaces["desktop"]?["kind"] as? String == "video")
        precondition(pairedSurfaces["desktop"]?["fileIndex"] as? Int == 0)
        precondition(pairedSurfaces["lockScreen"]?["kind"] as? String == "image")
        precondition(pairedSurfaces["lockScreen"]?["fileIndex"] as? Int == 1)
        precondition(NSDictionary(dictionary: pairedConfiguration["playbackPolicy"] as! [String: Any]).isEqual(to: pairedSurfaces["desktop"]!["playbackPolicy"] as! [String: Any]))
        let sharedPair = try NativeWallpaperStore.pairedChoice(desktop: choice, lockScreen: choice)
        let sharedConfiguration = try JSONSerialization.jsonObject(with: sharedPair["Configuration"] as! Data) as! [String: Any]
        let sharedSurfaces = sharedConfiguration["surfaces"] as! [String: [String: Any]]
        precondition((sharedPair["Files"] as? [[String: String]])?.count == 1)
        precondition(sharedSurfaces["desktop"]?["fileIndex"] as? Int == 0)
        precondition(sharedSurfaces["lockScreen"]?["fileIndex"] as? Int == 0)
        var invalidIndexChoice = choice
        var invalidIndexConfiguration = configuration
        invalidIndexConfiguration["fileIndex"] = 9
        invalidIndexChoice["Configuration"] = try JSONSerialization.data(withJSONObject: invalidIndexConfiguration)
        do { _ = try NativeWallpaperStore.pairedChoice(desktop: invalidIndexChoice, lockScreen: imageChoice); preconditionFailure("Accepted an invalid file index") }
        catch is NativeWallpaperError {}
        var otherProviderChoice = imageChoice
        otherProviderChoice["Provider"] = "other.provider"
        do { _ = try NativeWallpaperStore.pairedChoice(desktop: choice, lockScreen: otherProviderChoice); preconditionFailure("Paired different providers") }
        catch is NativeWallpaperError {}
        let preserved = try Data(contentsOf: source)
        precondition(preserved == sourceData)
        let assignments = ["display": NativeWallpaperStore.Assignment(desktop: choice, lockScreen: choice)]
        let old: [String: Any] = ["Type": "individual", "Desktop": ["Content": ["Choices": [["Provider": "old-desktop"]]]], "Idle": ["Content": ["Choices": [["Provider": "old-idle"]]]], "Keep": "metadata"]
        let store: [String: Any] = ["SystemDefault": old, "AllSpacesAndDisplays": [:], "Displays": ["display": old], "Spaces": ["space": ["Default": old, "Displays": ["display": old]]], "Keep": "root metadata"]
        func encode(_ value: Any) throws -> Data { try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0) }
        let defaultOptions = try PropertyListSerialization.data(fromPropertyList: ["values": [String: String]()], format: .binary, options: 0)
        func defaultSurface(encodedOptions: Any = defaultOptions, extra: [String: Any] = [:]) -> [String: Any] {
            var content: [String: Any] = [
                "Choices": [["Provider": "default", "Files": [[String: String]](), "Configuration": Data()]],
                "Shuffle": "$null",
                "EncodedOptionValues": encodedOptions
            ]
            for (key, value) in extra { content[key] = value }
            return ["Content": content, "LastSet": Date(timeIntervalSince1970: 100), "LastUse": Date(timeIntervalSince1970: 101)]
        }
        func isDefaultSurface(_ value: Any?) -> Bool {
            guard let surface = value as? [String: Any], let content = surface["Content"] as? [String: Any],
                  let choices = content["Choices"] as? [[String: Any]], choices.count == 1 else { return false }
            let choice = choices[0]
            return choice["Provider"] as? String == "default" && (choice["Files"] as? [[String: String]])?.isEmpty == true &&
                choice["Configuration"] as? Data == Data() && content["Shuffle"] as? String == "$null" &&
                content["EncodedOptionValues"] as? Data == defaultOptions
        }
        func assertDefaultFallback(_ data: Data) throws {
            let value = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
            let systemDefault = value["SystemDefault"] as! [String: Any]
            let display = (value["Displays"] as! [String: Any])["display"] as! [String: Any]
            precondition(isDefaultSurface(systemDefault["Desktop"]) && isDefaultSurface(systemDefault["Idle"]))
            precondition(isDefaultSurface(display["Desktop"]) && isDefaultSurface(display["Idle"]))
            for surface in [systemDefault["Desktop"], systemDefault["Idle"], display["Desktop"], display["Idle"]] {
                let assignment = surface as! [String: Any]
                precondition(assignment["LastSet"] is Date && assignment["LastUse"] is Date)
            }
            let containsFlua = try NativeWallpaperStore.containsProvider("local.flua.desktop.wallpaper", in: data)
            precondition(!containsFlua)
        }
        let foreignDesktop: [String: Any] = [
            "Content": ["Choices": [["Provider": "foreign.desktop", "Files": [[String: String]](), "Configuration": Data()]],
                        "Shuffle": "$null", "EncodedOptionValues": defaultOptions],
            "LastSet": Date(timeIntervalSince1970: 100), "LastUse": Date(timeIntervalSince1970: 101)
        ]
        let expectedMixedFallback: [String: Any] = [
            "SystemDefault": ["Type": "individual", "Desktop": foreignDesktop, "Idle": defaultSurface()],
            "AllSpacesAndDisplays": [String: Any](),
            "Displays": ["display": ["Type": "individual", "Desktop": foreignDesktop, "Idle": defaultSurface()]],
            "Spaces": [String: Any]()
        ]
        let nativeResetToDefaults: [String: Any] = [
            "SystemDefault": ["Type": "linked", "Linked": defaultSurface(encodedOptions: "$null")],
            "AllSpacesAndDisplays": ["Type": "linked", "Linked": defaultSurface(encodedOptions: "$null")],
            "Displays": [String: Any](), "Spaces": [String: Any]()
        ]
        let expectedMixedFallbackData = try encode(expectedMixedFallback)
        let nativeResetData = try encode(nativeResetToDefaults)
        precondition(!NativeWallpaperStore.stopMatches(expectedMixedFallbackData, in: nativeResetData),
                     "A native whole-store reset must not verify when it drops a foreign Desktop choice")
        for type in ["individual", "linked", "desktop", "idle"] {
            var assignment = old
            assignment["Type"] = type
            assignment["Linked"] = ["Content": ["Choices": [["Provider": "old-linked"]]]]
            var variant = store
            variant["SystemDefault"] = assignment
            let converted = try NativeWallpaperStore.applying(assignments, mirrored: true, to: encode(variant))
            precondition(NativeWallpaperStore.matches(assignments, mirrored: true, in: converted))
            let decoded = try PropertyListSerialization.propertyList(from: converted, format: nil) as! [String: Any]
            let defaultAssignment = decoded["SystemDefault"] as! [String: Any]
            precondition(defaultAssignment["Type"] as? String == "individual" && defaultAssignment["Linked"] == nil)
        }
        let original = try encode(store)
        let updated = try NativeWallpaperStore.applying(assignments, mirrored: true, to: original, now: Date(timeIntervalSince1970: 100))
        precondition(NativeWallpaperStore.matches(assignments, mirrored: true, in: updated))
        let saved = try PropertyListSerialization.propertyList(from: updated, format: nil) as! [String: Any]
        precondition(saved["Keep"] as? String == "root metadata")
        precondition((saved["SystemDefault"] as? [String: Any])?["Keep"] as? String == "metadata")
        let stopped = try NativeWallpaperStore.stopping(displays: ["display"], provider: "local.flua.desktop.wallpaper", in: updated, baseline: original)
        let stoppedStore = try PropertyListSerialization.propertyList(from: stopped, format: nil) as! [String: Any]
        let stoppedDisplay = (stoppedStore["Displays"] as! [String: Any])["display"] as! [String: Any]
        precondition(NSDictionary(dictionary: stoppedDisplay["Desktop"] as! [String: Any]).isEqual(to: old["Desktop"] as! [String: Any]))
        precondition(NSDictionary(dictionary: stoppedDisplay["Idle"] as! [String: Any]).isEqual(to: old["Idle"] as! [String: Any]))
        precondition(stoppedStore["Keep"] as? String == "root metadata")
        let stoppedAgain = try NativeWallpaperStore.stopping(displays: ["display"], provider: "local.flua.desktop.wallpaper", in: stopped, baseline: nil)
        precondition(stoppedAgain == stopped)
        precondition(NativeWallpaperStore.stopMatches(stopped, in: stopped))
        precondition(!NativeWallpaperStore.stopMatches(stopped, in: updated))
        for baseline: Data? in [nil, updated, Data("malformed".utf8)] {
            let fallback = try NativeWallpaperStore.stopping(displays: ["display"], provider: "local.flua.desktop.wallpaper", in: updated, baseline: baseline)
            try assertDefaultFallback(fallback)
        }
        let reappliedWithoutBaseline = try NativeWallpaperStore.replacing(assignments, displays: ["display"], provider: "local.flua.desktop.wallpaper",
            mirrored: true, in: updated, baseline: nil)
        precondition(NativeWallpaperStore.matches(assignments, mirrored: true, in: reappliedWithoutBaseline))
        let unchangedRestore = try NativeWallpaperStore.replacing(assignments, displays: ["display"], provider: "local.flua.desktop.wallpaper",
            mirrored: true, in: updated, baseline: original)
        precondition(NativeWallpaperStore.stopMatches(unchangedRestore, in: updated), "Restoration must ignore refreshed surface timestamps")
        precondition(!NativeWallpaperStore.stopMatches(unchangedRestore, in: original), "A different system wallpaper still needs application")
        func decoded(_ data: Data) throws -> [String: Any] {
            try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
        }
        func replaceChoice(_ choice: [String: Any], surface: String, in value: inout [String: Any]) {
            var settings = value[surface] as! [String: Any]
            var content = settings["Content"] as! [String: Any]
            content["Choices"] = [choice]
            settings["Content"] = content
            settings["LastSet"] = Date(timeIntervalSince1970: 200)
            settings["LastUse"] = Date(timeIntervalSince1970: 201)
            value[surface] = settings
        }
        var idleChoice = choice
        idleChoice["Provider"] = "local.flua.idle"
        let applicationAssignments = ["display": NativeWallpaperStore.Assignment(desktop: choice, lockScreen: idleChoice)]
        func spaceChoiceProvider(_ assignment: Any?, surface: String) -> String? {
            guard let assignment = assignment as? [String: Any],
                  let settings = assignment[surface] as? [String: Any],
                  let content = settings["Content"] as? [String: Any],
                  let choices = content["Choices"] as? [[String: Any]] else { return nil }
            return choices.first?["Provider"] as? String
        }
        var inheritedOtherDisplay = old
        replaceChoice(["Provider": "other.desktop"], surface: "Desktop", in: &inheritedOtherDisplay)
        replaceChoice(["Provider": "other.idle"], surface: "Idle", in: &inheritedOtherDisplay)
        var sparseSpaceStore = try decoded(original)
        sparseSpaceStore["Spaces"] = [String: Any]()
        var sparseDisplays = sparseSpaceStore["Displays"] as! [String: Any]
        sparseDisplays["other-display"] = inheritedOtherDisplay
        sparseSpaceStore["Displays"] = sparseDisplays
        let sparseSpaceSource = try encode(sparseSpaceStore)
        let seededSpaces = try NativeWallpaperStore.applying(applicationAssignments, mirrored: false,
            to: sparseSpaceSource, spaceIDs: [desktopSpace, fullscreenSpace])
        precondition(NativeWallpaperStore.matches(applicationAssignments, mirrored: false, in: seededSpaces))
        let seededPreservingReplacement = try NativeWallpaperStore.replacing(applicationAssignments, displays: ["display"],
            provider: "local.flua.desktop.wallpaper", mirrored: false, in: sparseSpaceSource, baseline: nil,
            clearingUnassigned: false, spaceIDs: [desktopSpace, fullscreenSpace])
        precondition(NativeWallpaperStore.matches(applicationAssignments, mirrored: false, in: seededPreservingReplacement))
        let seededClearingReplacement = try NativeWallpaperStore.replacing(applicationAssignments, displays: ["display"],
            provider: "local.flua.desktop.wallpaper", mirrored: false, in: sparseSpaceSource, baseline: nil,
            clearingUnassigned: true, spaceIDs: [desktopSpace, fullscreenSpace])
        precondition(NativeWallpaperStore.matches(applicationAssignments, mirrored: false, in: seededClearingReplacement))
        let seededSpaceStore = try decoded(seededSpaces)
        let seededSpaceValues = seededSpaceStore["Spaces"] as! [String: Any]
        precondition(Set(seededSpaceValues.keys) == Set([desktopSpace, fullscreenSpace]))
        for id in [desktopSpace, fullscreenSpace] {
            let space = seededSpaceValues[id] as! [String: Any]
            precondition(NSDictionary(dictionary: space["Default"] as! [String: Any]).isEqual(to: old))
            let overrides = space["Displays"] as! [String: Any]
            precondition(spaceChoiceProvider(overrides["display"], surface: "Desktop") == "local.flua.desktop.wallpaper")
            precondition(spaceChoiceProvider(overrides["display"], surface: "Idle") == "local.flua.idle")
            precondition(NSDictionary(dictionary: overrides["other-display"] as! [String: Any]).isEqual(to: inheritedOtherDisplay))
        }
        var existingSpaceStore = sparseSpaceStore
        existingSpaceStore["Spaces"] = ["existing-space": ["Default": old, "Displays": sparseDisplays,
            "Keep": "existing space metadata"]]
        let existingSpaceResult = try NativeWallpaperStore.applying(applicationAssignments, mirrored: false,
            to: encode(existingSpaceStore), spaceIDs: ["existing-space", desktopSpace])
        let existingSpaceValues = try decoded(existingSpaceResult)["Spaces"] as! [String: Any]
        let existingSpace = existingSpaceValues["existing-space"] as! [String: Any]
        precondition(existingSpace["Keep"] as? String == "existing space metadata")
        precondition(NSDictionary(dictionary: existingSpace["Default"] as! [String: Any]).isEqual(to: old))
        precondition(existingSpaceValues[desktopSpace] != nil)
        let mirroredSeeded = try NativeWallpaperStore.applying(applicationAssignments, mirrored: true,
            to: sparseSpaceSource, spaceIDs: [desktopSpace, fullscreenSpace])
        precondition(NativeWallpaperStore.matches(applicationAssignments, mirrored: true, in: mirroredSeeded))
        let mirroredSeededSpaces = try decoded(mirroredSeeded)["Spaces"] as! [String: Any]
        for id in [desktopSpace, fullscreenSpace] {
            let space = mirroredSeededSpaces[id] as! [String: Any]
            precondition(spaceChoiceProvider(space["Default"], surface: "Desktop") == "local.flua.desktop.wallpaper")
            precondition(spaceChoiceProvider(space["Default"], surface: "Idle") == "local.flua.idle")
        }
        var incompleteSeededStore = try decoded(seededSpaces)
        var incompleteSeededSpaces = incompleteSeededStore["Spaces"] as! [String: Any]
        var incompleteSeededSpace = incompleteSeededSpaces[fullscreenSpace] as! [String: Any]
        var incompleteOverrides = incompleteSeededSpace["Displays"] as! [String: Any]
        var incompleteTarget = incompleteOverrides["display"] as! [String: Any]
        incompleteTarget.removeValue(forKey: "Idle")
        incompleteOverrides["display"] = incompleteTarget
        incompleteSeededSpace["Displays"] = incompleteOverrides
        incompleteSeededSpaces[fullscreenSpace] = incompleteSeededSpace
        incompleteSeededStore["Spaces"] = incompleteSeededSpaces
        let incompleteSeededData = try encode(incompleteSeededStore)
        precondition(!NativeWallpaperStore.matches(applicationAssignments, mirrored: false, in: incompleteSeededData))
        var applicationDefault = old
        for surface in ["Desktop", "Idle"] {
            var settings = applicationDefault[surface] as! [String: Any]
            var content = settings["Content"] as! [String: Any]
            content["Shuffle"] = "$null"
            content["EncodedOptionValues"] = Data([0])
            settings["Content"] = content
            applicationDefault[surface] = settings
        }
        var applicationBase = try decoded(original)
        applicationBase["SystemDefault"] = applicationDefault
        var applicationSpaces = applicationBase["Spaces"] as! [String: Any]
        for id in ["space-2", "space-3"] {
            applicationSpaces[id] = ["Default": applicationDefault, "Displays": ["display": old, "untargeted": old]]
        }
        for id in Array(applicationSpaces.keys) {
            var space = applicationSpaces[id] as! [String: Any]
            space["Default"] = applicationDefault
            applicationSpaces[id] = space
        }
        applicationBase["Spaces"] = applicationSpaces
        applicationBase["Displays"] = ["display": old, "untargeted": old]

        func existingFluaChoice(_ label: String) throws -> [String: Any] {
            var value = choice
            value["Provider"] = "local.flua.desktop.wallpaper"
            var configuration = try JSONSerialization.jsonObject(with: value["Configuration"] as! Data) as! [String: Any]
            configuration["regressionChoice"] = label
            value["Configuration"] = try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys])
            return value
        }
        let existingDesktopChoice = try existingFluaChoice("existing.desktop")
        let existingIdleChoice = try existingFluaChoice("existing.idle")
        var replacementDesktopChoice = choice
        replacementDesktopChoice["Provider"] = "replacement.desktop"
        var replacementIdleChoice = choice
        replacementIdleChoice["Provider"] = "replacement.idle"
        let partialAssignments = [
            "A": NativeWallpaperStore.Assignment(desktop: existingDesktopChoice, lockScreen: existingIdleChoice),
            "B": NativeWallpaperStore.Assignment(desktop: existingIdleChoice, lockScreen: existingDesktopChoice)
        ]
        let surfacePreservationStore: [String: Any] = [
            "SystemDefault": applicationDefault,
            "AllSpacesAndDisplays": "$null",
            "Displays": ["A": old, "B": old, "untargeted": old],
            "Spaces": [
                "space-2": ["Default": applicationDefault, "Displays": ["A": old, "B": old, "untargeted": old]],
                "space-3": ["Default": applicationDefault, "Displays": ["A": old, "B": old, "untargeted": old]]
            ]
        ]
        let surfacePreservationApplied = try NativeWallpaperStore.applying(partialAssignments, mirrored: false, to: encode(surfacePreservationStore))
        func provider(_ assignment: Any?, surface: String) -> String? {
            guard let assignment = assignment as? [String: Any],
                  let settings = assignment[surface] as? [String: Any],
                  let content = settings["Content"] as? [String: Any],
                  let choices = content["Choices"] as? [[String: Any]] else { return nil }
            guard let choice = choices.first, let provider = choice["Provider"] as? String else { return nil }
            if provider != "local.flua.desktop.wallpaper" { return provider }
            guard let configuration = choice["Configuration"] as? Data,
                  let value = try? JSONSerialization.jsonObject(with: configuration) as? [String: Any] else { return provider }
            return value["regressionChoice"] as? String ?? provider
        }
        func assertPartialReplacement(_ data: Data, changedSurface: String, replacement: String) throws {
            let value = try decoded(data)
            let systemDefault = value["SystemDefault"] as! [String: Any]
            precondition(NSDictionary(dictionary: systemDefault).isEqual(to: applicationDefault))
            precondition(value["AllSpacesAndDisplays"] as? String == "$null")
            let displays = value["Displays"] as! [String: Any]
            let expectedA = changedSurface == "Desktop" ? replacement : "existing.desktop"
            let expectedIdleA = changedSurface == "Idle" ? replacement : "existing.idle"
            precondition(provider(displays["A"], surface: "Desktop") == expectedA)
            precondition(provider(displays["A"], surface: "Idle") == expectedIdleA)
            precondition(provider(displays["B"], surface: "Desktop") == "existing.idle")
            precondition(provider(displays["B"], surface: "Idle") == "existing.desktop")
            precondition(NSDictionary(dictionary: displays["untargeted"] as! [String: Any]).isEqual(to: old))
            let spaces = value["Spaces"] as! [String: Any]
            for id in ["space-2", "space-3"] {
                let space = spaces[id] as! [String: Any]
                precondition(NSDictionary(dictionary: space["Default"] as! [String: Any]).isEqual(to: applicationDefault))
                let overrides = space["Displays"] as! [String: Any]
                precondition(provider(overrides["A"], surface: "Desktop") == expectedA)
                precondition(provider(overrides["A"], surface: "Idle") == expectedIdleA)
                precondition(provider(overrides["B"], surface: "Desktop") == "existing.idle")
                precondition(provider(overrides["B"], surface: "Idle") == "existing.desktop")
                precondition(NSDictionary(dictionary: overrides["untargeted"] as! [String: Any]).isEqual(to: old))
            }
        }
        let desktopOnlyReplacement = try NativeWallpaperStore.replacing(
            ["A": NativeWallpaperStore.Assignment(desktop: replacementDesktopChoice)], displays: ["A"],
            provider: "local.flua.desktop.wallpaper", mirrored: false, in: surfacePreservationApplied, baseline: nil,
            clearingUnassigned: false)
        try assertPartialReplacement(desktopOnlyReplacement, changedSurface: "Desktop", replacement: "replacement.desktop")
        let clearingReplacement = try NativeWallpaperStore.replacing(
            ["A": NativeWallpaperStore.Assignment(desktop: replacementDesktopChoice)], displays: ["A"],
            provider: "local.flua.desktop.wallpaper", mirrored: false, in: surfacePreservationApplied, baseline: nil,
            clearingUnassigned: true)
        let clearedIdle = try decoded(clearingReplacement)
        let clearedDisplayA = (clearedIdle["Displays"] as! [String: Any])["A"]
        precondition(isDefaultSurface((clearedDisplayA as? [String: Any])?["Idle"]))
        let lockScreenOnlyReplacement = try NativeWallpaperStore.replacing(
            ["A": NativeWallpaperStore.Assignment(lockScreen: replacementIdleChoice)], displays: ["A"],
            provider: "local.flua.desktop.wallpaper", mirrored: false, in: surfacePreservationApplied, baseline: nil,
            clearingUnassigned: false)
        try assertPartialReplacement(lockScreenOnlyReplacement, changedSurface: "Idle", replacement: "replacement.idle")

        let mirroredExisting = NativeWallpaperStore.Assignment(desktop: existingDesktopChoice, lockScreen: existingIdleChoice)
        let mirroredPartialApplied = try NativeWallpaperStore.applying(["A": mirroredExisting, "B": mirroredExisting],
            mirrored: true, to: encode(surfacePreservationStore))
        let mirroredPartialReplacement = try NativeWallpaperStore.replacing([
            "A": NativeWallpaperStore.Assignment(desktop: replacementDesktopChoice),
            "B": NativeWallpaperStore.Assignment(desktop: replacementDesktopChoice)
        ], displays: ["A", "B"], provider: "local.flua.desktop.wallpaper", mirrored: true,
            in: mirroredPartialApplied, baseline: nil, clearingUnassigned: false)
        let mirroredPartialValue = try decoded(mirroredPartialReplacement)
        for key in ["SystemDefault", "AllSpacesAndDisplays"] {
            let defaults = mirroredPartialValue[key] as! [String: Any]
            precondition(provider(defaults, surface: "Desktop") == "replacement.desktop")
            precondition(provider(defaults, surface: "Idle") == "existing.idle")
        }
        let mirroredDisplays = mirroredPartialValue["Displays"] as! [String: Any]
        for id in ["A", "B"] {
            precondition(provider(mirroredDisplays[id], surface: "Desktop") == "replacement.desktop")
            precondition(provider(mirroredDisplays[id], surface: "Idle") == "existing.idle")
        }
        precondition(NSDictionary(dictionary: mirroredDisplays["untargeted"] as! [String: Any]).isEqual(to: old))
        let mirroredSpaces = mirroredPartialValue["Spaces"] as! [String: Any]
        for id in ["space-2", "space-3"] {
            let space = mirroredSpaces[id] as! [String: Any]
            for key in ["Default"] {
                precondition(provider(space[key], surface: "Desktop") == "replacement.desktop")
                precondition(provider(space[key], surface: "Idle") == "existing.idle")
            }
            let overrides = space["Displays"] as! [String: Any]
            for display in ["A", "B"] {
                precondition(provider(overrides[display], surface: "Desktop") == "replacement.desktop")
                precondition(provider(overrides[display], surface: "Idle") == "existing.idle")
            }
            precondition(NSDictionary(dictionary: overrides["untargeted"] as! [String: Any]).isEqual(to: old))
        }

        var scopedState = LibraryState.initial
        scopedState.assign("aurora", display: "A", surface: .desktop)
        scopedState.setMode(.still, display: "A", surface: .desktop)
        scopedState.assign("ocean", display: "A", surface: .lockScreen)
        let desktopScoped = try NativeWallpaperStore.assignments(from: scopedState, displays: ["A"], root: root,
            provider: "local.flua.desktop.wallpaper", surface: .desktop)["A"]!
        let lockScreenScoped = try NativeWallpaperStore.assignments(from: scopedState, displays: ["A"], root: root,
            provider: "local.flua.desktop.wallpaper", surface: .lockScreen)["A"]!
        precondition(desktopScoped.desktop != nil && desktopScoped.lockScreen != nil)
        precondition(lockScreenScoped.desktop != nil && lockScreenScoped.lockScreen != nil)
        precondition(NSDictionary(dictionary: desktopScoped.desktop!).isEqual(to: desktopScoped.lockScreen!))
        precondition(NSDictionary(dictionary: lockScreenScoped.desktop!).isEqual(to: lockScreenScoped.lockScreen!))
        scopedState.setSurfacesLinked(true, display: "A")
        let linkedDesktopScoped = try NativeWallpaperStore.assignments(from: scopedState, displays: ["A"], root: root,
            provider: "local.flua.desktop.wallpaper", surface: .desktop)["A"]!
        let linkedLockScreenScoped = try NativeWallpaperStore.assignments(from: scopedState, displays: ["A"], root: root,
            provider: "local.flua.desktop.wallpaper", surface: .lockScreen)["A"]!
        precondition(linkedDesktopScoped.desktop != nil && linkedDesktopScoped.lockScreen != nil)
        precondition(linkedLockScreenScoped.desktop != nil && linkedLockScreenScoped.lockScreen != nil)
        precondition(NSDictionary(dictionary: linkedDesktopScoped.desktop!).isEqual(to: linkedDesktopScoped.lockScreen!))
        precondition(NSDictionary(dictionary: linkedLockScreenScoped.desktop!).isEqual(to: linkedLockScreenScoped.lockScreen!))
        var desktopOnlyState = LibraryState.initial
        desktopOnlyState.assign("aurora", display: "A")
        let desktopOnlyScoped = try NativeWallpaperStore.assignments(from: desktopOnlyState, displays: ["A"], root: root,
            provider: "local.flua.desktop.wallpaper", surface: .desktop)["A"]!
        let desktopOnlyConfiguration = try JSONSerialization.jsonObject(with: desktopOnlyScoped.desktop!["Configuration"] as! Data) as! [String: Any]
        precondition(desktopOnlyConfiguration["version"] as? Int == 1)
        precondition(desktopOnlyScoped.lockScreen == nil)
        print("PASS: surface-scoped native Apply preserves untargeted choices, defaults and other displays across Spaces")

        let applicationExpected = try NativeWallpaperStore.applying(applicationAssignments, mirrored: false,
            to: encode(applicationBase), now: Date(timeIntervalSince1970: 100))
        func propagated(_ surfaces: [String], systemDefault: Bool, spaceIDs: [String]) throws -> Data {
            var value = try decoded(applicationExpected)
            for surface in surfaces {
                let requested = surface == "Desktop" ? choice : idleChoice
                if systemDefault {
                    var defaults = value["SystemDefault"] as! [String: Any]
                    replaceChoice(requested, surface: surface, in: &defaults)
                    value["SystemDefault"] = defaults
                }
                var spaces = value["Spaces"] as! [String: Any]
                for id in spaceIDs {
                    var space = spaces[id] as! [String: Any]
                    var defaults = space["Default"] as! [String: Any]
                    replaceChoice(requested, surface: surface, in: &defaults)
                    space["Default"] = defaults
                    spaces[id] = space
                }
                value["Spaces"] = spaces
            }
            return try encode(value)
        }
        for surfaces in [["Desktop"], ["Idle"], ["Desktop", "Idle"]] {
            let actual = try propagated(surfaces, systemDefault: true, spaceIDs: ["space-2"])
            precondition(NativeWallpaperStore.matches(applicationAssignments, mirrored: false, in: actual))
            precondition(NativeWallpaperStore.applicationMatches(applicationAssignments, mirrored: false,
                expected: applicationExpected, in: actual))
            precondition(!NativeWallpaperStore.stopMatches(applicationExpected, in: actual))
        }
        let subsetDefault = try propagated(["Desktop"], systemDefault: false, spaceIDs: ["space-2"])
        precondition(NativeWallpaperStore.applicationMatches(applicationAssignments, mirrored: false,
            expected: applicationExpected, in: subsetDefault))
        var foreignChoice = choice
        foreignChoice["Provider"] = "foreign.provider"
        var wrongSurface = try decoded(propagated(["Desktop"], systemDefault: true, spaceIDs: []))
        var wrongDefaults = wrongSurface["SystemDefault"] as! [String: Any]
        replaceChoice(idleChoice, surface: "Desktop", in: &wrongDefaults)
        wrongSurface["SystemDefault"] = wrongDefaults
        let wrongSurfaceData = try encode(wrongSurface)
        precondition(NativeWallpaperStore.matches(applicationAssignments, mirrored: false, in: wrongSurfaceData))
        precondition(!NativeWallpaperStore.applicationMatches(applicationAssignments, mirrored: false,
            expected: applicationExpected, in: wrongSurfaceData))
        let desktopOnly = ["display": NativeWallpaperStore.Assignment(desktop: choice)]
        let desktopOnlyExpected = try NativeWallpaperStore.applying(desktopOnly, mirrored: false, to: encode(applicationBase))
        var unassignedSurface = try decoded(desktopOnlyExpected)
        var unassignedDefaults = unassignedSurface["SystemDefault"] as! [String: Any]
        replaceChoice(idleChoice, surface: "Idle", in: &unassignedDefaults)
        unassignedSurface["SystemDefault"] = unassignedDefaults
        let unassignedData = try encode(unassignedSurface)
        precondition(NativeWallpaperStore.matches(desktopOnly, mirrored: false, in: unassignedData))
        precondition(!NativeWallpaperStore.applicationMatches(desktopOnly, mirrored: false,
            expected: desktopOnlyExpected, in: unassignedData))
        var foreignDefaultPropagation = try decoded(propagated(["Desktop"], systemDefault: true, spaceIDs: []))
        var foreignDefaults = foreignDefaultPropagation["SystemDefault"] as! [String: Any]
        replaceChoice(foreignChoice, surface: "Desktop", in: &foreignDefaults)
        foreignDefaultPropagation["SystemDefault"] = foreignDefaults
        let foreignDefaultData = try encode(foreignDefaultPropagation)
        precondition(NativeWallpaperStore.matches(applicationAssignments, mirrored: false, in: foreignDefaultData))
        precondition(!NativeWallpaperStore.applicationMatches(applicationAssignments, mirrored: false,
            expected: applicationExpected, in: foreignDefaultData))
        var untargeted = try decoded(applicationExpected)
        var displays = untargeted["Displays"] as! [String: Any]
        var untargetedDisplay = displays["untargeted"] as! [String: Any]
        replaceChoice(foreignChoice, surface: "Desktop", in: &untargetedDisplay)
        displays["untargeted"] = untargetedDisplay
        untargeted["Displays"] = displays
        let untargetedData = try encode(untargeted)
        precondition(NativeWallpaperStore.matches(applicationAssignments, mirrored: false, in: untargetedData))
        precondition(!NativeWallpaperStore.applicationMatches(applicationAssignments, mirrored: false,
            expected: applicationExpected, in: untargetedData))
        var changedContent = try decoded(propagated(["Desktop"], systemDefault: true, spaceIDs: []))
        var changedDefaults = changedContent["SystemDefault"] as! [String: Any]
        var changedDesktop = changedDefaults["Desktop"] as! [String: Any]
        var changedDesktopContent = changedDesktop["Content"] as! [String: Any]
        changedDesktopContent["Shuffle"] = "changed"
        changedDesktop["Content"] = changedDesktopContent
        changedDefaults["Desktop"] = changedDesktop
        changedContent["SystemDefault"] = changedDefaults
        let changedContentData = try encode(changedContent)
        precondition(NativeWallpaperStore.matches(applicationAssignments, mirrored: false, in: changedContentData))
        precondition(!NativeWallpaperStore.applicationMatches(applicationAssignments, mirrored: false,
            expected: applicationExpected, in: changedContentData))
        var missingTarget = try decoded(applicationExpected)
        var missingDisplays = missingTarget["Displays"] as! [String: Any]
        missingDisplays.removeValue(forKey: "display")
        missingTarget["Displays"] = missingDisplays
        let missingTargetData = try encode(missingTarget)
        precondition(!NativeWallpaperStore.applicationMatches(applicationAssignments, mirrored: false,
            expected: applicationExpected, in: missingTargetData))
        var mismatchedTarget = try decoded(applicationExpected)
        var mismatchedDisplays = mismatchedTarget["Displays"] as! [String: Any]
        var mismatchedDisplay = mismatchedDisplays["display"] as! [String: Any]
        replaceChoice(foreignChoice, surface: "Desktop", in: &mismatchedDisplay)
        mismatchedDisplays["display"] = mismatchedDisplay
        mismatchedTarget["Displays"] = mismatchedDisplays
        let mismatchedTargetData = try encode(mismatchedTarget)
        precondition(!NativeWallpaperStore.applicationMatches(applicationAssignments, mirrored: false,
            expected: applicationExpected, in: mismatchedTargetData))
        precondition(!NativeWallpaperStore.applicationMatches(applicationAssignments, mirrored: false,
            expected: applicationExpected, in: Data("not a plist".utf8)))
        let mirroredExpected = try NativeWallpaperStore.applying(applicationAssignments, mirrored: true, to: encode(applicationBase))
        var sparseBase = applicationBase
        let linkedOld = ["Type": "linked", "Linked": old["Desktop"] as! [String: Any]] as [String: Any]
        sparseBase["SystemDefault"] = linkedOld
        sparseBase["AllSpacesAndDisplays"] = linkedOld
        sparseBase["Displays"] = ["display": linkedOld, "untargeted": ["Type": "individual"]]
        sparseBase["Spaces"] = ["space": ["Default": linkedOld, "Displays": ["display": linkedOld, "untargeted": ["Type": "individual"], "space-only": ["Type": "individual"]]]]
        let sparseAssignments = ["display": NativeWallpaperStore.Assignment(desktop: choice, lockScreen: choice)]
        let sparseMirrored = try NativeWallpaperStore.applying(sparseAssignments, mirrored: true, to: encode(sparseBase))
        let sparseStopped = try NativeWallpaperStore.stopping(displays: ["display"], provider: "local.flua.desktop.wallpaper",
            in: sparseMirrored, baseline: encode(sparseBase), mirrored: true)
        let sparseResult = try decoded(sparseStopped)
        let sparseUntargetedDisplays = sparseResult["Displays"] as! [String: Any]
        let inheritedUntargeted = sparseUntargetedDisplays["untargeted"] as! [String: Any]
        precondition(spaceChoiceProvider(inheritedUntargeted, surface: "Desktop") == "local.flua.desktop.wallpaper",
                     "Stopping one display must preserve the provider choice inherited by untargeted displays")
        precondition(spaceChoiceProvider(inheritedUntargeted, surface: "Idle") == "local.flua.desktop.wallpaper",
                     "Stopping one display must preserve both inherited surface choices")
        let sparseSpace = (sparseResult["Spaces"] as! [String: Any])["space"] as! [String: Any]
        let sparseSpaceDisplays = sparseSpace["Displays"] as! [String: Any]
        let inheritedSpaceDisplay = sparseSpaceDisplays["untargeted"] as! [String: Any]
        precondition(spaceChoiceProvider(inheritedSpaceDisplay, surface: "Desktop") == "local.flua.desktop.wallpaper",
                     "Stopping one display must preserve the provider choice inherited by untargeted Space displays")
        precondition(spaceChoiceProvider(inheritedSpaceDisplay, surface: "Idle") == "local.flua.desktop.wallpaper",
                     "Stopping one display must preserve both inherited Space surface choices")
        let inheritedSpaceOnlyDisplay = sparseSpaceDisplays["space-only"] as! [String: Any]
        precondition(spaceChoiceProvider(inheritedSpaceOnlyDisplay, surface: "Desktop") == "local.flua.desktop.wallpaper" &&
                     spaceChoiceProvider(inheritedSpaceOnlyDisplay, surface: "Idle") == "local.flua.desktop.wallpaper",
                     "Stopping one display must preserve choices for IDs present only in Space overrides")
        var sparsePartialSpaceDefault = try decoded(sparseMirrored)
        var sparsePartialSpaces = sparsePartialSpaceDefault["Spaces"] as! [String: Any]
        var sparsePartialSpace = sparsePartialSpaces["space"] as! [String: Any]
        var partialDefault = sparsePartialSpace["Default"] as! [String: Any]
        partialDefault.removeValue(forKey: "Idle")
        sparsePartialSpace["Default"] = partialDefault
        sparsePartialSpaces["space"] = sparsePartialSpace
        sparsePartialSpaceDefault["Spaces"] = sparsePartialSpaces
        let partialDefaultStopped = try NativeWallpaperStore.stopping(displays: ["display"], provider: "local.flua.desktop.wallpaper",
            in: encode(sparsePartialSpaceDefault), baseline: encode(sparseBase), mirrored: true)
        let partialDefaultResult = try decoded(partialDefaultStopped)
        let partialDefaultDisplays = ((partialDefaultResult["Spaces"] as! [String: Any])["space"] as! [String: Any])["Displays"] as! [String: Any]
        let inheritedPartialDefault = partialDefaultDisplays["untargeted"] as! [String: Any]
        precondition(spaceChoiceProvider(inheritedPartialDefault, surface: "Desktop") == "local.flua.desktop.wallpaper" &&
                     spaceChoiceProvider(inheritedPartialDefault, surface: "Idle") == "local.flua.desktop.wallpaper",
                     "A partial Space default must inherit its missing surface before shared defaults are restored")
        var sparseWithoutSpaceDefault = try decoded(sparseMirrored)
        var sparseWithoutDefaultSpaces = sparseWithoutSpaceDefault["Spaces"] as! [String: Any]
        var sparseWithoutDefaultSpace = sparseWithoutDefaultSpaces["space"] as! [String: Any]
        sparseWithoutDefaultSpace.removeValue(forKey: "Default")
        sparseWithoutDefaultSpaces["space"] = sparseWithoutDefaultSpace
        sparseWithoutSpaceDefault["Spaces"] = sparseWithoutDefaultSpaces
        let noSpaceDefaultStopped = try NativeWallpaperStore.stopping(displays: ["display"], provider: "local.flua.desktop.wallpaper",
            in: encode(sparseWithoutSpaceDefault), baseline: encode(sparseBase), mirrored: true)
        let noSpaceDefaultResult = try decoded(noSpaceDefaultStopped)
        let noSpaceDefault = ((noSpaceDefaultResult["Spaces"] as! [String: Any])["space"] as! [String: Any])
        precondition(noSpaceDefault["Default"] == nil)
        let noSpaceDefaultDisplays = noSpaceDefault["Displays"] as! [String: Any]
        let inheritedWithoutDefault = noSpaceDefaultDisplays["untargeted"] as! [String: Any]
        precondition(spaceChoiceProvider(inheritedWithoutDefault, surface: "Desktop") == "local.flua.desktop.wallpaper" &&
                     spaceChoiceProvider(inheritedWithoutDefault, surface: "Idle") == "local.flua.desktop.wallpaper",
                     "A missing Space default must fall back to the current global provider choices")
        var mirroredFixture = try decoded(mirroredExpected)
        var mirroredDefaults = mirroredFixture["SystemDefault"] as! [String: Any]
        let oldDesktopChoice = ((old["Desktop"] as! [String: Any])["Content"] as! [String: Any])["Choices"] as! [[String: Any]]
        replaceChoice(oldDesktopChoice[0], surface: "Desktop", in: &mirroredDefaults)
        mirroredFixture["SystemDefault"] = mirroredDefaults
        let mirroredExpectedWithOldDefault = try encode(mirroredFixture)
        precondition(NativeWallpaperStore.matches(applicationAssignments, mirrored: true, in: mirroredExpected))
        precondition(!NativeWallpaperStore.applicationMatches(applicationAssignments, mirrored: true,
            expected: mirroredExpectedWithOldDefault, in: mirroredExpected))
        print("PASS: Apply verification allows only requested per-display choice propagation into defaults")
        let captured = try NativeWallpaperStore.stopping(displays: ["second"], provider: "local.flua.desktop.wallpaper", in: updated, baseline: original, captureBaseline: true)
        let recaptured = try NativeWallpaperStore.stopping(displays: ["display"], provider: "local.flua.desktop.wallpaper", in: updated, baseline: captured, captureBaseline: true)
        let repeatedStop = try NativeWallpaperStore.stopping(displays: ["display"], provider: "local.flua.desktop.wallpaper", in: updated, baseline: recaptured)
        precondition(NativeWallpaperStore.stopMatches(stopped, in: repeatedStop))
        var foreignStore = saved
        var foreignDisplay = saved["SystemDefault"] as! [String: Any]
        foreignDisplay["Idle"] = old["Idle"]
        foreignStore["Displays"] = ["display": foreignDisplay, "untargeted": saved["SystemDefault"]!]
        let foreignStop = try NativeWallpaperStore.stopping(displays: ["display"], provider: "local.flua.desktop.wallpaper", in: encode(foreignStore), baseline: original)
        let foreignResult = try PropertyListSerialization.propertyList(from: foreignStop, format: nil) as! [String: Any]
        let foreignDisplays = foreignResult["Displays"] as! [String: Any]
        precondition(NSDictionary(dictionary: foreignDisplays["untargeted"] as! [String: Any]).isEqual(to: saved["SystemDefault"] as! [String: Any]))
        let foreignTarget = foreignDisplays["display"] as! [String: Any]
        precondition(NSDictionary(dictionary: foreignTarget["Idle"] as! [String: Any]).isEqual(to: old["Idle"] as! [String: Any]))
        var timestampStore = stoppedStore
        var timestampDisplays = timestampStore["Displays"] as! [String: Any]
        var timestampDisplay = stoppedDisplay
        var timestampDesktop = timestampDisplay["Desktop"] as! [String: Any]
        timestampDesktop["LastUse"] = Date()
        timestampDisplay["Desktop"] = timestampDesktop
        timestampDisplays["display"] = timestampDisplay
        timestampStore["Displays"] = timestampDisplays
        let timestampData = try encode(timestampStore)
        precondition(NativeWallpaperStore.stopMatches(stopped, in: timestampData))
        let mirroredStop = try NativeWallpaperStore.stopping(displays: ["display"], provider: "local.flua.desktop.wallpaper", in: updated, baseline: original, mirrored: true)
        let mirroredResult = try PropertyListSerialization.propertyList(from: mirroredStop, format: nil) as! [String: Any]
        let restoredDefault = mirroredResult["SystemDefault"] as! [String: Any]
        precondition(NSDictionary(dictionary: restoredDefault["Desktop"] as! [String: Any]).isEqual(to: old["Desktop"] as! [String: Any]))
        var mixedStopStore = saved
        var mixedStopDisplay = foreignDisplay
        mixedStopDisplay["Desktop"] = ["Content": ["Choices": [choice, ["Provider": "foreign"]]]]
        mixedStopStore["Displays"] = ["display": mixedStopDisplay]
        let mixedStop = try NativeWallpaperStore.stopping(displays: ["display"], provider: "local.flua.desktop.wallpaper", in: encode(mixedStopStore), baseline: original)
        let mixedStopResult = try PropertyListSerialization.propertyList(from: mixedStop, format: nil) as! [String: Any]
        let mixedStopDesktop = (((mixedStopResult["Displays"] as! [String: Any])["display"] as! [String: Any])["Desktop"] as! [String: Any])["Content"] as! [String: Any]
        precondition((mixedStopDesktop["Choices"] as! [[String: Any]]).map { $0["Provider"] as? String } == ["foreign"])
        do { _ = try NativeWallpaperStore.stopping(displays: ["display"], provider: "test", in: encode(["Displays": [:]]), baseline: original); preconditionFailure("Accepted malformed stop store") }
        catch is NativeWallpaperError {}
        print("PASS: native Stop restores both surfaces, retains untargeted and foreign choices, and falls back to macOS defaults when baselines are unavailable")
        let restored = try NativeWallpaperStore.restoring(original, provider: "local.flua.desktop.wallpaper", in: updated)
        precondition(NativeWallpaperStore.restorationMatches(original, in: restored))
        let containsFlua = try NativeWallpaperStore.containsProvider("local.flua.desktop.wallpaper", in: restored)
        precondition(!containsFlua)
        var touched = store
        var touchedDefault = old
        touchedDefault["Desktop"] = ["Content": ["Choices": [["Provider": "old-desktop"]]], "LastUse": Date()]
        touched["SystemDefault"] = touchedDefault
        let touchedData = try encode(touched)
        precondition(NativeWallpaperStore.restorationMatches(original, in: touchedData))
        let restoredAgain = try NativeWallpaperStore.restoring(original, provider: "local.flua.desktop.wallpaper", in: restored)
        precondition(restoredAgain == restored)
        var removalMixed = saved
        var removalDefault = saved["SystemDefault"] as! [String: Any]
        removalDefault["Idle"] = old["Idle"]
        removalDefault["Keep"] = "new metadata"
        removalMixed["SystemDefault"] = removalDefault
        removalMixed["Displays"] = ["display": old]
        let partial = try NativeWallpaperStore.restoring(original, provider: "local.flua.desktop.wallpaper", in: encode(removalMixed))
        let partialStore = try PropertyListSerialization.propertyList(from: partial, format: nil) as! [String: Any]
        precondition((partialStore["SystemDefault"] as! [String: Any])["Keep"] as? String == "new metadata")
        precondition(NSDictionary(dictionary: partialStore["Displays"] as! [String: Any]).isEqual(to: removalMixed["Displays"] as! [String: Any]))
        precondition(!NativeWallpaperStore.restorationMatches(original, in: partial))
        for baseline in [updated, try encode(["bad": true])] {
            let fallback = try NativeWallpaperStore.restoring(baseline, provider: "local.flua.desktop.wallpaper", in: updated)
            try assertDefaultFallback(fallback)
        }
        let noBaselineRestore = try NativeWallpaperStore.restoring(nil, provider: "local.flua.desktop.wallpaper", in: updated)
        try assertDefaultFallback(noBaselineRestore)
        var partialBaselineStore = store
        var partialBaselineDefault = old
        partialBaselineDefault["Desktop"] = ["Content": ["Choices": [choice]]]
        partialBaselineStore["SystemDefault"] = partialBaselineDefault
        let partialBaseline = try NativeWallpaperStore.restoring(encode(partialBaselineStore), provider: "local.flua.desktop.wallpaper", in: updated)
        let partialBaselineResult = try PropertyListSerialization.propertyList(from: partialBaseline, format: nil) as! [String: Any]
        let partialSystemDefault = partialBaselineResult["SystemDefault"] as! [String: Any]
        precondition(isDefaultSurface(partialSystemDefault["Desktop"]))
        precondition(NSDictionary(dictionary: partialSystemDefault["Idle"] as! [String: Any]).isEqual(to: old["Idle"] as! [String: Any]))
        var missingSurfaceBaselineStore = store
        var missingSurfaceDefault = old
        missingSurfaceDefault.removeValue(forKey: "Desktop")
        missingSurfaceBaselineStore["SystemDefault"] = missingSurfaceDefault
        let missingSurfaceBaseline = try NativeWallpaperStore.restoring(encode(missingSurfaceBaselineStore), provider: "local.flua.desktop.wallpaper", in: updated)
        let missingSurfaceResult = try PropertyListSerialization.propertyList(from: missingSurfaceBaseline, format: nil) as! [String: Any]
        let missingSurfaceDefaultResult = missingSurfaceResult["SystemDefault"] as! [String: Any]
        precondition(isDefaultSurface(missingSurfaceDefaultResult["Desktop"]))
        precondition(NSDictionary(dictionary: missingSurfaceDefaultResult["Idle"] as! [String: Any]).isEqual(to: old["Idle"] as! [String: Any]))
        var damagedBaselineStore = store
        var damagedBaselineDefault = old
        damagedBaselineDefault["Desktop"] = ["Content": ["Choices": [[:]]]]
        damagedBaselineStore["SystemDefault"] = damagedBaselineDefault
        let damagedBaseline = try encode(damagedBaselineStore)
        let damagedStop = try NativeWallpaperStore.stopping(displays: ["display"], provider: "local.flua.desktop.wallpaper", in: updated, baseline: damagedBaseline)
        let damagedStopResult = try PropertyListSerialization.propertyList(from: damagedStop, format: nil) as! [String: Any]
        let damagedStopDefault = (damagedStopResult["SystemDefault"] as! [String: Any])
        precondition(isDefaultSurface(damagedStopDefault["Desktop"]))
        precondition(NSDictionary(dictionary: damagedStopDefault["Idle"] as! [String: Any]).isEqual(to: old["Idle"] as! [String: Any]))
        let damagedRemoval = try NativeWallpaperStore.restoring(damagedBaseline, provider: "local.flua.desktop.wallpaper", in: updated)
        let damagedRemovalResult = try PropertyListSerialization.propertyList(from: damagedRemoval, format: nil) as! [String: Any]
        let damagedRemovalDefault = damagedRemovalResult["SystemDefault"] as! [String: Any]
        precondition(isDefaultSurface(damagedRemovalDefault["Desktop"]))
        precondition(NSDictionary(dictionary: damagedRemovalDefault["Idle"] as! [String: Any]).isEqual(to: old["Idle"] as! [String: Any]))
        var futureStore = saved
        var futureDefault = saved["SystemDefault"] as! [String: Any]
        futureDefault["Type"] = "future"
        futureStore["SystemDefault"] = futureDefault
        do { _ = try NativeWallpaperStore.restoring(original, provider: "local.flua.desktop.wallpaper", in: encode(futureStore)); preconditionFailure("Restored an unknown store format") }
        catch is NativeWallpaperError {}
        var newDisplay = saved
        newDisplay["Displays"] = ["new": saved["SystemDefault"]!]
        let inheritedRestore = try NativeWallpaperStore.restoring(original, provider: "local.flua.desktop.wallpaper", in: encode(newDisplay))
        let inheritedContainsFlua = try NativeWallpaperStore.containsProvider("local.flua.desktop.wallpaper", in: inheritedRestore)
        precondition(!inheritedContainsFlua)
        for type in ["linked", "desktop", "idle"] {
            var linkedStore = store
            var linked = old
            linked["Type"] = type
            linked["Linked"] = old["Desktop"]
            linkedStore["SystemDefault"] = linked
            let baseline = try encode(linkedStore)
            let applied = try NativeWallpaperStore.applying(assignments, mirrored: true, to: baseline)
            let restored = try NativeWallpaperStore.restoring(baseline, provider: "local.flua.desktop.wallpaper", in: applied)
            precondition(NativeWallpaperStore.restorationMatches(baseline, in: restored), "Failed to restore " + type)
        }
        var linkedOnlyStore = store
        linkedOnlyStore["SystemDefault"] = ["Type": "linked", "Linked": old["Desktop"]!]
        let linkedOnlyBaseline = try encode(linkedOnlyStore)
        let linkedOnlyApplied = try NativeWallpaperStore.applying(assignments, mirrored: true, to: linkedOnlyBaseline)
        let linkedOnlyRestored = try NativeWallpaperStore.restoring(linkedOnlyBaseline, provider: "local.flua.desktop.wallpaper", in: linkedOnlyApplied)
        precondition(NativeWallpaperStore.restorationMatches(linkedOnlyBaseline, in: linkedOnlyRestored))
        var linkedWithStaleSurfaceStore = store
        linkedWithStaleSurfaceStore["SystemDefault"] = [
            "Type": "linked",
            "Linked": old["Desktop"]!,
            "Desktop": ["Content": ["Choices": [choice]]]
        ]
        let linkedWithStaleSurfaceBaseline = try encode(linkedWithStaleSurfaceStore)
        let linkedWithStaleSurfaceApplied = try NativeWallpaperStore.applying(assignments, mirrored: true, to: linkedWithStaleSurfaceBaseline)
        let linkedWithStaleSurfaceRestored = try NativeWallpaperStore.restoring(linkedWithStaleSurfaceBaseline, provider: "local.flua.desktop.wallpaper", in: linkedWithStaleSurfaceApplied)
        let staleLinkedProviderRemains = try NativeWallpaperStore.containsProvider("local.flua.desktop.wallpaper", in: linkedWithStaleSurfaceRestored)
        precondition(!staleLinkedProviderRemains)
        var currentLinkedStore = saved
        var currentLinkedAssignment = currentLinkedStore["SystemDefault"] as! [String: Any]
        currentLinkedAssignment["Type"] = "linked"
        currentLinkedAssignment["Linked"] = ["Content": ["Choices": [choice]]]
        currentLinkedAssignment.removeValue(forKey: "Desktop")
        currentLinkedAssignment.removeValue(forKey: "Idle")
        currentLinkedStore["SystemDefault"] = currentLinkedAssignment
        let currentLinkedData = try encode(currentLinkedStore)
        let linkedMissingBaselineRestore = try NativeWallpaperStore.restoring(nil, provider: "local.flua.desktop.wallpaper", in: currentLinkedData)
        let linkedMissingBaselineStore = try PropertyListSerialization.propertyList(from: linkedMissingBaselineRestore, format: nil) as! [String: Any]
        let linkedMissingBaselineAssignment = linkedMissingBaselineStore["SystemDefault"] as! [String: Any]
        precondition(isDefaultSurface(linkedMissingBaselineAssignment["Desktop"]) && isDefaultSurface(linkedMissingBaselineAssignment["Idle"]))
        var unusableLinkedBaselineStore = store
        unusableLinkedBaselineStore["SystemDefault"] = ["Type": "linked", "Linked": ["Content": ["Choices": [choice]]]]
        let linkedUnusableBaselineRestore = try NativeWallpaperStore.restoring(encode(unusableLinkedBaselineStore), provider: "local.flua.desktop.wallpaper", in: currentLinkedData)
        let linkedUnusableBaselineStore = try PropertyListSerialization.propertyList(from: linkedUnusableBaselineRestore, format: nil) as! [String: Any]
        let linkedUnusableBaselineAssignment = linkedUnusableBaselineStore["SystemDefault"] as! [String: Any]
        precondition(isDefaultSurface(linkedUnusableBaselineAssignment["Desktop"]) && isDefaultSurface(linkedUnusableBaselineAssignment["Idle"]))
        print("PASS: native removal restores safe baseline assignments, preserves foreign choices and metadata, and uses macOS defaults for missing or Flua baselines")
        item.speed = 0.75
        item.dimming = 0.6
        item.trimStart = nil
        item.trimEnd = nil
        item.still = 1.25
        let replacement = try NativeWallpaperStore.choice(item, root: root, provider: "local.flua.desktop.wallpaper")
        let refreshed = try NativeWallpaperStore.refreshing(replacement, provider: "local.flua.desktop.wallpaper", in: updated)
        precondition(refreshed != updated)
        precondition(NativeWallpaperStore.refreshMatches(refreshed, in: refreshed, provider: "local.flua.desktop.wallpaper"))
        precondition(!NativeWallpaperStore.refreshMatches(refreshed, in: updated, provider: "local.flua.desktop.wallpaper"))
        let refreshedStore = try PropertyListSerialization.propertyList(from: refreshed, format: nil) as! [String: Any]
        let refreshedDefault = refreshedStore["SystemDefault"] as! [String: Any]
        let refreshedDesktop = refreshedDefault["Desktop"] as! [String: Any]
        let refreshedContent = refreshedDesktop["Content"] as! [String: Any]
        let refreshedChoice = (refreshedContent["Choices"] as! [[String: Any]])[0]
        let refreshedConfig = try JSONSerialization.jsonObject(with: refreshedChoice["Configuration"] as! Data) as! [String: Any]
        precondition(refreshedConfig["speed"] as? Double == 0.75 && refreshedConfig["dimming"] as? Double == 0.6)
        precondition(refreshedConfig["still"] as? Double == 1.25 && refreshedConfig["trim"] == nil)
        precondition(refreshedConfig["modes"] as? [String: String] == configuration["modes"] as? [String: String])
        var richPair = paired
        var richPairConfiguration = pairedConfiguration
        var richPairSurfaces = pairedSurfaces
        var richDesktop = richPairSurfaces["desktop"]!
        richDesktop["futureSetting"] = "keep desktop metadata"
        richPairSurfaces["desktop"] = richDesktop
        var richLockScreen = richPairSurfaces["lockScreen"]!
        richLockScreen["futureSetting"] = "keep lock metadata"
        richPairSurfaces["lockScreen"] = richLockScreen
        richPairConfiguration["surfaces"] = richPairSurfaces
        richPairConfiguration["futurePairSetting"] = "keep pair metadata"
        richPair["Configuration"] = try JSONSerialization.data(withJSONObject: richPairConfiguration, options: [.sortedKeys])
        let pairStore = try NativeWallpaperStore.applying(
            ["display": NativeWallpaperStore.Assignment(desktop: richPair, lockScreen: richPair)], mirrored: false, to: original)
        let refreshedPairStore = try NativeWallpaperStore.refreshing(replacement, provider: "local.flua.desktop.wallpaper", in: pairStore)
        let refreshedPairValue = try PropertyListSerialization.propertyList(from: refreshedPairStore, format: nil) as! [String: Any]
        let refreshedPairAssignment = (refreshedPairValue["Displays"] as! [String: Any])["display"] as! [String: Any]
        let refreshedPairChoice = (((refreshedPairAssignment["Desktop"] as! [String: Any])["Content"] as! [String: Any])["Choices"] as! [[String: Any]])[0]
        let refreshedPairConfig = try JSONSerialization.jsonObject(with: refreshedPairChoice["Configuration"] as! Data) as! [String: Any]
        let refreshedPairSurfaces = refreshedPairConfig["surfaces"] as! [String: [String: Any]]
        precondition(refreshedPairConfig["futurePairSetting"] as? String == "keep pair metadata")
        precondition(refreshedPairSurfaces["desktop"]?["speed"] as? Double == 0.75)
        precondition(refreshedPairSurfaces["desktop"]?["fileIndex"] as? Int == 0)
        precondition(refreshedPairSurfaces["desktop"]?["modes"] as? [String: String] == ["desktop": "still", "lockScreen": "animated"])
        precondition(refreshedPairSurfaces["desktop"]?["futureSetting"] as? String == "keep desktop metadata")
        precondition(NSDictionary(dictionary: refreshedPairSurfaces["lockScreen"]!).isEqual(to: richLockScreen))
        var updatedImageItem = imageItem
        updatedImageItem.speed = 0.9
        let updatedImageChoice = try NativeWallpaperStore.choice(updatedImageItem, root: root, provider: "local.flua.desktop.wallpaper")
        let refreshedLockPairStore = try NativeWallpaperStore.refreshing(updatedImageChoice, provider: "local.flua.desktop.wallpaper", in: refreshedPairStore)
        let refreshedLockPairValue = try PropertyListSerialization.propertyList(from: refreshedLockPairStore, format: nil) as! [String: Any]
        let refreshedLockPairAssignment = (refreshedLockPairValue["Displays"] as! [String: Any])["display"] as! [String: Any]
        let refreshedLockPairChoice = (((refreshedLockPairAssignment["Desktop"] as! [String: Any])["Content"] as! [String: Any])["Choices"] as! [[String: Any]])[0]
        let refreshedLockPairConfig = try JSONSerialization.jsonObject(with: refreshedLockPairChoice["Configuration"] as! Data) as! [String: Any]
        let refreshedLockPairSurfaces = refreshedLockPairConfig["surfaces"] as! [String: [String: Any]]
        precondition(refreshedLockPairSurfaces["desktop"]?["speed"] as? Double == 0.75)
        precondition(refreshedLockPairSurfaces["lockScreen"]?["speed"] as? Double == 0.9)
        precondition(refreshedLockPairSurfaces["lockScreen"]?["fileIndex"] as? Int == 1)
        precondition(refreshedLockPairSurfaces["lockScreen"]?["modes"] as? [String: String] == ["desktop": "animated", "lockScreen": "still"])
        precondition(refreshedLockPairSurfaces["lockScreen"]?["futureSetting"] as? String == "keep lock metadata")
        let unchanged = try NativeWallpaperStore.refreshing(replacement, provider: "local.flua.desktop.wallpaper", in: refreshed)
        precondition(unchanged == refreshed)
        let unrelated = try NativeWallpaperStore.refreshing(replacement, provider: "another-provider", in: updated)
        precondition(unrelated == updated)
        let unassigned = try NativeWallpaperStore.refreshing(replacement, provider: "local.flua.desktop.wallpaper", in: original)
        precondition(unassigned == original)
        var independent = choice
        var independentConfig = configuration
        independentConfig["modes"] = ["desktop": "animated", "lockScreen": "still"]
        independentConfig["futureSetting"] = "preserved"
        independent["Configuration"] = try JSONSerialization.data(withJSONObject: independentConfig)
        var mixedStore = store
        var mixedDefault = old
        mixedDefault["Desktop"] = ["Content": ["Choices": [choice, independent]], "LastSet": Date(timeIntervalSince1970: 50)]
        mixedDefault["Idle"] = ["Content": ["Choices": [["Provider": "another-provider"]]]]
        mixedStore["SystemDefault"] = mixedDefault
        let mixedData = try encode(mixedStore)
        var foreignMixed = mixedStore
        var foreignDefault = mixedDefault
        foreignDefault["Desktop"] = ["Content": ["Choices": [choice, ["Provider": "foreign"]]]]
        foreignMixed["SystemDefault"] = foreignDefault
        let foreignMixedRestored = try NativeWallpaperStore.restoring(original, provider: "local.flua.desktop.wallpaper", in: encode(foreignMixed))
        let foreignMixedResult = try PropertyListSerialization.propertyList(from: foreignMixedRestored, format: nil) as! [String: Any]
        let foreignMixedChoices = (((foreignMixedResult["SystemDefault"] as! [String: Any])["Desktop"] as! [String: Any])["Content"] as! [String: Any])["Choices"] as! [[String: Any]]
        precondition(foreignMixedChoices.map { $0["Provider"] as? String } == ["foreign"])
        let mixedRefresh = try NativeWallpaperStore.refreshing(replacement, provider: "local.flua.desktop.wallpaper", in: mixedData)
        let mixedResult = try PropertyListSerialization.propertyList(from: mixedRefresh, format: nil) as! [String: Any]
        let mixedAssignment = mixedResult["SystemDefault"] as! [String: Any]
        precondition(NSDictionary(dictionary: mixedAssignment["Idle"] as! [String: Any]).isEqual(to: mixedDefault["Idle"] as! [String: Any]))
        let desktop = mixedAssignment["Desktop"] as! [String: Any]
        precondition(desktop["LastSet"] as? Date == Date(timeIntervalSince1970: 50))
        let choices = (desktop["Content"] as! [String: Any])["Choices"] as! [[String: Any]]
        let independentResult = try JSONSerialization.jsonObject(with: choices[1]["Configuration"] as! Data) as! [String: Any]
        precondition(independentResult["modes"] as? [String: String] == ["desktop": "animated", "lockScreen": "still"])
        precondition(independentResult["futureSetting"] as? String == "preserved")
        precondition(independentResult["speed"] as? Double == 0.75)
        var otherFile = replacement
        otherFile["Files"] = [["relative": root.appendingPathComponent("Media/other.mov").absoluteString]]
        let otherFileResult = try NativeWallpaperStore.refreshing(otherFile, provider: "local.flua.desktop.wallpaper", in: mixedData)
        precondition(otherFileResult == mixedData)
        var changed = saved
        changed["Displays"] = ["display": old]
        let changedData = try encode(changed)
        precondition(!NativeWallpaperStore.matches(assignments, mirrored: true, in: changedData))
        for invalid: Any in [[], ["SystemDefault": [:]], ["SystemDefault": ["Type": "future"], "AllSpacesAndDisplays": [:], "Spaces": [:], "Displays": [:]], ["SystemDefault": old, "AllSpacesAndDisplays": [:], "Spaces": [], "Displays": [:]], ["SystemDefault": old, "AllSpacesAndDisplays": [], "Spaces": [:], "Displays": [:]]] {
            do { _ = try NativeWallpaperStore.applying(assignments, mirrored: true, to: encode(invalid)); preconditionFailure("Accepted unsupported store") }
            catch is NativeWallpaperError {}
        }
        do { _ = try NativeWallpaperStore.refreshing(replacement, provider: "local.flua.desktop.wallpaper", in: encode(["unexpected": choice])); preconditionFailure("Refreshed an unsupported store") }
        catch is NativeWallpaperError {}
        do { _ = try NativeWallpaperStore.applying(assignments, mirrored: true, to: Data(repeating: 0, count: NativeWallpaperStore.maximumSize + 1)); preconditionFailure("Accepted oversized store") }
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
        item.file = "Media/video.mov"
        _ = try NativeWallpaperStore.choice(item, root: root, provider: "test")
        var state = LibraryState.initial
        state.assign("aurora", display: "A")
        state.setMode(.still, display: "A", surface: .desktop)
        state.assign("ocean", display: "A", surface: .lockScreen)
        state.assign("ember", display: "B")
        state.setSurfacesLinked(true, display: "B")
        state.assign("cosmos", display: "disconnected")
        let resolved = try NativeWallpaperStore.assignments(from: state, displays: ["A", "B", "unassigned"], root: root, provider: "test")
        precondition(Set(resolved.keys) == ["A", "B"])
        func config(_ choice: [String: Any]?) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: choice!["Configuration"] as! Data) as! [String: Any]
        }
        let desktopConfig = try config(resolved["A"]!.desktop)
        let lockConfig = try config(resolved["A"]!.lockScreen)
        precondition(desktopConfig["version"] as? Int == 2)
        let resolvedSurfaces = desktopConfig["surfaces"] as! [String: [String: Any]]
        precondition(resolvedSurfaces["desktop"]?["kind"] as? String == "aurora")
        precondition(resolvedSurfaces["desktop"]?["modes"] as? [String: String] == ["desktop": "still", "lockScreen": "still"])
        precondition(resolvedSurfaces["lockScreen"]?["kind"] as? String == "ocean")
        precondition(NSDictionary(dictionary: desktopConfig).isEqual(to: lockConfig))
        precondition(NSDictionary(dictionary: resolved["B"]!.desktop!).isEqual(to: resolved["B"]!.lockScreen!))
        var mediaState = LibraryState.initial
        mediaState.wallpapers.append(Wallpaper(id: "video-choice", title: "Video", kind: "video", file: "video.mov"))
        mediaState.wallpapers.append(Wallpaper(id: "image-choice", title: "Image", kind: "image", file: "image.png"))
        mediaState.assign("video-choice", display: "A")
        mediaState.setMode(.still, display: "A", surface: .desktop)
        mediaState.assign("image-choice", display: "A", surface: .lockScreen)
        mediaState.assign("image-choice", display: "B")
        mediaState.setSurfacesLinked(true, display: "B")
        let mediaAssignments = try NativeWallpaperStore.assignments(from: mediaState, displays: ["A", "B"], root: root, provider: "test")
        let mediaA = try config(mediaAssignments["A"]!.desktop)
        let mediaB = try config(mediaAssignments["B"]!.desktop)
        let mediaASurfaces = mediaA["surfaces"] as! [String: [String: Any]]
        let mediaBSurfaces = mediaB["surfaces"] as! [String: [String: Any]]
        precondition(mediaASurfaces["desktop"]?["kind"] as? String == "video")
        precondition(mediaASurfaces["desktop"]?["modes"] as? [String: String] == ["desktop": "still", "lockScreen": "still"])
        precondition(mediaASurfaces["lockScreen"]?["kind"] as? String == "image")
        precondition(mediaBSurfaces["desktop"]?["kind"] as? String == "image")
        precondition(NSDictionary(dictionary: mediaAssignments["B"]!.desktop!).isEqual(to: mediaAssignments["B"]!.lockScreen!))
        let perDisplay = try NativeWallpaperStore.applying(resolved, mirrored: false, to: original)
        precondition(NativeWallpaperStore.matches(resolved, mirrored: false, in: perDisplay))
        let perStore = try PropertyListSerialization.propertyList(from: perDisplay, format: nil) as! [String: Any]
        precondition(NSDictionary(dictionary: perStore["SystemDefault"] as! [String: Any]).isEqual(to: old))
        precondition(perStore["AllSpacesAndDisplays"] as? String == "$null")
        let removedPerDisplay = try NativeWallpaperStore.restoring(original, provider: "test", in: perDisplay)
        let perDisplayContainsProvider = try NativeWallpaperStore.containsProvider("test", in: removedPerDisplay)
        precondition(!perDisplayContainsProvider)
        let removalPerStore = try PropertyListSerialization.propertyList(from: removedPerDisplay, format: nil) as! [String: Any]
        precondition(removalPerStore["AllSpacesAndDisplays"] as? String == "$null")
        let restoredA = (removalPerStore["Displays"] as! [String: Any])["A"] as! [String: Any]
        precondition(NSDictionary(dictionary: restoredA["Desktop"] as! [String: Any]).isEqual(to: old["Desktop"] as! [String: Any]))
        let stopBaseline = try NativeWallpaperStore.stopping(displays: ["A", "B"], provider: "test", in: perDisplay, baseline: original, captureBaseline: true)
        let removedFromStopBaseline = try NativeWallpaperStore.restoring(stopBaseline, provider: "test", in: perDisplay)
        precondition(NativeWallpaperStore.stopMatches(removedPerDisplay, in: removedFromStopBaseline))
        let refreshedPerDisplay = try NativeWallpaperStore.refreshing(scene, provider: "test", in: perDisplay)
        let refreshedPerStore = try PropertyListSerialization.propertyList(from: refreshedPerDisplay, format: nil) as! [String: Any]
        precondition(refreshedPerStore["AllSpacesAndDisplays"] as? String == "$null")
        precondition(refreshedPerDisplay != perDisplay)
        precondition(NativeWallpaperStore.refreshMatches(refreshedPerDisplay, in: refreshedPerDisplay, provider: "test"))
        let reapplied = try NativeWallpaperStore.applying(resolved, mirrored: false, to: perDisplay)
        precondition(NativeWallpaperStore.matches(resolved, mirrored: false, in: reapplied))
        let replacementAssignments = ["A": NativeWallpaperStore.Assignment(desktop: resolved["B"]!.desktop)]
        let replaced = try NativeWallpaperStore.replacing(replacementAssignments, displays: ["A", "B"], provider: "test",
            mirrored: false, in: perDisplay, baseline: original)
        precondition(NativeWallpaperStore.matches(replacementAssignments, mirrored: false, in: replaced))
        let restoredBeforeReplace = try NativeWallpaperStore.stopping(displays: ["A", "B"], provider: "test", in: perDisplay, baseline: original)
        let expectedReplacement = try NativeWallpaperStore.applying(replacementAssignments, mirrored: false, to: restoredBeforeReplace)
        precondition(NativeWallpaperStore.stopMatches(expectedReplacement, in: replaced))
        let replacedStore = try PropertyListSerialization.propertyList(from: replaced, format: nil) as! [String: Any]
        let replacedDisplays = replacedStore["Displays"] as! [String: Any]
        let restoredDisplayB = replacedDisplays["B"] as! [String: Any]
        precondition(NSDictionary(dictionary: restoredDisplayB["Desktop"] as! [String: Any]).isEqual(to: old["Desktop"] as! [String: Any]))
        precondition(NSDictionary(dictionary: restoredDisplayB["Idle"] as! [String: Any]).isEqual(to: old["Idle"] as! [String: Any]))
        let emptyReplacement = try NativeWallpaperStore.replacing([:], displays: ["A", "B"], provider: "test",
            mirrored: false, in: perDisplay, baseline: original)
        precondition(NativeWallpaperStore.stopMatches(removedPerDisplay, in: emptyReplacement))
        let mirroredAssignments = ["A": replacementAssignments["A"]!, "B": replacementAssignments["A"]!]
        let formerlyMirrored = try NativeWallpaperStore.applying(mirroredAssignments, mirrored: true, to: original)
        let perDisplayAfterMirror = try NativeWallpaperStore.replacing(replacementAssignments, displays: ["A", "B"], provider: "test",
            mirrored: false, in: formerlyMirrored, baseline: original)
        precondition(NativeWallpaperStore.matches(replacementAssignments, mirrored: false, in: perDisplayAfterMirror))
        let modeChangedStore = try PropertyListSerialization.propertyList(from: perDisplayAfterMirror, format: nil) as! [String: Any]
        let expectedDefault = try encode(["SystemDefault": old])
        let modeChangedDefault = try encode(["SystemDefault": modeChangedStore["SystemDefault"]!])
        precondition(NativeWallpaperStore.stopMatches(expectedDefault, in: modeChangedDefault))
        let stoppedAfterModeChange = try NativeWallpaperStore.stopping(displays: ["A", "B"], provider: "test",
            in: perDisplayAfterMirror, baseline: original, mirrored: false)
        let stoppedModeStore = try PropertyListSerialization.propertyList(from: stoppedAfterModeChange, format: nil) as! [String: Any]
        let stoppedModeDefault = try encode(["SystemDefault": stoppedModeStore["SystemDefault"]!])
        precondition(NativeWallpaperStore.stopMatches(expectedDefault, in: stoppedModeDefault))
        let stoppedModeUsesProvider = try NativeWallpaperStore.containsProvider("test", in: stoppedAfterModeChange)
        precondition(!stoppedModeUsesProvider)
        let remirrored = try NativeWallpaperStore.applying(assignments, mirrored: true, to: perDisplay)
        precondition(NativeWallpaperStore.matches(assignments, mirrored: true, in: remirrored))
        precondition(NSDictionary(dictionary: (perStore["Displays"] as! [String: Any])["display"] as! [String: Any]).isEqual(to: old))
        var malformed = store
        malformed["Displays"] = ["display": []]
        do { _ = try NativeWallpaperStore.applying(assignments, mirrored: false, to: encode(malformed)); preconditionFailure("Replaced malformed display data") }
        catch is NativeWallpaperError {}
        var globalStore = store
        globalStore["AllSpacesAndDisplays"] = old
        globalStore["SystemDefault"] = ["Type": "desktop", "Desktop": ["Keep": "old default"]]
        let globalData = try NativeWallpaperStore.applying(resolved, mirrored: false, to: encode(globalStore))
        let splitGlobal = try PropertyListSerialization.propertyList(from: globalData, format: nil) as! [String: Any]
        precondition(splitGlobal["AllSpacesAndDisplays"] as? String == "$null")
        precondition(NSDictionary(dictionary: splitGlobal["SystemDefault"] as! [String: Any]).isEqual(to: old))
        do { _ = try NativeWallpaperStore.applying(resolved, mirrored: true, to: original); preconditionFailure("Accepted mixed mirrored assignments") }
        catch is NativeWallpaperError {}
        let lockOnly = ["display": NativeWallpaperStore.Assignment(lockScreen: scene)]
        var linkedStore = store
        var linked = old
        linked["Type"] = "linked"
        linked["Linked"] = old["Desktop"]
        linkedStore["Displays"] = ["display": linked]
        let lockData = try NativeWallpaperStore.applying(lockOnly, mirrored: false, to: encode(linkedStore))
        precondition(NativeWallpaperStore.matches(lockOnly, mirrored: false, in: lockData))
        let lockStore = try PropertyListSerialization.propertyList(from: lockData, format: nil) as! [String: Any]
        let lockDisplay = (lockStore["Displays"] as! [String: Any])["display"] as! [String: Any]
        precondition(NSDictionary(dictionary: lockDisplay["Desktop"] as! [String: Any]).isEqual(to: old["Desktop"] as! [String: Any]))
        do { _ = try NativeWallpaperStore.assignments(from: state, displays: ["unassigned"], root: root, provider: "test"); preconditionFailure("Accepted empty assignments") }
        catch is NativeWallpaperError {}
        state.assign(state.wallpapers[0].id, display: "blocked")
        state.blockedTags = ["blocked"]
        state.wallpapers[0].tags = "blocked"
        do { _ = try NativeWallpaperStore.assignments(from: state, displays: ["blocked"], root: root, provider: "test"); preconditionFailure("Accepted blocked assignment") }
        catch is NativeWallpaperError {}
        let finalSource = try Data(contentsOf: source)
        precondition(finalSource == sourceData)
        print("PASS: active native edit refresh preserves independent modes, unknown settings, foreign choices and timestamps; no-op and different-media edits leave the store unchanged")
        print("PASS: direct native choices, safe media paths, preserved source files, all display/Space assignments, metadata retention, verification and unsupported-store rejection")
    }
}
