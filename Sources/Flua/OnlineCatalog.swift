import Foundation

enum OnlineWallpaperSource: String, CaseIterable, Hashable, Identifiable, Sendable {
    case dareful
    case isoRepublic
    case cuteStockFootage
    case nasaSVS
    case grandCanyonNPS
    case joshuaTreeNPS

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dareful: return "Dareful"
        case .isoRepublic: return "ISO Republic"
        case .cuteStockFootage: return "Cute Stock Footage"
        case .nasaSVS: return "NASA SVS"
        case .grandCanyonNPS: return "Grand Canyon National Park"
        case .joshuaTreeNPS: return "Joshua Tree National Park"
        }
    }
}

enum OnlineWallpaperPreviewMode: Equatable, Sendable {
    case direct
    case boundedRange(maximumBytes: Int64, maximumDuration: Double)

    var isValid: Bool {
        switch self {
        case .direct: return true
        case .boundedRange(let maximumBytes, let maximumDuration):
            return (1024 * 1024...12_000_000).contains(maximumBytes)
                && (0.25...5).contains(maximumDuration)
        }
    }
}

struct OnlineWallpaper: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var summary: String? = nil
    var sourceName: String
    var sourceURL: URL
    var creator: String
    var licenseName: String
    var licenseURL: URL
    var modificationNotice: String?
    var thumbnailURL: URL
    var previewURL: URL
    var previewMode: OnlineWallpaperPreviewMode = .direct
    var previewUnavailableReason: String? = nil
    var downloadRoute: OnlineWallpaperDownloadRoute
    var fileExtension: String

    var catalogItemID: String {
        OnlineCatalog.items.first {
            $0.sourceURL == sourceURL && ($0.title == title || $0.downloadRoute == downloadRoute)
        }?.id ?? id
    }

    var attribution: WallpaperSourceAttribution {
        WallpaperSourceAttribution(catalogItemID: catalogItemID, sourceName: sourceName,
                                   sourceURL: sourceURL.absoluteString, creator: creator,
                                   licenseName: licenseName, licenseURL: licenseURL.absoluteString,
                                   modificationNotice: modificationNotice)
    }

    func validate() throws {
        let provider = OnlineWallpaperSource.allCases.first { $0.title == sourceName }
        let legacyBundledItem = OnlineCatalog.items.contains(self)
        guard !id.isEmpty, !title.isEmpty, !sourceName.isEmpty, !creator.isEmpty,
              !licenseName.isEmpty,
              previewMode.isValid,
              ["mp4", "mov", "m4v"].contains(fileExtension.lowercased()),
              [sourceURL, licenseURL, thumbnailURL].allSatisfy(Self.isHTTPS),
              downloadRoute.isValid,
              (legacyBundledItem || (provider.map { validatesOrigin($0) } ?? false)),
              (Self.isHTTPS(previewURL) || (legacyBundledItem && previewURL.isFileURL && previewURL.pathExtension.lowercased() == "mp4")) else {
            throw OnlineWallpaperError.invalidCatalogItem
        }
    }

    private func validatesOrigin(_ provider: OnlineWallpaperSource) -> Bool {
        guard id.hasPrefix(provider.rawValue + ":"),
              let sourceHost = sourceURL.host?.lowercased(),
              let thumbnailHost = thumbnailURL.host?.lowercased(),
              let licenseHost = licenseURL.host?.lowercased() else { return false }
        let expectedSourceHosts: Set<String>
        let expectedDownloadHosts: Set<String>
        let expectedThumbnailHosts: Set<String>
        let expectedPathPrefix: String
        switch provider {
        case .dareful:
            expectedSourceHosts = ["dareful.com", "www.dareful.com"]
            expectedDownloadHosts = ["stream.mux.com"]
            expectedThumbnailHosts = ["dareful.com", "www.dareful.com"]
            expectedPathPrefix = "/"
        case .isoRepublic:
            expectedSourceHosts = ["isorepublic.com", "www.isorepublic.com"]
            expectedDownloadHosts = ["isorepublic.com", "www.isorepublic.com"]
            expectedThumbnailHosts = ["isorepublic.com", "www.isorepublic.com"]
            expectedPathPrefix = "/video/"
        case .cuteStockFootage:
            expectedSourceHosts = ["cutestockfootage.com", "www.cutestockfootage.com"]
            expectedDownloadHosts = ["player.vimeo.com", "vod-progressive-ak.vimeocdn.com"]
            expectedThumbnailHosts = ["cutestockfootage.com", "www.cutestockfootage.com"]
            expectedPathPrefix = "/stock-footage/"
        case .nasaSVS:
            expectedSourceHosts = ["svs.gsfc.nasa.gov"]
            expectedDownloadHosts = ["svs.gsfc.nasa.gov"]
            expectedThumbnailHosts = ["svs.gsfc.nasa.gov"]
            expectedPathPrefix = "/"
        case .grandCanyonNPS:
            expectedSourceHosts = ["nps.gov", "www.nps.gov"]
            expectedDownloadHosts = ["nps.gov", "www.nps.gov"]
            expectedThumbnailHosts = ["nps.gov", "www.nps.gov"]
            expectedPathPrefix = "/grca/"
        case .joshuaTreeNPS:
            expectedSourceHosts = ["nps.gov", "www.nps.gov"]
            expectedDownloadHosts = ["nps.gov", "www.nps.gov"]
            expectedThumbnailHosts = ["nps.gov", "www.nps.gov"]
            expectedPathPrefix = "/jotr/"
        }
        let allowedLicenseHosts: Set<String> = [
            "creativecommons.org", "dareful.com", "www.dareful.com", "isorepublic.com",
            "www.isorepublic.com", "cutestockfootage.com", "www.cutestockfootage.com",
            "svs.gsfc.nasa.gov", "nasa.gov", "www.nasa.gov",
            "nps.gov", "www.nps.gov"
        ]
        guard expectedSourceHosts.contains(sourceHost),
              (provider == .cuteStockFootage
                ? Self.isCuteClipPage(sourceURL)
                : sourceURL.path.hasPrefix(expectedPathPrefix)),
              expectedThumbnailHosts.contains(thumbnailHost),
              allowedLicenseHosts.contains(licenseHost) else { return false }
        if provider == .nasaSVS && sourceURL.path.split(separator: "/").last?.allSatisfy(\.isNumber) != true {
            return false
        }
        if Self.isHTTPS(previewURL), let host = previewURL.host?.lowercased(),
           host != thumbnailHost,
           !expectedSourceHosts.contains(host),
           !expectedDownloadHosts.contains(host) {
            return false
        }
        switch downloadRoute {
        case .direct(let url):
            return expectedDownloadHosts.contains(url.host?.lowercased() ?? "")
        case .cuteStockFootage(let pageURL, let videoID):
            return provider == .cuteStockFootage
                && expectedSourceHosts.contains(pageURL.host?.lowercased() ?? "")
                && pageURL == sourceURL
                && Self.isCuteClipPage(pageURL)
                && Self.isCuteClipIdentity(id, pageURL: pageURL)
                && videoID.allSatisfy(\.isNumber)
                && !videoID.isEmpty
        case .unavailable:
            return true
        }
    }

    fileprivate static func isHTTPS(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme?.lowercased() == "https"
            && components.host != nil
            && components.user == nil
            && components.password == nil
    }

    fileprivate static func isCuteClipPage(_ url: URL) -> Bool {
        guard isHTTPS(url),
              ["cutestockfootage.com", "www.cutestockfootage.com"].contains(url.host?.lowercased() ?? ""),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let decodedPath = components.percentEncodedPath.removingPercentEncoding else { return false }
        let parts = decodedPath.split(separator: "/").map(String.init)
        guard !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") }),
              parts.allSatisfy({ $0.range(of: #"^[A-Za-z0-9-]+$"#, options: .regularExpression) != nil }) else { return false }
        if parts.first == "stock-footage" {
            return parts.count == 3 && parts[1].allSatisfy(\.isNumber)
        }
        return parts.count == 1
    }

    fileprivate static func isCuteClipIdentity(_ id: String, pageURL: URL) -> Bool {
        let identity = id.split(separator: ":")
        guard identity.count == 3, identity[0] == "cuteStockFootage",
              identity[1].allSatisfy(\.isNumber),
              let components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false),
              let decodedPath = components.percentEncodedPath.removingPercentEncoding else { return false }
        let path = decodedPath.split(separator: "/").map(String.init)
        guard let slug = path.last, slug == identity[2] else { return false }
        if path.first == "stock-footage" { return path.count == 3 && path[1] == identity[1] }
        return path.count == 1
    }
}

enum OnlineWallpaperDownloadRoute: Equatable, Sendable {
    case direct(URL)
    case cuteStockFootage(pageURL: URL, videoID: String)
    case unavailable(String)

    var allowedRedirectHosts: Set<String> {
        switch self {
        case .direct(let url): return [url.host?.lowercased() ?? ""]
        case .cuteStockFootage: return ["player.vimeo.com", "vod-progressive-ak.vimeocdn.com"]
        case .unavailable: return []
        }
    }

    var isValid: Bool {
        switch self {
        case .direct(let url): return OnlineWallpaper.isHTTPS(url)
        case .cuteStockFootage(let pageURL, let videoID):
            return OnlineWallpaper.isHTTPS(pageURL)
                && ["cutestockfootage.com", "www.cutestockfootage.com"].contains(pageURL.host?.lowercased() ?? "")
                && OnlineWallpaper.isCuteClipPage(pageURL)
                && videoID.allSatisfy(\.isNumber)
                && !videoID.isEmpty
        case .unavailable(let reason): return !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

struct UnavailableWallpaperSource: Identifiable, Equatable, Sendable {
    var id: String
    var sourceURL: URL
    var reason: String
}

enum OnlineCatalog {
    static let items = OnlineWallpaperItems.all
    static let unavailableSources = OnlineWallpaperItems.unavailableSources

    static func item(id: String) -> OnlineWallpaper? {
        items.first { $0.id == id }
    }
}

enum OnlineWallpaperError: LocalizedError {
    case invalidCatalogItem
    case httpStatus(Int)
    case missingDownload
    case downloadTooLarge
    case sourcePageTooLarge
    case missingPublishedDownload
    case invalidPublishedDownload
    case duplicate
    case previewUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidCatalogItem: return "This wallpaper catalog entry is invalid."
        case .httpStatus(let status): return "The wallpaper source returned HTTP status \(status)."
        case .missingDownload: return "The wallpaper download did not produce a file."
        case .downloadTooLarge: return "The wallpaper download is larger than the supported 1 GB limit."
        case .sourcePageTooLarge: return "The wallpaper source page is larger than the supported limit."
        case .missingPublishedDownload: return "The source page did not publish a downloadable video link."
        case .invalidPublishedDownload: return "The source page published an invalid download link."
        case .duplicate: return "This wallpaper is already in your library."
        case .previewUnavailable: return "This source does not provide a compatible lightweight video preview."
        }
    }
}

@MainActor
final class BoundedHTTPSDataRequest: NSObject, @preconcurrency URLSessionDataDelegate {
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var data = Data()
    private let maximumBytes: Int
    private let allowedHosts: Set<String>
    private let byteRange: ClosedRange<Int64>?
    private let onDataReceived: (@MainActor (Data) -> Void)?

    init(maximumBytes: Int, sourceHost: String, byteRange: ClosedRange<Int64>? = nil,
         onDataReceived: (@MainActor (Data) -> Void)? = nil) {
        self.maximumBytes = maximumBytes
        self.allowedHosts = [sourceHost.lowercased()]
        self.byteRange = byteRange
        self.onDataReceived = onDataReceived
    }

    init(maximumBytes: Int, allowedHosts: Set<String>, byteRange: ClosedRange<Int64>? = nil,
         onDataReceived: (@MainActor (Data) -> Void)? = nil) {
        self.maximumBytes = maximumBytes
        self.allowedHosts = Set(allowedHosts.map { $0.lowercased() })
        self.byteRange = byteRange
        self.onDataReceived = onDataReceived
    }

    func fetch(_ url: URL, configuration: URLSessionConfiguration) async throws -> Data {
        try await fetchResponse(url, configuration: configuration).0
    }

    func fetchResponse(_ url: URL, configuration: URLSessionConfiguration) async throws -> (Data, HTTPURLResponse) {
        guard !Task.isCancelled else { throw CancellationError() }
        guard isTrustedHTTPS(url), allowedHosts.contains(url.host?.lowercased() ?? "") else {
            throw byteRange == nil
                ? OnlineWallpaperError.invalidPublishedDownload
                : OnlineWallpaperError.previewUnavailable
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                configuration.timeoutIntervalForRequest = 30
                configuration.timeoutIntervalForResource = 60
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
                self.session = session
                var request = URLRequest(url: url)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.setValue("Flua/OnlineCatalog (+https://github.com/Eclipter/flua)", forHTTPHeaderField: "User-Agent")
                if let byteRange {
                    request.setValue("bytes=\(byteRange.lowerBound)-\(byteRange.upperBound)", forHTTPHeaderField: "Range")
                }
                let task = session.dataTask(with: request)
                self.task = task
                task.resume()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard isTrustedHTTPS(request.url), allowedHosts.contains(request.url?.host?.lowercased() ?? "") else {
            completionHandler(nil)
            finish(.failure(byteRange == nil
                ? OnlineWallpaperError.invalidPublishedDownload
                : OnlineWallpaperError.previewUnavailable))
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse,
              isTrustedHTTPS(response.url), allowedHosts.contains(response.url?.host?.lowercased() ?? "") else {
            completionHandler(.cancel)
            finish(.failure(byteRange == nil
                ? OnlineWallpaperError.invalidPublishedDownload
                : OnlineWallpaperError.previewUnavailable))
            return
        }
        guard response.expectedContentLength < 0 || response.expectedContentLength <= Int64(maximumBytes) else {
            completionHandler(.cancel)
            finish(.failure(byteRange == nil
                ? OnlineWallpaperError.sourcePageTooLarge
                : OnlineWallpaperError.previewUnavailable))
            return
        }
        if let byteRange {
            let expectedLength = byteRange.upperBound - byteRange.lowerBound + 1
            guard response.statusCode == 206,
                  let contentRange = HTTPByteContentRange.parse(response.value(forHTTPHeaderField: "Content-Range")),
                  contentRange.start == byteRange.lowerBound,
                  contentRange.end == byteRange.upperBound,
                  contentRange.total > contentRange.end,
                  response.expectedContentLength < 0 || response.expectedContentLength == expectedLength else {
                completionHandler(.cancel)
                finish(.failure(OnlineWallpaperError.previewUnavailable))
                return
            }
        }
        self.response = response
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard self.data.count <= maximumBytes - data.count else {
            dataTask.cancel()
            finish(.failure(byteRange == nil
                ? OnlineWallpaperError.sourcePageTooLarge
                : OnlineWallpaperError.previewUnavailable))
            return
        }
        self.data.append(data)
        onDataReceived?(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        guard let response else { finish(.failure(OnlineWallpaperError.missingPublishedDownload)); return }
        guard (200..<300).contains(response.statusCode) else {
            finish(.failure(OnlineWallpaperError.httpStatus(response.statusCode)))
            return
        }
        if let byteRange, Int64(data.count) != byteRange.upperBound - byteRange.lowerBound + 1 {
            finish(.failure(OnlineWallpaperError.previewUnavailable))
            return
        }
        finish(.success((data, response)))
    }

    private func isTrustedHTTPS(_ url: URL?) -> Bool {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme?.lowercased() == "https" && components.host != nil
            && components.user == nil && components.password == nil
    }

    private func finish(_ result: Result<(Data, HTTPURLResponse), Error>) {
        guard let continuation else { return }
        self.continuation = nil
        task = nil
        session?.invalidateAndCancel()
        session = nil
        continuation.resume(with: result)
    }

    private func cancel() {
        task?.cancel()
        finish(.failure(CancellationError()))
    }
}

struct HTTPByteContentRange: Equatable, Sendable {
    var start: Int64
    var end: Int64
    var total: Int64

    static func parse(_ value: String?) -> HTTPByteContentRange? {
        guard let value,
              let match = value.range(of: #"^bytes (0|[1-9][0-9]*)-(0|[1-9][0-9]*)/(0|[1-9][0-9]*)$"#,
                                      options: .regularExpression) else { return nil }
        let fields = value[match].dropFirst("bytes ".count).split { $0 == "-" || $0 == "/" }
        guard fields.count == 3,
              let start = Int64(fields[0]),
              let end = Int64(fields[1]),
              let total = Int64(fields[2]),
              start <= end, end < total else { return nil }
        return HTTPByteContentRange(start: start, end: end, total: total)
    }
}

@MainActor
enum OnlineWallpaperDownloadURLResolver {
    static func resolve(_ route: OnlineWallpaperDownloadRoute,
                        configuration: URLSessionConfiguration) async throws -> URL {
        switch route {
        case .direct(let url): return url
        case .cuteStockFootage(let pageURL, let videoID):
            let html = try await BoundedHTTPSDataRequest(maximumBytes: 2_000_000,
                                                         allowedHosts: ["cutestockfootage.com", "www.cutestockfootage.com"])
                .fetch(pageURL, configuration: configuration)
            guard let source = String(data: html, encoding: .utf8) else {
                throw OnlineWallpaperError.missingPublishedDownload
            }
            let escapedVideoID = NSRegularExpression.escapedPattern(for: videoID)
            let pattern = #"href\s*=\s*[\"'](https://player\.vimeo\.com/progressive_redirect/download/\#(escapedVideoID)/[^\s\"'<>]+)[\"']"#
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = expression.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
                  let range = Range(match.range(at: 1), in: source) else {
                throw OnlineWallpaperError.missingPublishedDownload
            }
            let rawValue = String(source[range]).replacingOccurrences(of: "&amp;", with: "&")
            guard let url = URL(string: rawValue),
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw OnlineWallpaperError.invalidPublishedDownload
            }
            let pathHasTraversal = components.path
                .split(separator: "/")
                .contains { $0 == "." || $0 == ".." }
            guard components.scheme?.lowercased() == "https",
                  components.host?.lowercased() == "player.vimeo.com",
                  components.user == nil, components.password == nil,
                  !pathHasTraversal,
                  components.path.hasPrefix("/progressive_redirect/download/\(videoID)/") else {
                throw OnlineWallpaperError.invalidPublishedDownload
            }
            let signatures = components.queryItems?.filter { $0.name == "signature" } ?? []
            let expirations = components.queryItems?.filter { $0.name == "expires" } ?? []
            guard signatures.count == 1, let signature = signatures.first?.value, !signature.isEmpty,
                  expirations.count == 1, let expiryValue = expirations.first?.value,
                  let expiry = Int64(expiryValue), expiry > Int64(Date().timeIntervalSince1970) else {
                throw OnlineWallpaperError.invalidPublishedDownload
            }
            return url
        case .unavailable:
            throw OnlineWallpaperError.invalidCatalogItem
        }
    }
}

@MainActor
final class OnlineWallpaperDownload: NSObject, @preconcurrency URLSessionDownloadDelegate {
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var resultURL: URL?
    private var progressHandler: ((Double?) -> Void)?
    private var fileExtension = "mp4"
    private var item: OnlineWallpaper?
    private let configuration: URLSessionConfiguration
    private static let maximumDownloadBytes: Int64 = 1_073_741_824

    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        super.init()
    }

    func download(_ item: OnlineWallpaper, progress: @escaping (Double?) -> Void) async throws -> URL {
        guard !Task.isCancelled else { throw CancellationError() }
        try item.validate()
        return try await withTaskCancellationHandler {
            let url = try await OnlineWallpaperDownloadURLResolver.resolve(item.downloadRoute,
                                                                           configuration: configuration)
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                progressHandler = progress
                fileExtension = item.fileExtension.lowercased()
                self.item = item
                configuration.timeoutIntervalForRequest = 45
                configuration.timeoutIntervalForResource = 1800
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
                self.session = session
                var request = URLRequest(url: url)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let task = session.downloadTask(with: request)
                self.task = task
                task.resume()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.task?.cancel() }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > Self.maximumDownloadBytes {
            downloadTask.cancel()
            finish(.failure(OnlineWallpaperError.downloadTooLarge))
            return
        }
        progressHandler?(totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        let nextHost = request.url?.host?.lowercased()
        guard request.url?.scheme?.lowercased() == "https", request.url?.user == nil,
              request.url?.password == nil, nextHost.map({ item?.downloadRoute.allowedRedirectHosts.contains($0) }) == true else {
            completionHandler(nil)
            finish(.failure(OnlineWallpaperError.invalidPublishedDownload))
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let response = downloadTask.response as? HTTPURLResponse else {
            finish(.failure(OnlineWallpaperError.missingDownload))
            return
        }
        guard let responseURL = response.url,
              responseURL.scheme?.lowercased() == "https",
              responseURL.user == nil, responseURL.password == nil,
              item?.downloadRoute.allowedRedirectHosts.contains(responseURL.host?.lowercased() ?? "") == true else {
            finish(.failure(OnlineWallpaperError.invalidPublishedDownload))
            return
        }
        guard (200..<300).contains(response.statusCode) else {
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            finish(.failure(OnlineWallpaperError.httpStatus(status)))
            return
        }
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
            let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard byteCount <= Self.maximumDownloadBytes else {
                finish(.failure(OnlineWallpaperError.downloadTooLarge))
                return
            }
            try FileManager.default.moveItem(at: location, to: target)
            resultURL = target
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        guard let resultURL else {
            if let response = task.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
                finish(.failure(OnlineWallpaperError.httpStatus(response.statusCode)))
            } else {
                finish(.failure(OnlineWallpaperError.missingDownload))
            }
            return
        }
        finish(.success(resultURL))
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        task = nil
        session?.invalidateAndCancel()
        session = nil
        progressHandler = nil
        item = nil
        if case .failure = result, let resultURL { try? FileManager.default.removeItem(at: resultURL) }
        resultURL = nil
        continuation.resume(with: result)
    }

}
