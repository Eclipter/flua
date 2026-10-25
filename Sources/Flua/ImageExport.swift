import Foundation

enum ImageExport {
    static func copy(source: URL, destination: URL?, savePanelAccepted: Bool) throws {
        guard savePanelAccepted, let destination else { return }
        let fm = FileManager.default
        let sourceAttributes = try fm.attributesOfItem(atPath: source.path)
        guard sourceAttributes[.type] as? FileAttributeType == .typeRegular else {
            throw CocoaError(.fileReadUnknown)
        }
        guard !refersToSameFile(source, destination, sourceAttributes: sourceAttributes) else {
            throw CocoaError(.fileWriteFileExists)
        }

        let destinationExists = fm.fileExists(atPath: destination.path)
        if destinationExists {
            let attributes = try fm.attributesOfItem(atPath: destination.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw CocoaError(.fileWriteFileExists)
            }
        }

        let filename = ".flua-image-" + UUID().uuidString
        let stagingName = source.pathExtension.isEmpty ? filename : filename + "." + source.pathExtension
        let staging = destination.deletingLastPathComponent().appendingPathComponent(stagingName)
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: source, to: staging)
        if destinationExists { _ = try fm.replaceItemAt(destination, withItemAt: staging) }
        else { try fm.moveItem(at: staging, to: destination) }
    }

    private static func refersToSameFile(_ source: URL, _ destination: URL,
                                         sourceAttributes: [FileAttributeKey: Any]) -> Bool {
        if source.standardizedFileURL.resolvingSymlinksInPath() == destination.standardizedFileURL.resolvingSymlinksInPath() {
            return true
        }
        guard let destinationAttributes = try? FileManager.default.attributesOfItem(atPath: destination.path),
              let sourceVolume = sourceAttributes[.systemNumber] as? NSNumber,
              let destinationVolume = destinationAttributes[.systemNumber] as? NSNumber,
              let sourceFile = sourceAttributes[.systemFileNumber] as? NSNumber,
              let destinationFile = destinationAttributes[.systemFileNumber] as? NSNumber else { return false }
        return sourceVolume == destinationVolume && sourceFile == destinationFile
    }
}
