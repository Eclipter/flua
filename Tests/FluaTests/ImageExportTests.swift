import Foundation

@main struct ImageExportTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FluaImageExportTests-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }

        let source = root.appendingPathComponent("source.png")
        let sourceBytes = Data("original image bytes".utf8)
        try sourceBytes.write(to: source)

        let existing = root.appendingPathComponent("existing.png")
        let existingBytes = Data("old destination".utf8)
        try existingBytes.write(to: existing)
        try ImageExport.copy(source: source, destination: existing, savePanelAccepted: false)
        let cancelledDestinationBytes = try Data(contentsOf: existing)
        precondition(cancelledDestinationBytes == existingBytes)
        let sourceAfterCancellation = try Data(contentsOf: source)
        precondition(sourceAfterCancellation == sourceBytes)

        try ImageExport.copy(source: source, destination: existing, savePanelAccepted: true)
        let replacedDestinationBytes = try Data(contentsOf: existing)
        precondition(replacedDestinationBytes == sourceBytes)
        let sourceAfterReplacement = try Data(contentsOf: source)
        precondition(sourceAfterReplacement == sourceBytes)

        let newDestination = root.appendingPathComponent("new.png")
        try ImageExport.copy(source: source, destination: newDestination, savePanelAccepted: true)
        let newDestinationBytes = try Data(contentsOf: newDestination)
        precondition(newDestinationBytes == sourceBytes)

        for (name, alias) in [("same-path", source), ("symlink", root.appendingPathComponent("source-link.png")),
                              ("hardlink", root.appendingPathComponent("source-hardlink.png"))] {
            if name == "symlink" { try fm.createSymbolicLink(at: alias, withDestinationURL: source) }
            if name == "hardlink" { try fm.linkItem(at: source, to: alias) }
            do {
                try ImageExport.copy(source: source, destination: alias, savePanelAccepted: true)
                fatalError("Replaced the source through \(name)")
            } catch let error as CocoaError {
                precondition(error.code == .fileWriteFileExists)
            }
            let preservedSourceBytes = try Data(contentsOf: source)
            precondition(preservedSourceBytes == sourceBytes)
        }

        let items = try fm.contentsOfDirectory(atPath: root.path)
        precondition(!items.contains(where: { $0.hasPrefix(".flua-image-") }))
        print("PASS: image export preserves sources, stages and replaces only after save-panel approval, ignores cancellation, and rejects source path, symlink and hard-link destinations")
    }
}
