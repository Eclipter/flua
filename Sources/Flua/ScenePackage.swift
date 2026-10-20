import Foundation
import Darwin

/// Owns a temporary extraction only when `temporaryDirectory` is non-nil.
/// Keep the result alive until its asset has been copied into the local library,
/// then call `cleanup()`. The original package is never changed.
struct ScenePackageContents: @unchecked Sendable {
    let manifest: [String: Any]
    let assetURL: URL?
    let rootURL: URL
    let sceneKind: String
    let title: String
    let tags: String
    let temporaryDirectory: URL?

    func cleanup() {
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
    }
}

enum ScenePackageError: LocalizedError {
    case invalid(String)
    case unsupportedScene(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let detail): return "This package could not be imported: \(detail)"
        case .unsupportedScene(let kind):
            return "This \(kind) wallpaper needs an unsupported runtime. Add an image, video or supported video wallpaper package instead."
        }
    }
}

/// Imports Flua video manifests from folders, JSON files, or ZIP archives.
/// Validates paths and archive contents before copying media into the library.
struct ScenePackage {
    private static let maxArchive = 512 * 1_024 * 1_024
    private static let maxExpanded = 1_024 * 1_024 * 1_024
    private static let maxMember = 512 * 1_024 * 1_024
    private static let maxEntries = 4_096
    private static let maxManifest = 1_024 * 1_024
    private static let fm = FileManager.default

    static func inspect(_ url: URL) throws -> ScenePackageContents {
        var staging: URL?
        do {
            let input = url.standardizedFileURL
            let attributes = try fm.attributesOfItem(atPath: input.path)
            let source = try canonicalExisting(input)
            guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
                throw ScenePackageError.invalid("symbolic links are not supported.")
            }
            let root: URL
            var explicitManifest: URL?
            if attributes[.type] as? FileAttributeType == .typeDirectory {
                root = source
            } else if source.pathExtension.lowercased() == "json", attributes[.type] as? FileAttributeType == .typeRegular {
                explicitManifest = source
                root = source.deletingLastPathComponent()
            } else {
                guard ["zip", "bdpkg"].contains(source.pathExtension.lowercased()),
                      attributes[.type] as? FileAttributeType == .typeRegular,
                      (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= maxArchive else {
                    throw ScenePackageError.invalid("choose a package folder, .zip, or .bdpkg archive smaller than 512 MB.")
                }
                let temporary = try canonicalExisting(fm.temporaryDirectory).appendingPathComponent("Flua-Package-" + UUID().uuidString, isDirectory: true)
                try fm.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                staging = temporary
                // Freeze the archive inside a private directory before validation.
                let frozen = temporary.appendingPathComponent("input.zip")
                try fm.copyItem(at: source, to: frozen)
                let archive = try Data(contentsOf: frozen, options: .mappedIfSafe)
                let entries = try preflightZIP(archive)
                // zipinfo independently checks that the system ZIP reader agrees
                // about every member before ditto is allowed to extract anything.
                let listed = try run("/usr/bin/zipinfo", ["-1", frozen.path])
                guard let listing = String(data: listed, encoding: .utf8),
                      listing.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) == entries.map(\.name) else {
                    throw ScenePackageError.invalid("the ZIP readers disagree about its members.")
                }
                let extracted = temporary.appendingPathComponent("contents", isDirectory: true)
                try fm.createDirectory(at: extracted, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                _ = try run("/usr/bin/ditto", ["-x", "-k", "--norsrc", "--noextattr", "--noacl", frozen.path, extracted.path])
                try validateTree(extracted)
                try verifyExtraction(entries, at: extracted)
                root = try packageRoot(extracted)
            }
            // A directly selected manifest may live beside unrelated user files.
            // Inspect only that manifest and its named media, without walking its parent.
            if explicitManifest == nil { try validateTree(root) }
            let manifestURL = try explicitManifest ?? locateManifest(root)
            let size = try fm.attributesOfItem(atPath: manifestURL.path)[.size] as? NSNumber
            guard (size?.intValue ?? Int.max) <= maxManifest else {
                throw ScenePackageError.invalid("the manifest is larger than 1 MB.")
            }
            let data = try Data(contentsOf: manifestURL)
            guard let text = String(data: data, encoding: .utf8), !text.hasPrefix("\u{feff}"),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ScenePackageError.invalid("the manifest must be a UTF-8 JSON object.")
            }
            let kind = object["type"] as? String ?? "unknown"
            guard kind == "video" else { throw ScenePackageError.unsupportedScene(kind) }
            guard let files = object["files"] as? [String: Any], let relative = files["asset"] as? String else {
                throw ScenePackageError.invalid("the video manifest has no files.asset path.")
            }
            let asset = try safeChild(relative, of: root)
            let assetAttributes = try fm.attributesOfItem(atPath: asset.path)
            guard assetAttributes[.type] as? FileAttributeType == .typeRegular,
                  ["mov", "mp4", "m4v"].contains(asset.pathExtension.lowercased()) else {
                throw ScenePackageError.invalid("files.asset must name a local QuickTime or MP4 video.")
            }
            let rawTitle = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = rawTitle?.isEmpty == false ? rawTitle! : source.deletingPathExtension().lastPathComponent
            let tags = (object["tags"] as? [String])?.joined(separator: ", ") ?? (object["tags"] as? String ?? "")
            return ScenePackageContents(manifest: object, assetURL: asset, rootURL: root,
                                        sceneKind: kind, title: title, tags: tags, temporaryDirectory: staging)
        } catch {
            if let staging { try? fm.removeItem(at: staging) }
            if let error = error as? ScenePackageError { throw error }
            throw ScenePackageError.invalid(error.localizedDescription)
        }
    }

    private static func canonicalExisting(_ url: URL) throws -> URL {
        guard let resolved = realpath(url.path, nil) else {
            throw ScenePackageError.invalid("a package path could not be resolved.")
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    private static func packageRoot(_ directory: URL) throws -> URL {
        if (try? locateManifest(directory)) != nil { return directory }
        let children = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        if children.count == 1, try children[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
           (try? locateManifest(children[0])) != nil { return children[0] }
        throw ScenePackageError.invalid("no single package manifest was found.")
    }

    private static func locateManifest(_ root: URL) throws -> URL {
        let names = try fm.contentsOfDirectory(atPath: root.path)
        let candidates = names.filter { $0 == "manifest.json" || $0.hasSuffix("-manifest.json") }
        guard candidates.count == 1 else {
            throw ScenePackageError.invalid("a package must contain one manifest.json or *-manifest.json file.")
        }
        let result = root.appendingPathComponent(candidates[0])
        guard try fm.attributesOfItem(atPath: result.path)[.type] as? FileAttributeType == .typeRegular else {
            throw ScenePackageError.invalid("the manifest is not a regular file.")
        }
        return result
    }

    private static func safeChild(_ name: String, of root: URL, directory: Bool = false) throws -> URL {
        var path = name
        if directory && path.hasSuffix("/") { path.removeLast() }
        guard !path.isEmpty, path.utf8.count <= 1_024, !path.hasPrefix("/"),
              !path.contains("\\"), !path.contains(":"),
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw ScenePackageError.invalid("an unsafe file path was found.")
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 16, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0 != "__MACOSX" && !$0.hasPrefix("._") }) else {
            throw ScenePackageError.invalid("an unsafe or excessively deep file path was found.")
        }
        let result = root.appendingPathComponent(path, isDirectory: directory)
        let noLink = try !fm.fileExists(atPath: result.path) || canonicalExisting(result).path == result.path
        guard result.path.hasPrefix(root.path + "/"), noLink else {
            throw ScenePackageError.invalid("a file path escapes the package or uses a symbolic link.")
        }
        return result
    }

    private static func validateTree(_ root: URL) throws {
        guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: []) else {
            throw ScenePackageError.invalid("the package folder is unreadable.")
        }
        var total = 0, count = 0
        var identities = Set<String>()
        for case let child as URL in iterator {
            count += 1
            guard count <= maxEntries else { throw ScenePackageError.invalid("too many package entries.") }
            let relative = String(child.path.dropFirst(root.path.count + 1))
            _ = try safeChild(relative, of: root)
            let key = relative.precomposedStringWithCanonicalMapping.lowercased()
            guard identities.insert(key).inserted else { throw ScenePackageError.invalid("duplicate file paths.") }
            let attributes = try fm.attributesOfItem(atPath: child.path)
            let type = attributes[.type] as? FileAttributeType
            guard type == .typeDirectory || type == .typeRegular else {
                throw ScenePackageError.invalid("links and special files are not supported.")
            }
            if type == .typeRegular {
                guard (attributes[.referenceCount] as? NSNumber)?.intValue ?? 1 == 1 else {
                    throw ScenePackageError.invalid("hard-linked files are not supported.")
                }
                let size = (attributes[.size] as? NSNumber)?.intValue ?? Int.max
                guard size <= maxMember, total <= maxExpanded - size else {
                    throw ScenePackageError.invalid("the package exceeds the expanded size limit.")
                }
                total += size
            }
        }
    }

    private struct Entry {
        let name: String
        let size: Int
        let isDirectory: Bool
    }

    private static func preflightZIP(_ d: Data) throws -> [Entry] {
        func u16(_ p: Int) throws -> Int {
            guard p >= 0, p <= d.count - 2 else { throw ScenePackageError.invalid("a ZIP header is truncated.") }
            return Int(d[p]) | Int(d[p + 1]) << 8
        }
        func u32(_ p: Int) throws -> Int { try u16(p) | (u16(p + 2) << 16) }
        func bad(_ message: String) -> ScenePackageError { .invalid(message) }
        guard d.count >= 22, d.count <= maxArchive else { throw bad("the archive size is unsupported.") }
        let end = d.count - 22
        guard try u32(end) == 0x06054b50, try u16(end + 4) == 0, try u16(end + 6) == 0, try u16(end + 20) == 0 else {
            throw bad("this must be a single-disk ZIP without comments.")
        }
        let count = try u16(end + 10), centralSize = try u32(end + 12), central = try u32(end + 16)
        guard count > 0, count <= maxEntries, try u16(end + 8) == count,
              central >= 0, centralSize <= end, central == end - centralSize else {
            throw bad("the ZIP central directory is invalid or uses ZIP64.")
        }
        var position = central, total = 0
        var names = Set<String>(), fileNames = Set<String>(), directoryNames = Set<String>()
        var entries: [Entry] = [], spans: [(Int, Int)] = []
        for _ in 0..<count {
            guard try u32(position) == 0x02014b50 else { throw bad("an invalid ZIP directory entry was found.") }
            let flags = try u16(position + 8), method = try u16(position + 10)
            let crc = try u32(position + 16), compressed = try u32(position + 20), size = try u32(position + 24)
            let nameLength = try u16(position + 28), extraLength = try u16(position + 30), commentLength = try u16(position + 32)
            let external = try u32(position + 38), local = try u32(position + 42)
            let next = position + 46 + nameLength + extraLength + commentLength
            guard flags & ~0x0800 == 0, [0, 8].contains(method), try u16(position + 34) == 0,
                  next <= end, nameLength > 0, nameLength <= 1_024, compressed <= maxArchive, size <= maxMember,
                  local < central, local <= central - 30 else {
                throw bad("encrypted, streaming, ZIP64, oversized or malformed ZIP entries are unsupported.")
            }
            let nameBytes = d.subdata(in: position + 46..<position + 46 + nameLength)
            guard let name = String(data: nameBytes, encoding: .utf8) else { throw bad("ZIP filenames must be UTF-8.") }
            let isDirectory = name.hasSuffix("/")
            _ = try safeChild(name, of: URL(fileURLWithPath: "/__FluaPackageValidation"), directory: isDirectory)
            let plain = isDirectory ? String(name.dropLast()) : name
            let normalized = plain.precomposedStringWithCanonicalMapping.lowercased()
            guard names.insert(normalized).inserted else { throw bad("duplicate ZIP paths were found.") }
            if isDirectory { directoryNames.insert(normalized) } else { fileNames.insert(normalized) }
            let mode = (external >> 16) & 0xf000
            guard (mode == 0 || mode == (isDirectory ? 0x4000 : 0x8000)),
                  !isDirectory || (size == 0 && compressed == 0),
                  method != 0 || compressed == size,
                  size <= 16 * 1_024 * 1_024 || (compressed > 0 && size / compressed <= 250),
                  total <= maxExpanded - size else {
                throw bad("a ZIP link, special file or excessive expansion was found.")
            }
            total += size
            func checkExtras(_ begin: Int, _ length: Int) throws {
                var extra = begin
                let extraEnd = begin + length
                while extra < extraEnd {
                    guard extra <= extraEnd - 4 else { throw bad("a ZIP extra field is truncated.") }
                    let kind = try u16(extra), size = try u16(extra + 2)
                    // Only timestamp/UID metadata is accepted. In particular,
                    // Unicode-path aliases or platform link metadata could make
                    // an extractor choose a different path than the raw name.
                    guard [0x5455, 0x7875, 0x5855, 0x000a].contains(kind), extra + 4 + size <= extraEnd else {
                        throw bad("a ZIP extra field changes path semantics or uses an unsupported format.")
                    }
                    extra += 4 + size
                }
            }
            try checkExtras(position + 46 + nameLength, extraLength)
            guard try u32(local) == 0x04034b50, try u16(local + 6) == flags, try u16(local + 8) == method,
                  try u32(local + 14) == crc, try u32(local + 18) == compressed, try u32(local + 22) == size,
                  try u16(local + 26) == nameLength else { throw bad("ZIP local and central headers disagree.") }
            let localExtra = try u16(local + 28)
            let start = local + 30 + nameLength + localExtra
            guard start <= central, compressed <= central - start,
                  d.subdata(in: local + 30..<local + 30 + nameLength) == nameBytes else {
                throw bad("a ZIP member extends outside its data area.")
            }
            try checkExtras(local + 30 + nameLength, localExtra)
            spans.append((local, start + compressed))
            entries.append(Entry(name: name, size: size, isDirectory: isDirectory))
            position = next
        }
        guard position == end else { throw bad("trailing ZIP directory data was found.") }
        let sorted = spans.sorted { $0.0 < $1.0 }
        guard sorted.first?.0 == 0 else { throw bad("self-extracting ZIPs are unsupported.") }
        for i in 1..<sorted.count where sorted[i].0 < sorted[i - 1].1 { throw bad("ZIP member data overlaps.") }
        for name in names {
            let parts = name.split(separator: "/")
            if parts.count > 1 {
                for i in 1..<parts.count where fileNames.contains(parts.prefix(i).joined(separator: "/")) {
                    throw bad("a ZIP path is both a file and a directory.")
                }
            }
        }
        guard fileNames.isDisjoint(with: directoryNames) else { throw bad("conflicting ZIP path types.") }
        return entries
    }

    private static func verifyExtraction(_ entries: [Entry], at root: URL) throws {
        let declared = Dictionary(uniqueKeysWithValues: entries.filter { !$0.isDirectory }.map { ($0.name, $0.size) })
        var observed = Set<String>()
        guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw ScenePackageError.invalid("the extracted package is unreadable.")
        }
        for case let item as URL in iterator {
            let attributes = try fm.attributesOfItem(atPath: item.path)
            if attributes[.type] as? FileAttributeType == .typeRegular {
                let name = String(item.path.dropFirst(root.path.count + 1))
                guard let size = declared[name], (attributes[.size] as? NSNumber)?.intValue == size else {
                    throw ScenePackageError.invalid("the extracted file \(name) differs from the ZIP inventory.")
                }
                observed.insert(name)
            }
        }
        guard observed == Set(declared.keys) else { throw ScenePackageError.invalid("some archive members are missing.") }
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ScenePackageError.invalid("the system ZIP utility rejected the archive.")
        }
        return output
    }
}
