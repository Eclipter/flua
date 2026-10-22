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
        print("PASS: wallpaper-service PID parsing rejects missing, invalid and unsafe process IDs; the test process has no wallpaper extension")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Media"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Media/video.mov")
        let sourceData = Data("source must stay intact".utf8)
        try sourceData.write(to: source)
        var item = ProviderCatalog.Item(id: "clip", title: "Clip", kind: "video", file: "Media/video.mov", fit: "fit", speed: 1.5, dimming: 0.2, trimStart: 1, trimEnd: 3, still: 2)
        item.desktop = .still
        item.playbackPolicy = PlaybackPolicy(pauseOnBattery: true, pauseOnLowPower: true,
                                             lowPowerThreshold: -5, pauseOnFullscreen: false)
        let choice = try NativeWallpaperStore.choice(item, root: root, provider: "local.flua.desktop.wallpaper")
        let configuration = try JSONSerialization.jsonObject(with: choice["Configuration"] as! Data) as! [String: Any]
        precondition(configuration["kind"] as? String == "video")
        precondition(configuration["trim"] as? [Double] == [1, 3])
        precondition(configuration["modes"] as? [String: String] == ["desktop": "still", "lockScreen": "animated"])
        let descriptorPolicy = configuration["playbackPolicy"] as! [String: Any]
        precondition(descriptorPolicy["pauseOnBattery"] as? Bool == true)
        precondition(descriptorPolicy["pauseOnLowPower"] as? Bool == true)
        precondition(descriptorPolicy["lowPowerThreshold"] as? Int == 0)
        precondition(descriptorPolicy["pauseOnFullscreen"] as? Bool == false)
        precondition((choice["Files"] as? [[String: String]])?.first?["relative"] == source.resolvingSymlinksInPath().absoluteString)
        let preserved = try Data(contentsOf: source)
        precondition(preserved == sourceData)
        let assignments = ["display": NativeWallpaperStore.Assignment(desktop: choice, lockScreen: choice)]
        let old: [String: Any] = ["Type": "individual", "Desktop": ["Content": ["Choices": [["Provider": "old-desktop"]]]], "Idle": ["Content": ["Choices": [["Provider": "old-idle"]]]], "Keep": "metadata"]
        let store: [String: Any] = ["SystemDefault": old, "AllSpacesAndDisplays": [:], "Displays": ["display": old], "Spaces": ["space": ["Default": old, "Displays": ["display": old]]], "Keep": "root metadata"]
        func encode(_ value: Any) throws -> Data { try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0) }
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
        for baseline: Data? in [nil, updated] {
            do { _ = try NativeWallpaperStore.stopping(displays: ["display"], provider: "local.flua.desktop.wallpaper", in: updated, baseline: baseline); preconditionFailure("Stopped without a usable baseline") }
            catch is NativeWallpaperError {}
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
        let captureFresh = try NativeWallpaperStore.shouldCaptureBaseline(nil, provider: "local.flua.desktop.wallpaper", in: original)
        let skipExisting = try NativeWallpaperStore.shouldCaptureBaseline(nil, provider: "local.flua.desktop.wallpaper", in: updated)
        let refreshSaved = try NativeWallpaperStore.shouldCaptureBaseline(original, provider: "local.flua.desktop.wallpaper", in: updated)
        precondition(captureFresh && !skipExisting && refreshSaved)
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
        do { _ = try NativeWallpaperStore.stopping(displays: ["display"], provider: "local.flua.desktop.wallpaper", in: encode(mixedStopStore), baseline: original); preconditionFailure("Discarded a mixed-provider selection") }
        catch is NativeWallpaperError {}
        do { _ = try NativeWallpaperStore.stopping(displays: ["display"], provider: "test", in: encode(["Displays": [:]]), baseline: original); preconditionFailure("Accepted malformed stop store") }
        catch is NativeWallpaperError {}
        print("PASS: native Stop restores both surfaces, retains untargeted and foreign choices, survives repeated baseline capture, rejects missing baselines and verifies host timestamp changes")
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
            do { _ = try NativeWallpaperStore.restoring(baseline, provider: "local.flua.desktop.wallpaper", in: updated); preconditionFailure("Accepted unsafe restoration") }
            catch is NativeWallpaperError {}
        }
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
            precondition(NativeWallpaperStore.restorationMatches(baseline, in: restored))
        }
        print("PASS: native removal restores baseline assignments, preserves later foreign choices and metadata, handles repeat removal, and rejects missing or Flua baselines")
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
        do { _ = try NativeWallpaperStore.restoring(original, provider: "local.flua.desktop.wallpaper", in: encode(foreignMixed)); preconditionFailure("Overwrote a mixed foreign choice") }
        catch is NativeWallpaperError {}
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
        precondition(desktopConfig["kind"] as? String == "aurora")
        precondition(desktopConfig["modes"] as? [String: String] == ["desktop": "still", "lockScreen": "still"])
        precondition(lockConfig["kind"] as? String == "ocean")
        precondition(NSDictionary(dictionary: resolved["B"]!.desktop!).isEqual(to: resolved["B"]!.lockScreen!))
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
