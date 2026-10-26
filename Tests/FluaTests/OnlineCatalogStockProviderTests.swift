import Foundation

enum OnlineWallpaperItems {
    static let all: [OnlineWallpaper] = []
    static let unavailableSources: [UnavailableWallpaperSource] = []
}

@main struct OnlineCatalogStockProviderTests {
    static func main() throws {
        try testDarefulParsingAndPagination()
        try testISORepublicParsing()
        try testCuteStockFootageParsingAndPagination()
        print("PASS: stock provider item identity, license, preview/download routes, paging, search scoping, and restricted rows")
    }

    private static func testDarefulParsingAndPagination() throws {
        let listing = #"<article class="post-828 entry"><a href="https://dareful.com/flying-over-field/" title="Flying Over Field" class="grid-link"><span>Clip</span></a><img class="vimeo-thumbnail" src="https://dareful.com/thumb.jpg"></article><div class="pagination"><a href="https://dareful.com/page/3/">Next</a></div>"#
        let page = URL(string: "https://dareful.com/page/2/")!
        let rows = DarefulStockParser.rows(in: listing, page: page)
        precondition(rows.count == 1)
        precondition(rows[0].postID == "828")
        precondition(rows[0].title == "Flying Over Field")
        precondition(DarefulStockParser.nextPage(in: listing, current: page, query: "")?.path == "/page/3")

        let detail = #"<meta name="author" content="Editor"><meta itemprop="description" content="Aerial view of the Koolau mountains over the ocean."><a href="https://creativecommons.org/licenses/by/4.0/">CC BY 4.0</a><mux-player playback-id="WJsR2iTFl3IvigI00IdqLJbYQC2UjiD4IXC3got5ZIcs"></mux-player><a class="mux-button" data-file-name="flying-over-field.mp4" href="https://stream.mux.com/preview.m3u8"></a><meta itemprop="contentURL" content="https://stream.mux.com/WJsR2iTFl3IvigI00IdqLJbYQC2UjiD4IXC3got5ZIcs.m3u8">"#
        let item = try XCTUnwrap(DarefulStockParser.item(row: rows[0], html: detail))
        precondition(item.id == "dareful:828")
        precondition(item.creator == "Joel Holland")
        precondition(item.summary == "Aerial view of the Koolau mountains over the ocean.")
        precondition(item.previewURL.path.hasSuffix(".m3u8"))
        precondition(item.downloadRoute == .direct(URL(string: "https://stream.mux.com/WJsR2iTFl3IvigI00IdqLJbYQC2UjiD4IXC3got5ZIcs/high.mp4?download=flying-over-field.mp4")!))
        try item.validate()

        let injected = listing.replacingOccurrences(of: "https://dareful.com/page/3/", with: "https://evil.example/page/3/")
        precondition(DarefulStockParser.nextPage(in: injected, current: page, query: "") == nil)
        precondition(DarefulStockParser.nextPage(in: listing, current: page, query: "different") == nil)
        precondition(DarefulStockParser.rows(in: listing + #"<article class="post-999"><a class="grid-link" href="https://dareful.com/sponsored-clip/" title="Sponsored clip"></a><img class="vimeo-thumbnail" src="https://dareful.com/thumb.jpg"></article>"#, page: page).count == 1)
        var restrictedRow = rows[0]
        restrictedRow.title = "Sponsored clip"
        precondition(DarefulStockParser.item(row: restrictedRow, html: detail) == nil)
    }

    private static func testISORepublicParsing() throws {
        let record: [String: Any] = [
            "id": 21414,
            "slug": "underwater-sun-rays",
            "type": "video_post",
            "link": "https://isorepublic.com/video/underwater-sun-rays/",
            "title": ["rendered": "Underwater Sun Rays"],
            "_embedded": ["wp:featuredmedia": [[
                "source_url": "https://isorepublic.com/thumb.jpg",
                "media_details": ["sizes": ["medium": ["source_url": "https://isorepublic.com/thumb-533.jpg"]]]
            ]]]
        ]
        let row = try XCTUnwrap(ISORepublicStockParser.row(record))
        precondition(row.title == "Underwater Sun Rays")
        precondition(row.thumbnailURL?.absoluteString == "https://isorepublic.com/thumb-533.jpg")
        let detail = #"<meta itemprop="description" content="Rays of sunlight passing through clear ocean water."><script type="application/ld+json">{"@type":"Article","author":{"name":"Editor"}}</script><ul class="media-details"><a href="https://isorepublic.com/media-author/free-nature-stock" title="Free Nature Stock" class="media-author"><strong>Free Nature Stock</strong></a></ul><video><source src="https://isorepublic.com/wp-content/uploads/clip.mp4" type="video/mp4"></video><a href="https://isorepublic.com/wp-content/uploads/clip.mp4">Free Video Download</a><p>CC0. No attribution required.</p>"#
        let item = try XCTUnwrap(ISORepublicStockParser.item(row: row, html: detail))
        precondition(item.id == "isoRepublic:underwater-sun-rays")
        precondition(item.creator == "Free Nature Stock")
        precondition(item.summary == "Rays of sunlight passing through clear ocean water.")
        precondition(item.previewUnavailableReason == nil)
        precondition(item.previewURL == URL(string: "https://isorepublic.com/wp-content/uploads/clip.mp4")!)
        precondition(item.previewMode == .boundedRange(maximumBytes: 12_000_000, maximumDuration: 2))
        precondition(item.downloadRoute == .direct(URL(string: "https://isorepublic.com/wp-content/uploads/clip.mp4")!))
        try item.validate()
        let editorAuthoredDetail = detail.replacingOccurrences(of: #"<ul class="media-details"><a href="https://isorepublic.com/media-author/free-nature-stock" title="Free Nature Stock" class="media-author"><strong>Free Nature Stock</strong></a></ul>"#, with: "")
        let editorAuthoredItem = try XCTUnwrap(ISORepublicStockParser.item(row: row, html: editorAuthoredDetail))
        precondition(editorAuthoredItem.creator == "Creator not listed by ISO Republic")
        precondition(ISORepublicStockParser.item(row: row, html: detail.replacingOccurrences(of: "CC0", with: "Shutterstock")) == nil)
        precondition(ISORepublicStockParser.row(["id": 1, "slug": "bad", "type": "post", "link": "https://evil.example/video/bad/", "title": ["rendered": "Bad"]]) == nil)
    }

    private static func testCuteStockFootageParsingAndPagination() throws {
        let listing = #"<article><a href="https://cutestockfootage.com/stock-footage/10797/flight-over-small-town-near-forest-3/" id="link-501562231" title="Flight Over Small Town Near Forest 3" class="grid-link" data-vimeo="501562231"></a><div><img id="vimeo-thumbnail-501562231" class="vimeo-thumbnail" src="https://cutestockfootage.com/thumb.jpg" alt="Flight"></div></article><div class="pagination"><a href="https://cutestockfootage.com/page/3/"><span>Next&nbsp;</span></a></div>"#
        let page = URL(string: "https://cutestockfootage.com/page/2/")!
        let rows = CuteStockFootageParser.rows(in: listing, page: page)
        precondition(rows.count == 1)
        precondition(rows[0].itemID == "10797")
        precondition(rows[0].videoID == "501562231")
        precondition(CuteStockFootageParser.nextPage(in: listing, current: page, query: "")?.path == "/page/3")
        let item = CuteStockFootageParser.item(rows[0])
        precondition(item.id == "cuteStockFootage:10797:flight-over-small-town-near-forest-3")
        precondition(item.previewUnavailableReason == nil)
        precondition(item.previewMode == .boundedRange(maximumBytes: 12_000_000, maximumDuration: 2))
        precondition(item.downloadRoute == .cuteStockFootage(pageURL: rows[0].url, videoID: "501562231"))
        try item.validate()
        let queryURL = URL(string: "https://cutestockfootage.com/?s=forest")!
        precondition(CuteStockFootageParser.nextPage(in: listing, current: queryURL, query: "forest") == nil)
        let queryListing = listing.replacingOccurrences(of: "https://cutestockfootage.com/page/3/", with: "https://cutestockfootage.com/page/3/?s=forest")
        let queryNext = CuteStockFootageParser.nextPage(in: queryListing, current: queryURL, query: "forest")
        precondition(URLComponents(url: queryNext!, resolvingAgainstBaseURL: false)?.queryItems?.first == URLQueryItem(name: "s", value: "forest"))
        let forbidden = listing.replacingOccurrences(of: "cutestockfootage.com/page/3/", with: "evil.example/page/3/")
        precondition(CuteStockFootageParser.nextPage(in: forbidden, current: page, query: "") == nil)
        let sponsored = listing.replacingOccurrences(of: "Flight Over Small Town Near Forest 3", with: "Sponsored clip")
        precondition(CuteStockFootageParser.rows(in: sponsored, page: page).isEmpty)

        let rootPermalink = #"<a href="https://cutestockfootage.com/brewing-coffee-beverage/" id="link-828476659" title="Brewing Coffee Beverage" class="grid-link" data-vimeo="828476659"></a><img id="vimeo-thumbnail-828476659" class="vimeo-thumbnail" src="https://cutestockfootage.com/coffee.jpg">"#
        let rootRows = CuteStockFootageParser.rows(in: rootPermalink, page: URL(string: "https://cutestockfootage.com/?s=coffee")!)
        precondition(rootRows.count == 1)
        precondition(rootRows[0].itemID.isEmpty)
        precondition(rootRows[0].url.path == "/brewing-coffee-beverage")
        let postData = try JSONSerialization.data(withJSONObject: [[
            "id": 9592,
            "slug": "brewing-coffee-beverage",
            "type": "post",
            "link": "https://cutestockfootage.com/brewing-coffee-beverage/"
        ]])
        let mappedPostID = try CuteStockFootageParser.postID(in: postData, for: rootRows[0])
        let mismatchedPostID = try CuteStockFootageParser.postID(in: postData, for: rows[0])
        precondition(mappedPostID == "9592")
        precondition(mismatchedPostID == nil)
        var resolvedRootRow = rootRows[0]
        resolvedRootRow.itemID = "9592"
        let rootItem = CuteStockFootageParser.item(resolvedRootRow)
        precondition(rootItem.id == "cuteStockFootage:9592:brewing-coffee-beverage")
        precondition(rootItem.downloadRoute == .cuteStockFootage(pageURL: rootRows[0].url, videoID: "828476659"))
        try rootItem.validate()
        precondition(CatalogHTML.hasExplicitNoResults(in: "No flua-no-result-zzq998 Videos Found"))
        precondition(!CatalogHTML.hasExplicitNoResults(in: "A page with no video card markup"))
    }
}

private func XCTUnwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value else { fatalError("Expected non-nil value at \(file):\(line)") }
    return value
}
