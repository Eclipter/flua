import Foundation

@main struct OnlineCatalogPublicProviderTests {
    static func main() throws {
        try nasaSearchPaginationUsesOffsetAndNoSampleCap()
        try nasaPageKeepsOnlyPlayableUnrestrictedMovies()
        print("PASS: NASA search pagination, native renditions, and license filtering")
    }

    private static func nasaSearchPaginationUsesOffsetAndNoSampleCap() throws {
        let first = Data(#"{"count":5,"results":[{"id":101},{"id":102},{"id":103}]}"#.utf8)
        let second = Data(#"{"count":5,"results":[{"id":104},{"id":105}]}"#.utf8)
        let firstPage = try NASAOnlineCatalog.parseSearchResponse(first, offset: 0)
        let secondPage = try NASAOnlineCatalog.parseSearchResponse(second, offset: 3)
        precondition(firstPage.pageIDs == [101, 102, 103] && firstPage.nextCursor == "3")
        precondition(secondPage.pageIDs == [104, 105] && secondPage.nextCursor == nil)
        let malformed = Data(#"{"count":2,"results":[{}]}"#.utf8)
        let invalidSearch = try? NASAOnlineCatalog.parseSearchResponse(malformed, offset: 0)
        precondition(invalidSearch == nil)
    }

    private static func nasaPageKeepsOnlyPlayableUnrestrictedMovies() throws {
        let image: [String: Any] = ["media_type": "Image", "url": "http://svs.gsfc.nasa.gov/vis/thumb.jpg"]
        let allowed: [String: Any] = ["media_type": "Movie", "id": 44,
                                      "url": "http://svs.gsfc.nasa.gov/vis/clip.mp4", "width": 1920, "height": 1080,
                                      "alt_text": "Blue Earth"]
        let lowPreview: [String: Any] = ["media_type": "Movie", "id": 48,
                                         "url": "http://svs.gsfc.nasa.gov/vis/clip-640.mp4", "width": 640, "height": 360]
        let webmOnly: [String: Any] = ["media_type": "Movie", "id": 45,
                                       "url": "https://svs.gsfc.nasa.gov/vis/clip.webm"]
        let page: [String: Any] = [
            "title": "Earth view", "description": "NASA page description",
            "related_pages": [["title": "Music in an unrelated dataset"]],
            "main_image": ["url": "http://svs.gsfc.nasa.gov/vis/thumb.jpg"],
            "main_credits": ["Visualizations by": [["name": "Ada Lovelace", "employer": "NASA/GSFC"]]],
            "media_groups": [
                ["id": 55, "description": "Ocean temperature animation", "items": [["instance": image], ["instance": allowed], ["media": lowPreview], ["instance": webmOnly]]],
                ["id": 56, "description": "Music credits: licensed music by a third party", "items": [["instance": allowed]]],
                ["id": 57, "description": "Older WebM-only movie", "items": [["media": webmOnly]]]
            ]
        ]
        let items = NASAOnlineCatalog.parsePage(page, pageID: 234)
        precondition(items.count == 3)
        precondition(items[0].id == "nasaSVS:234:55")
        precondition(items[0].summary == "Ocean temperature animation")
        precondition(items[0].downloadRoute == .direct(URL(string: "https://svs.gsfc.nasa.gov/vis/clip.mp4")!))
        precondition(items[0].creator.contains("Ada Lovelace"))
        precondition(items[0].previewURL == URL(string: "https://svs.gsfc.nasa.gov/vis/clip-640.mp4")!)
        precondition(items[0].previewMode == .boundedRange(maximumBytes: 12_000_000, maximumDuration: 2))
        precondition(items[0].previewUnavailableReason == nil)
        precondition(items[1].id == "nasaSVS:234:56")
        precondition(items[1].downloadRoute == .unavailable("This visualization includes separately licensed audio and cannot be downloaded here."))
        precondition(items[2].id == "nasaSVS:234:57")
        precondition(items[2].downloadRoute == .unavailable("NASA SVS does not provide a native MP4 or QuickTime rendition for this clip."))

        let highOnlyPage: [String: Any] = [
            "title": "High resolution only",
            "main_image": ["url": "https://svs.gsfc.nasa.gov/vis/thumb.jpg"],
            "media_groups": [["id": 70, "title": "Earth", "items": [["media_type": "Movie", "id": 71,
                "url": "https://svs.gsfc.nasa.gov/vis/large.mp4", "width": 3840, "height": 2160]]]]
        ]
        guard let highOnly = NASAOnlineCatalog.parsePage(highOnlyPage, pageID: 235).first else {
            fatalError("A native NASA video without a low-resolution alternate should remain previewable")
        }
        precondition(highOnly.previewURL == URL(string: "https://svs.gsfc.nasa.gov/vis/large.mp4")!)
        precondition(highOnly.previewMode == .boundedRange(maximumBytes: 12_000_000, maximumDuration: 2))
        precondition(highOnly.previewUnavailableReason == nil)

        let publicDomainMusicPage: [String: Any] = [
            "title": "Public-domain music animation",
            "main_image": ["url": "https://svs.gsfc.nasa.gov/vis/thumb.jpg"],
            "media_groups": [["id": 72, "title": "Original public-domain music performance", "items": [allowed]]]
        ]
        let publicDomainMusic = NASAOnlineCatalog.parsePage(publicDomainMusicPage, pageID: 236).first
        precondition(publicDomainMusic?.downloadRoute == .direct(URL(string: "https://svs.gsfc.nasa.gov/vis/clip.mp4")!))

        var restricted = page
        restricted["description"] = "Music licensed separately; video is public domain without audio."
        let restrictedItems = NASAOnlineCatalog.parsePage(restricted, pageID: 234)
        precondition(restrictedItems.count == 3)
        precondition(restrictedItems.allSatisfy { if case .unavailable = $0.downloadRoute { return true }; return false })
        let untrusted: [String: Any] = ["title": "bad", "media_groups": [["items": [["instance": [
            "media_type": "Movie", "id": 4, "url": "https://example.com/clip.mp4"
        ]]]]]]
        precondition(NASAOnlineCatalog.parsePage(untrusted, pageID: 4).isEmpty)
    }

}
