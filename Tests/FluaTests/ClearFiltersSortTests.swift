import Foundation

// Standalone `swiftc` executables do not synthesize `Bundle.module`; provide a
// test-only stand-in so the rendering types Library.swift references can
// type-check. This stand-in is never exercised by the test below (no scene
// thumbnail is generated while clearing filters).
extension Bundle {
    static var module: Bundle { Bundle.main }
}

@main struct ClearFiltersSortTests {
    static func main() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FluaClearFiltersSortTest-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let support = dir.appendingPathComponent("ApplicationSupport", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let root = LibraryPaths.resolve(applicationSupport: support)

        let library = try Library(root: root, systemPlaybackEnabled: false)
        library.browseSort = "recent"
        library.filter.tags = ["nature"]
        library.query = "something"
        library.clearFilters()
        precondition(library.browseSort == "name")
        precondition(library.filter.activeCount == 0)
        precondition(library.query.isEmpty)
        for sort in ["favorites", "recent"] {
            library.browseSort = sort
            library.clearFilters()
            precondition(library.browseSort == "name", "clearFilters did not reset \(sort) sort to name; got \(library.browseSort)")
            precondition(library.filter.activeCount == 0, "clearFilters did not reset filter after \(sort)")
            precondition(library.query == "", "clearFilters did not reset query after \(sort)")
        }
        print("PASS: clearFilters resets filters, query, and sort type to default (name) with only sorting changed (favorites/recent)")
    }
}
