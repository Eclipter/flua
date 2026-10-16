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
        print("PASS: verified folder metadata, stored and nested ZIP extraction, source preservation, explicit unsupported-scene errors, cleanup, traversal, absolute/backslash/newline paths, symlinks, duplicate paths, file-directory collisions, AppleDouble and expansion limits")
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
