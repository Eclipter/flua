import Foundation

private enum StubURLMode {
    case success
    case failure
    case redirect
    case trustedVimeoRedirect
    case pageRedirect
    case stall
}

private final class StubURLProtocol: URLProtocol {
    static var mode: StubURLMode = .success
    static var stopped = false
    static var pageHTML: String?
    static var statusCode: Int?
    static var contentLength: Int?
    static var requests: [URL] = []
    static var cachePolicies: [URLRequest.CachePolicy] = []
    static let responseData = Data("self-contained video bytes".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request.url!)
        Self.cachePolicies.append(request.cachePolicy)
        if request.url?.host == "cutestockfootage.com" {
            if Self.mode == .stall { return }
            if Self.mode == .pageRedirect {
                let target = URL(string: "https://untrusted.example/page")!
                let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil,
                                               headerFields: ["Location": target.absoluteString])!
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
                return
            }
            let status = Self.statusCode ?? (Self.mode == .failure ? 503 : 200)
            let body = Data((Self.pageHTML ?? "").utf8)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Length": String(Self.contentLength ?? body.count)])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if Self.mode != .failure { client?.urlProtocol(self, didLoad: body) }
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        switch Self.mode {
        case .stall:
            return
        case .redirect:
            let target = URL(string: "https://untrusted.example/video.mp4")!
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil,
                                           headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target),
                                redirectResponse: response)
        case .trustedVimeoRedirect where request.url?.host == "player.vimeo.com":
            let target = URL(string: "https://vod-progressive-ak.vimeocdn.com/video.mp4")!
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil,
                                           headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target),
                                redirectResponse: response)
        case .success, .failure, .trustedVimeoRedirect, .pageRedirect:
            let status = Self.statusCode ?? (Self.mode == .failure ? 503 : 200)
            let body = Self.responseData
            let length = Self.contentLength ?? body.count
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Length": String(length)])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if Self.mode == .success { client?.urlProtocol(self, didLoad: body) }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() { Self.stopped = true }
}

enum OnlineWallpaperItems {
    static let pageURL = URL(string: "https://cutestockfootage.com/stock-footage/11801/white-particles-slowly-falling-black-background/")!
    static let all = [
        OnlineWallpaper(
            id: "test-video", title: "Test video", sourceName: "Test source",
            sourceURL: URL(string: "https://source.example/item")!, creator: "Test creator",
            licenseName: "CC0", licenseURL: URL(string: "https://source.example/license")!,
            modificationNotice: nil, thumbnailURL: URL(string: "https://source.example/thumb.jpg")!,
            previewURL: URL(string: "https://source.example/preview.mp4")!,
            downloadRoute: .direct(URL(string: "https://download.example/video.mp4")!), fileExtension: "mp4"),
        OnlineWallpaper(
            id: "cute-stock-footage-test", title: "Test Cute video", sourceName: "Cute Stock Footage",
            sourceURL: pageURL, creator: "Test creator", licenseName: "CC BY 4.0",
            licenseURL: URL(string: "https://creativecommons.org/licenses/by/4.0/")!, modificationNotice: nil,
            thumbnailURL: URL(string: "https://source.example/thumb.jpg")!,
            previewURL: URL(string: "https://source.example/preview.mp4")!,
            downloadRoute: .cuteStockFootage(pageURL: pageURL, videoID: "501489629"), fileExtension: "mp4")
    ]
    static let unavailableSources: [UnavailableWallpaperSource] = []
}

@main struct OnlineDownloadTests {
    @MainActor
    static func main() async throws {
        precondition(HTTPByteContentRange.parse("bytes 0-255/4096") == HTTPByteContentRange(start: 0, end: 255, total: 4096))
        precondition(HTTPByteContentRange.parse("bytes 0-1/*") == nil)
        precondition(HTTPByteContentRange.parse("bytes 0-256/256") == nil)
        precondition(OnlineWallpaperPreviewMode.boundedRange(maximumBytes: 12_000_000, maximumDuration: 2).isValid)
        precondition(!OnlineWallpaperPreviewMode.boundedRange(maximumBytes: 50_000_000, maximumDuration: 2).isValid)
        let mergedPreviewSpans = OnlinePreviewByteSpan.merged([
            try OnlinePreviewByteSpan(start: 8, endExclusive: 20),
            try OnlinePreviewByteSpan(start: 0, endExclusive: 10)
        ])
        let expectedMergedPreviewSpans = [try OnlinePreviewByteSpan(start: 0, endExclusive: 20)]
        precondition(mergedPreviewSpans == expectedMergedPreviewSpans)
        let uncoveredPreviewSpans = try OnlinePreviewByteSpan.uncovered(
            [OnlinePreviewByteSpan(start: 0, endExclusive: 30)],
            by: [OnlinePreviewByteSpan(start: 0, endExclusive: 10),
                 OnlinePreviewByteSpan(start: 20, endExclusive: 30)])
        let expectedUncoveredPreviewSpans = [try OnlinePreviewByteSpan(start: 10, endExclusive: 20)]
        precondition(uncoveredPreviewSpans == expectedUncoveredPreviewSpans)
        do { _ = try OnlinePreviewByteSpan(start: 2, endExclusive: 2); fatalError("Accepted an empty byte span") }
        catch OnlineWallpaperError.previewUnavailable { }
        let item = OnlineWallpaperItems.all[0]
        try item.validate()
        let cuteItem = OnlineWallpaperItems.all[1]
        try cuteItem.validate()
        var cataloguedCute = cuteItem
        cataloguedCute.id = "cuteStockFootage:11801:white-particles-slowly-falling-black-background"
        cataloguedCute.thumbnailURL = URL(string: "https://cutestockfootage.com/thumb.jpg")!
        cataloguedCute.previewURL = URL(string: "https://cutestockfootage.com/preview.mp4")!
        precondition(cataloguedCute.catalogItemID == cuteItem.id)
        try cataloguedCute.validate()

        var coffeeClip = cuteItem
        coffeeClip.id = "cuteStockFootage:9592:brewing-coffee-beverage"
        coffeeClip.title = "Brewing Coffee Beverage"
        let coffeePage = URL(string: "https://cutestockfootage.com/brewing-coffee-beverage/")!
        coffeeClip.thumbnailURL = URL(string: "https://cutestockfootage.com/wp-content/uploads/2019/05/1037643185_1920x1080.jpg")!
        coffeeClip.previewURL = coffeeClip.thumbnailURL
        coffeeClip.sourceURL = coffeePage
        coffeeClip.downloadRoute = .cuteStockFootage(pageURL: coffeePage, videoID: "828476659")
        try coffeeClip.validate()

        var unsafeCuteClip = coffeeClip
        let traversalPage = URL(string: "https://cutestockfootage.com/%2e%2e/%2e%2e/wp-json/wp/v2/posts")!
        unsafeCuteClip.sourceURL = traversalPage
        unsafeCuteClip.downloadRoute = .cuteStockFootage(pageURL: traversalPage, videoID: "828476659")
        do { try unsafeCuteClip.validate(); fatalError("Accepted a non-clip Cute page") }
        catch OnlineWallpaperError.invalidCatalogItem { }

        var mismatchedCuteClip = coffeeClip
        mismatchedCuteClip.downloadRoute = .cuteStockFootage(pageURL: coffeePage, videoID: "828476659")
        mismatchedCuteClip.sourceURL = URL(string: "https://cutestockfootage.com/another-page/")!
        do { try mismatchedCuteClip.validate(); fatalError("Accepted a mismatched Cute source page") }
        catch OnlineWallpaperError.invalidCatalogItem { }

        let npsItem = OnlineWallpaper(
            id: "grandCanyonNPS:12345678-1234-1234-1234-123456789abc", title: "Canyon", sourceName: "Grand Canyon National Park",
            sourceURL: URL(string: "https://www.nps.gov/grca/learn/photosmultimedia/b-roll_hd01.htm")!, creator: "NPS",
            licenseName: "Public domain", licenseURL: URL(string: "https://www.nps.gov/grca/learn/photosmultimedia/b-roll_hd_index.htm")!,
            modificationNotice: nil, thumbnailURL: URL(string: "https://www.nps.gov/nps-audiovideo/thumbnail/test.jpg")!,
            previewURL: URL(string: "https://www.nps.gov/nps-audiovideo/audiovideo/test360p.mp4")!,
            downloadRoute: .direct(URL(string: "https://www.nps.gov/nps-audiovideo/audiovideo/test1080p.mp4")!), fileExtension: "mp4")
        try npsItem.validate()

        var unavailableItem = npsItem
        unavailableItem.downloadRoute = .unavailable("No native video rendition is available.")
        try unavailableItem.validate()

        var untrustedThumbnail = npsItem
        untrustedThumbnail.thumbnailURL = URL(string: "https://attacker.example/image.jpg")!
        do { try untrustedThumbnail.validate(); fatalError("Accepted a catalog thumbnail from an untrusted host") }
        catch OnlineWallpaperError.invalidCatalogItem { }

        var untrustedPreviewFile = npsItem
        untrustedPreviewFile.previewURL = URL(fileURLWithPath: "/tmp/private.mp4")
        do { try untrustedPreviewFile.validate(); fatalError("Accepted an arbitrary local preview path") }
        catch OnlineWallpaperError.invalidCatalogItem { }

        var unsafe = item
        unsafe.downloadRoute = .direct(URL(string: "http://download.example/video.mp4")!)
        do { try unsafe.validate(); fatalError("Accepted an insecure download URL") }
        catch OnlineWallpaperError.invalidCatalogItem { }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let successful = OnlineWallpaperDownload(configuration: configuration)
        StubURLProtocol.mode = .success
        StubURLProtocol.statusCode = nil
        StubURLProtocol.pageHTML = nil
        StubURLProtocol.contentLength = nil
        let file = try await successful.download(item) { _ in }
        let downloadedData = try Data(contentsOf: file)
        precondition(downloadedData == StubURLProtocol.responseData)
        precondition(file.pathExtension == "mp4")
        try FileManager.default.removeItem(at: file)

        StubURLProtocol.mode = .failure
        do {
            _ = try await OnlineWallpaperDownload(configuration: configuration).download(item) { _ in }
            fatalError("Accepted an HTTP error response")
        } catch OnlineWallpaperError.httpStatus(503) { }

        StubURLProtocol.mode = .redirect
        do {
            _ = try await OnlineWallpaperDownload(configuration: configuration).download(item) { _ in }
            fatalError("Followed an untrusted redirect")
        } catch OnlineWallpaperError.invalidPublishedDownload { }

        StubURLProtocol.mode = .stall
        StubURLProtocol.stopped = false
        let pending = Task { try await OnlineWallpaperDownload(configuration: configuration).download(item) { _ in } }
        try await Task.sleep(for: .milliseconds(50))
        pending.cancel()
        do { _ = try await pending.value; fatalError("A cancelled download completed") }
        catch is CancellationError { }
        catch let error as URLError { precondition(error.code == .cancelled) }
        precondition(StubURLProtocol.stopped, "Cancellation did not stop the active request")

        StubURLProtocol.mode = .success
        StubURLProtocol.pageHTML = #"<a class="mux-button" href="https://player.vimeo.com/progressive_redirect/download/501489629/clip.mp4?expires=1990000000&amp;signature=fresh-signature">Download Video</a>"#
        StubURLProtocol.requests = []
        StubURLProtocol.cachePolicies = []
        let resolvedFile = try await OnlineWallpaperDownload(configuration: configuration).download(cuteItem) { _ in }
        let resolvedBytes = try Data(contentsOf: resolvedFile)
        precondition(resolvedBytes == StubURLProtocol.responseData)
        precondition(StubURLProtocol.requests.count == 2)
        precondition(StubURLProtocol.requests[1].host == "player.vimeo.com")
        precondition(StubURLProtocol.requests[1].query?.contains("fresh-signature") == true)
        precondition(StubURLProtocol.cachePolicies.prefix(2).allSatisfy { $0 == .reloadIgnoringLocalCacheData })
        precondition(!cuteItem.attribution.sourceURL.contains("signature"))
        try FileManager.default.removeItem(at: resolvedFile)

        StubURLProtocol.mode = .trustedVimeoRedirect
        StubURLProtocol.pageHTML = #"<a href="https://player.vimeo.com/progressive_redirect/download/501489629/clip.mp4?expires=1990000000&amp;signature=second-signature">Download</a>"#
        StubURLProtocol.requests = []
        StubURLProtocol.cachePolicies = []
        let redirectedFile = try await OnlineWallpaperDownload(configuration: configuration).download(cuteItem) { _ in }
        precondition(StubURLProtocol.requests.compactMap(\.host) == ["cutestockfootage.com", "player.vimeo.com", "vod-progressive-ak.vimeocdn.com"])
        precondition(StubURLProtocol.requests[1].query?.contains("second-signature") == true)
        precondition(StubURLProtocol.cachePolicies.prefix(2).allSatisfy { $0 == .reloadIgnoringLocalCacheData })
        try FileManager.default.removeItem(at: redirectedFile)

        StubURLProtocol.mode = .success
        StubURLProtocol.pageHTML = #"<a href="https://player.vimeo.com/progressive_redirect/download/501489629/clip.mp4?expires=1990000000&amp;signature=fresh-signature">Download</a>"#
        StubURLProtocol.statusCode = 403
        do {
            _ = try await OnlineWallpaperDownload(configuration: configuration).download(cuteItem) { _ in }
            fatalError("Accepted an inaccessible source page")
        } catch OnlineWallpaperError.httpStatus(403) { }

        StubURLProtocol.statusCode = nil
        StubURLProtocol.pageHTML = #"<a href="https://attacker.example/progressive_redirect/download/501489629/clip.mp4?expires=1790000000&amp;signature=bad">Download</a>"#
        StubURLProtocol.requests = []
        do {
            _ = try await OnlineWallpaperDownload(configuration: configuration).download(cuteItem) { _ in }
            fatalError("Accepted an unsafe published media URL")
        } catch OnlineWallpaperError.missingPublishedDownload { }
        precondition(StubURLProtocol.requests.count == 1, "An invalid URL reached the media downloader")

        StubURLProtocol.pageHTML = #"<a href="https://player.vimeo.com/progressive_redirect/download/501489629/clip.mp4?expires=1990000000">Malformed link</a>"#
        StubURLProtocol.requests = []
        do {
            _ = try await OnlineWallpaperDownload(configuration: configuration).download(cuteItem) { _ in }
            fatalError("Accepted a published URL without its signature")
        } catch OnlineWallpaperError.invalidPublishedDownload { }
        precondition(StubURLProtocol.requests.count == 1, "A malformed published URL reached the media downloader")

        StubURLProtocol.pageHTML = #"<a href="https://player.vimeo.com/progressive_redirect/download/501489629/../../download/999/file.mp4?expires=1990000000&amp;signature=unsafe">Traversal link</a>"#
        StubURLProtocol.requests = []
        do {
            _ = try await OnlineWallpaperDownload(configuration: configuration).download(cuteItem) { _ in }
            fatalError("Accepted a published URL with path traversal")
        } catch OnlineWallpaperError.invalidPublishedDownload { }
        precondition(StubURLProtocol.requests.count == 1, "A path traversal URL reached the media downloader")

        StubURLProtocol.pageHTML = #"<a href="https://player.vimeo.com/progressive_redirect/download/501489629/%2e%2e%2f%2e%2e%2fdownload/999/file.mp4?expires=1990000000&amp;signature=encoded-unsafe">Encoded traversal link</a>"#
        StubURLProtocol.requests = []
        do {
            _ = try await OnlineWallpaperDownload(configuration: configuration).download(cuteItem) { _ in }
            fatalError("Accepted a published URL with encoded path traversal")
        } catch OnlineWallpaperError.invalidPublishedDownload { }
        precondition(StubURLProtocol.requests.count == 1, "An encoded path traversal URL reached the media downloader")

        StubURLProtocol.pageHTML = #"<a href="https://player.vimeo.com/progressive_redirect/download/501489629/clip.mp4?expires=1000000000&amp;signature=expired">Download</a>"#
        do {
            _ = try await OnlineWallpaperDownload(configuration: configuration).download(cuteItem) { _ in }
            fatalError("Accepted an expired published media URL")
        } catch OnlineWallpaperError.invalidPublishedDownload { }

        StubURLProtocol.mode = .pageRedirect
        StubURLProtocol.pageHTML = nil
        StubURLProtocol.requests = []
        do {
            _ = try await OnlineWallpaperDownload(configuration: configuration).download(cuteItem) { _ in }
            fatalError("Followed an untrusted source-page redirect")
        } catch OnlineWallpaperError.invalidPublishedDownload { }
        precondition(StubURLProtocol.requests.count == 1, "A source-page redirect escaped the expected host")

        StubURLProtocol.mode = .stall
        StubURLProtocol.stopped = false
        StubURLProtocol.requests = []
        let pendingResolution = Task {
            try await OnlineWallpaperDownload(configuration: configuration).download(cuteItem) { _ in }
        }
        for _ in 0..<100 {
            if !StubURLProtocol.requests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(StubURLProtocol.requests.count == 1, "Source-page lookup did not start")
        pendingResolution.cancel()
        do { _ = try await pendingResolution.value; fatalError("A cancelled link lookup completed") }
        catch is CancellationError { }
        catch let error as URLError { precondition(error.code == .cancelled) }
        precondition(StubURLProtocol.stopped, "Cancellation did not stop source-page lookup")

        StubURLProtocol.mode = .success
        StubURLProtocol.pageHTML = nil
        StubURLProtocol.contentLength = 2_000_001
        do {
            _ = try await OnlineWallpaperDownload(configuration: configuration).download(cuteItem) { _ in }
            fatalError("Accepted an oversized source page")
        } catch OnlineWallpaperError.sourcePageTooLarge { }
        StubURLProtocol.contentLength = nil
        print("PASS: catalog URL safety, download success, HTTP errors, redirect rejection, and cancellation")
    }
}
