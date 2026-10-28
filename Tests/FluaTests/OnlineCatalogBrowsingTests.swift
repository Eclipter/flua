import Foundation

enum OnlineWallpaperItems {
    static let all: [OnlineWallpaper] = []
}

private actor FixtureCatalogLoader: OnlineCatalogPageLoading {
    private(set) var requests: [OnlineCatalogPageRequest] = []
    private var failFirstNASARequest = true

    func load(_ request: OnlineCatalogPageRequest) async throws -> OnlineCatalogPage {
        requests.append(request)
        if request.query == "empty-page", request.cursor == nil {
            return OnlineCatalogPage(items: [], nextCursor: "page-2")
        }
        if request.query == "obsolete" { try await Task.sleep(for: .seconds(2)) }
        if request.query == "mixed", request.source == .nasaSVS { try await Task.sleep(for: .milliseconds(250)) }
        if request.source == .nasaSVS, request.query == "forest", request.cursor == nil,
           failFirstNASARequest {
            failFirstNASARequest = false
            throw URLError(.badServerResponse)
        }

        let pageNumber = request.cursor == nil ? 1 : 2
        let itemNumber = pageNumber == 1 ? 1 : 2
        let items = [wallpaper(id: "\(request.source.rawValue)-\(itemNumber)", source: request.source)]
        return OnlineCatalogPage(items: items, nextCursor: pageNumber == 1 ? "page-2" : nil)
    }

    private func wallpaper(id: String, source: OnlineWallpaperSource) -> OnlineWallpaper {
        OnlineWallpaper(
            id: id,
            title: id,
            sourceName: source.title,
            sourceURL: URL(string: "https://example.com/item/\(id)")!,
            creator: "Fixture creator",
            licenseName: "CC0",
            licenseURL: URL(string: "https://example.com/license")!,
            modificationNotice: nil,
            thumbnailURL: URL(string: "https://example.com/thumb.jpg")!,
            previewURL: URL(string: "https://example.com/preview.mp4")!,
            downloadRoute: .direct(URL(string: "https://example.com/video.mp4")!),
            fileExtension: "mp4"
        )
    }
}

@main struct OnlineCatalogBrowsingTests {
    @MainActor
    static func main() async throws {
        let loader = FixtureCatalogLoader()
        let browser = OnlineCatalogBrowser(loader: loader)
        browser.search(query: "forest", filter: .all)
        try await waitForSearch(browser)

        precondition(browser.items.count == OnlineWallpaperSource.allCases.count - 1)
        precondition(browser.errors[.nasaSVS] != nil)
        precondition(browser.hasMore)

        browser.retry(.nasaSVS)
        try await waitForSearch(browser)
        precondition(browser.items.count == OnlineWallpaperSource.allCases.count)
        precondition(browser.errors.isEmpty)

        browser.loadMore()
        try await waitForSearch(browser)
        precondition(browser.items.count == OnlineWallpaperSource.allCases.count * 2)
        precondition(!browser.hasMore)

        browser.search(query: "obsolete", filter: .all)
        try await Task.sleep(for: .milliseconds(30))
        browser.search(query: "current", filter: .source(.dareful))
        try await waitForSearch(browser)
        precondition(browser.query == "current")
        precondition(browser.items.map(\.id) == ["dareful-1"])
        precondition(browser.items.allSatisfy { $0.sourceName == OnlineWallpaperSource.dareful.title })

        browser.search(query: "empty-page", filter: .source(.dareful))
        try await waitForSearch(browser)
        precondition(browser.items.isEmpty && browser.hasMore)
        browser.loadMore()
        try await waitForSearch(browser)
        precondition(browser.items.map(\.id) == ["dareful-2"] && !browser.hasMore)

        browser.search(query: "mixed", filter: .all)
        try await Task.sleep(for: .milliseconds(50))
        precondition(browser.items.contains { $0.id == "dareful-1" })
        precondition(browser.loadingSources.contains(.nasaSVS))
        try await waitForSearch(browser)
        browser.search(query: "obsolete", filter: .all)
        try await Task.sleep(for: .milliseconds(30))
        browser.cancel()
        precondition(browser.wasCancelled && browser.hasCompletedSearch && !browser.isLoading)
        precondition(browser.errors.count == OnlineWallpaperSource.allCases.count)
        precondition(browser.errors.values.allSatisfy { $0.contains("Search canceled") })

        let npsMarkup = """
        <div class="VideoHero" itemscope itemtype="http://schema.org/VideoObject">
        <meta itemprop="name" content="Test Canyon &amp; Valley" />
        <meta itemprop="description" content="A canyon &#x26; sunset." />
        <meta itemprop="thumbnailUrl" content="https://www.nps.gov/nps-audiovideo/thumbnail/12345678-1234-1234-1234-123456789abc.jpg" />
        <video><source src="https://www.nps.gov/nps-audiovideo/audiovideo/12345678-1234-1234-1234-123456789abc360p.mp4" type="video/mp4" res="360" /><source src="https://www.nps.gov/nps-audiovideo/audiovideo/12345678-1234-1234-1234-123456789abc1080p.mp4" type="video/mp4" res="1080" /></video>
        </div>
        """
        let pageURL = URL(string: "https://www.nps.gov/grca/learn/photosmultimedia/b-roll_hd01.htm")!
        let npsItems = NPSOnlineParser.items(in: npsMarkup, page: pageURL, source: .grandCanyonNPS)
        precondition(npsItems.count == 1)
        precondition(npsItems[0].title == "Test Canyon & Valley")
        precondition(npsItems[0].summary == "A canyon & sunset.")
        precondition(npsItems[0].id == "grandCanyonNPS:12345678-1234-1234-1234-123456789abc")
        precondition(npsItems[0].previewURL.lastPathComponent.hasSuffix("360p.mp4"))
        precondition(npsItems[0].previewMode == .boundedRange(maximumBytes: 12_000_000, maximumDuration: 2))
        precondition(npsItems[0].downloadRoute == .direct(URL(string: "https://www.nps.gov/nps-audiovideo/audiovideo/12345678-1234-1234-1234-123456789abc1080p.mp4")!))
        let joshuaIndex = #"<a href="/jotr/learn/photosmultimedia/sunclips.htm">Sun</a><script>window.location.href = "/jotr/learn/photosmultimedia/snow-clips.htm";</script>"#
        let joshuaPages = NPSOnlineParser.archivePages(in: joshuaIndex, source: .joshuaTreeNPS)
        precondition(joshuaPages.map(\.lastPathComponent) == ["snow-clips.htm", "sunclips.htm"])

        print("PASS: source paging, deduplication, partial errors, retry, incremental results, query cancellation, and NPS clip parsing")
    }

    @MainActor
    private static func waitForSearch(_ browser: OnlineCatalogBrowser) async throws {
        for _ in 0..<300 {
            if !browser.isLoading { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Catalog search did not finish")
    }
}
