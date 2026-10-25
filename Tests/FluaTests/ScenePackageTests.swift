import Foundation

@main struct ScenePackageTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FluaPackageTests-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let manifest = try JSONSerialization.data(withJSONObject: ["id": "fixture", "type": "video", "title": "A local video", "tags": ["calm", "water"], "files": ["asset": "clip.mov"]], options: [.sortedKeys])
        let video = Data([0, 0, 0, 16, 102, 116, 121, 112, 113, 116, 32, 32, 0, 0, 0, 0])
        let folder = root.appendingPathComponent("video-folder")
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        try manifest.write(to: folder.appendingPathComponent("fixture-manifest.json"))
        try video.write(to: folder.appendingPathComponent("clip.mov"))
        let contents = try ScenePackage.inspect(folder)
        precondition(contents.sceneKind == "video" && contents.title == "A local video" && contents.tags == "calm, water")
        precondition(contents.temporaryDirectory == nil)
        precondition((try? Data(contentsOf: contents.assetURL!)) == video)
        let direct = try ScenePackage.inspect(folder.appendingPathComponent("fixture-manifest.json"))
        precondition(direct.title == contents.title && direct.assetURL == contents.assetURL)
        contents.cleanup()
        precondition(fm.fileExists(atPath: folder.path))
        precondition((try? Data(contentsOf: folder.appendingPathComponent("fixture-manifest.json"))) == manifest)

        func archive(_ name: String, _ members: [Member]) throws -> URL {
            let url = root.appendingPathComponent(name + ".zip")
            try zip(members).write(to: url)
            return url
        }
        let base = [Member("manifest.json", manifest), Member("clip.mov", video)]
        for (name, members) in [("stored", base), ("nested", [Member("bundle/manifest.json", manifest), Member("bundle/clip.mov", video)])] {
            let url = try archive(name, members)
            let result = try ScenePackage.inspect(url)
            precondition((try? Data(contentsOf: result.assetURL!)) == video)
            let temporary = result.temporaryDirectory!
            precondition(fm.fileExists(atPath: temporary.path))
            result.cleanup()
            precondition(!fm.fileExists(atPath: temporary.path))
            precondition(fm.fileExists(atPath: url.path))
        }
        let wallpaperPackage = root.appendingPathComponent("portable.bdpkg")
        try zip(base).write(to: wallpaperPackage)
        let wallpaperResult = try ScenePackage.inspect(wallpaperPackage)
        precondition(wallpaperResult.title == "A local video")
        wallpaperResult.cleanup()
        let deflated = root.appendingPathComponent("deflated.zip")
        let zipProcess = Process()
        zipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zipProcess.currentDirectoryURL = folder
        zipProcess.arguments = ["-q", deflated.path, "fixture-manifest.json", "clip.mov"]
        try zipProcess.run()
        zipProcess.waitUntilExit()
        precondition(zipProcess.terminationStatus == 0)
        let compressedResult = try ScenePackage.inspect(deflated)
        precondition((try? Data(contentsOf: compressedResult.assetURL!)) == video)
        compressedResult.cleanup()

        let wildcardAsset = "clip*[?].mov"
        let wildcardManifest = try JSONSerialization.data(withJSONObject: ["type": "video", "files": ["asset": wildcardAsset]])
        let wildcardArchive = try archive("wildcard-members", [
            Member("manifest.json", wildcardManifest), Member(wildcardAsset, video),
            Member("clip-wildcard.mov", Data([1])), Member("clip*[x].mov", Data([2]))
        ])
        let wildcardResult = try ScenePackage.inspect(wildcardArchive)
        precondition(wildcardResult.assetURL?.lastPathComponent == wildcardAsset)
        let wildcardVideo = try Data(contentsOf: wildcardResult.assetURL!)
        precondition(wildcardVideo == video)
        wildcardResult.cleanup()

        func falseSizeArchive(_ name: String, members: [(String, Data, Int)]) throws -> (URL, [ScenePackage.Entry]) {
            let sourceDirectory = root.appendingPathComponent(name + "-source", isDirectory: true)
            try fm.createDirectory(at: sourceDirectory, withIntermediateDirectories: false)
            for (path, bytes, _) in members {
                let file = sourceDirectory.appendingPathComponent(path)
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: file)
            }
            let url = root.appendingPathComponent(name + ".zip")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.currentDirectoryURL = sourceDirectory
            process.arguments = ["-q", "-r", url.path] + members.map(\.0)
            try process.run()
            process.waitUntilExit()
            precondition(process.terminationStatus == 0)
            var bytes = try Data(contentsOf: url)
            var entries: [ScenePackage.Entry] = []
            for (path, contents, declaredSize) in members {
                entries.append(ScenePackage.Entry(name: path, size: declaredSize, isDirectory: false))
                let nameBytes = Data(path.utf8)
                var offset = 0
                while offset + 46 <= bytes.count {
                    let signature = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
                    if signature == 0x04034b50 || signature == 0x02014b50 {
                        let nameLengthOffset = offset + (signature == 0x04034b50 ? 26 : 28)
                        let extraLengthOffset = offset + (signature == 0x04034b50 ? 28 : 30)
                        let nameLength = Int(bytes[nameLengthOffset]) | Int(bytes[nameLengthOffset + 1]) << 8
                        let extraLength = Int(bytes[extraLengthOffset]) | Int(bytes[extraLengthOffset + 1]) << 8
                        let nameOffset = offset + (signature == 0x04034b50 ? 30 : 46)
                        if nameLength == nameBytes.count && bytes.subdata(in: nameOffset..<(nameOffset + nameLength)) == nameBytes {
                            let sizeOffset = offset + (signature == 0x04034b50 ? 22 : 24)
                            for index in 0..<4 { bytes[sizeOffset + index] = UInt8((declaredSize >> (index * 8)) & 255) }
                            offset = nameOffset + nameLength + extraLength
                        } else {
                            offset = nameOffset + nameLength + extraLength + (signature == 0x02014b50 ? (Int(bytes[offset + 32]) | Int(bytes[offset + 33]) << 8) : 0)
                        }
                    } else { offset += 1 }
                    if offset < 0 || offset > bytes.count { break }
                }
                precondition(contents.count != declaredSize || name == "false-total-size")
            }
            try bytes.write(to: url)
            return (url, entries)
        }
        for (name, members, memberLimit, totalLimit) in [
            ("false-member-size", [("large.bin", Data((0..<256_000).map { UInt8($0 % 251) }), 100_000)], 130_000, 300_000),
            ("false-total-size", [("first.bin", Data(repeating: 7, count: 100), 100), ("second.bin", Data(repeating: 8, count: 100), 80)], 120, 150)
        ] {
            let (url, entries) = try falseSizeArchive(name, members: members)
            let destination = root.appendingPathComponent(name + "-output", isDirectory: true)
            try fm.createDirectory(at: destination, withIntermediateDirectories: false)
            do {
                try ScenePackage.extractZIP(url, entries: entries, at: destination,
                                            maxMemberBytes: memberLimit, maxExpandedBytes: totalLimit)
                fatalError("Accepted \(name)")
            } catch let error as ScenePackageError {
                guard error.localizedDescription.contains("expanded size limit") else {
                    fatalError("Unexpected \(name) error: \(error.localizedDescription)")
                }
            }
            let iterator = fm.enumerator(at: destination, includingPropertiesForKeys: nil)!
            let sizes = try iterator.compactMap { item -> Int? in
                guard let item = item as? URL,
                      try fm.attributesOfItem(atPath: item.path)[.type] as? FileAttributeType == .typeRegular else { return nil }
                return (try fm.attributesOfItem(atPath: item.path)[.size] as? NSNumber)?.intValue
            }
            precondition(sizes.allSatisfy { $0 <= memberLimit } && sizes.reduce(0, +) <= totalLimit)
            precondition(name == "false-total-size" ? sizes == [100] : sizes.isEmpty)
        }

        let exactLimitArchive = try archive("exact-extraction-limit", [Member("clip.mov", video)])
        let exactLimitOutput = root.appendingPathComponent("exact-extraction-output", isDirectory: true)
        try fm.createDirectory(at: exactLimitOutput, withIntermediateDirectories: false)
        try ScenePackage.extractZIP(exactLimitArchive,
                                    entries: [ScenePackage.Entry(name: "clip.mov", size: video.count, isDirectory: false)],
                                    at: exactLimitOutput, maxMemberBytes: video.count, maxExpandedBytes: video.count)
        let exactLimitVideo = try Data(contentsOf: exactLimitOutput.appendingPathComponent("clip.mov"))
        precondition(exactLimitVideo == video)

        func reject(_ name: String, _ members: [Member]) throws {
            let url = try archive(name, members)
            do { let result = try ScenePackage.inspect(url); result.cleanup(); fatalError("Accepted \(name)") }
            catch is ScenePackageError {}
        }
        try reject("traversal", base + [Member("../escaped", Data())])
        try reject("absolute", base + [Member("/escaped", Data())])
        try reject("backslash", base + [Member("..\\escaped", Data())])
        try reject("symlink", base + [Member("linked", Data("../escaped".utf8), mode: 0o120777)])
        try reject("case-collision", base + [Member("CLIP.mov", video)])
        try reject("prefix-collision", base + [Member("clip.mov/child", Data())])
        try reject("newline-name", base + [Member("bad\nname", Data())])
        try reject("appledouble", base + [Member("__MACOSX/._clip.mov", Data())])
        try reject("unicode-path-alias", [Member("manifest.json", manifest), Member("clip.mov", video, extra: Data([0x75, 0x70, 0, 0]))])
        try reject("oversized", [Member("manifest.json", manifest), Member("bomb", Data(), declaredSize: 600 * 1_024 * 1_024)])
        let scene = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "type": "rive", "runtimeABI": 1, "entry": "scene.riv", "assets": [], "settings": [], "rive": ["stateMachine": "Main"]])
        let sceneURL = try archive("unsupported-rive", [Member("manifest.json", scene), Member("scene.riv", Data())])
        do { let result = try ScenePackage.inspect(sceneURL); result.cleanup(); fatalError("Accepted a Rive scene") }
        catch ScenePackageError.unsupportedScene(let kind) { precondition(kind == "rive") }
        let escapingManifest = try JSONSerialization.data(withJSONObject: ["type": "video", "files": ["asset": "../outside.mov"]])
        try escapingManifest.write(to: folder.appendingPathComponent("fixture-manifest.json"))
        do { _ = try ScenePackage.inspect(folder); fatalError("Accepted an escaping video path") }
        catch is ScenePackageError {}
        try manifest.write(to: folder.appendingPathComponent("fixture-manifest.json"))
        try fm.createSymbolicLink(atPath: folder.appendingPathComponent("link").path, withDestinationPath: "/tmp")
        do { _ = try ScenePackage.inspect(folder); fatalError("Accepted a folder symbolic link") }
        catch is ScenePackageError {}
        print("PASS: verified folder metadata, ZIP and .bdpkg extraction, literal wildcard filenames, source preservation, explicit unsupported-scene errors, cleanup, traversal, absolute/backslash/newline paths, symlinks, duplicate paths, file-directory collisions, AppleDouble and bounded extraction at positive and exact limits")
    }

    struct Member {
        let name: String
        let bytes: Data
        var mode: Int = 0o100600
        var declaredSize: Int? = nil
        let extra: Data
        init(_ name: String, _ bytes: Data, mode: Int = 0o100600, declaredSize: Int? = nil, extra: Data = Data()) {
            self.name = name; self.bytes = bytes; self.mode = mode; self.declaredSize = declaredSize; self.extra = extra
        }
    }

    static func zip(_ members: [Member]) -> Data {
        var output = Data(), central = Data()
        func u16(_ d: inout Data, _ n: Int) { d.append(UInt8(n & 255)); d.append(UInt8((n >> 8) & 255)) }
        func u32(_ d: inout Data, _ n: Int) { u16(&d, n & 65535); u16(&d, (n >> 16) & 65535) }
        func crc(_ bytes: Data) -> Int {
            var value: UInt32 = 0xffffffff
            for byte in bytes {
                value ^= UInt32(byte)
                for _ in 0..<8 { value = (value >> 1) ^ ((value & 1) == 1 ? 0xedb88320 : 0) }
            }
            return Int(value ^ 0xffffffff)
        }
        for member in members {
            let name = Data(member.name.utf8), local = output.count, checksum = crc(member.bytes)
            let size = member.declaredSize ?? member.bytes.count
            u32(&output, 0x04034b50); u16(&output, 20); u16(&output, 0); u16(&output, 0)
            u16(&output, 0); u16(&output, 0); u32(&output, checksum)
            u32(&output, member.bytes.count); u32(&output, size); u16(&output, name.count); u16(&output, member.extra.count)
            output.append(name); output.append(member.extra); output.append(member.bytes)
            u32(&central, 0x02014b50); u16(&central, 0x0314); u16(&central, 20)
            u16(&central, 0); u16(&central, 0); u16(&central, 0); u16(&central, 0)
            u32(&central, checksum); u32(&central, member.bytes.count); u32(&central, size)
            u16(&central, name.count); u16(&central, member.extra.count); u16(&central, 0); u16(&central, 0); u16(&central, 0)
            u32(&central, member.mode << 16); u32(&central, local); central.append(name); central.append(member.extra)
        }
        let start = output.count
        output.append(central)
        u32(&output, 0x06054b50); u16(&output, 0); u16(&output, 0)
        u16(&output, members.count); u16(&output, members.count); u32(&output, central.count); u32(&output, start); u16(&output, 0)
        return output
    }
}
