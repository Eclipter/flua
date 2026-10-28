import Foundation

struct OnlineCatalogProviderService: OnlineCatalogPageLoading {
    func load(_ request: OnlineCatalogPageRequest) async throws -> OnlineCatalogPage {
        try Task.checkCancellation()
        switch request.source {
        case .grandCanyonNPS, .joshuaTreeNPS:
            let archive = try await NPSOnlineArchive.shared.items(for: request.source)
            let matches = archive.filter { item in
                request.query.isEmpty
                    || item.title.localizedCaseInsensitiveContains(request.query)
                    || item.summary?.localizedCaseInsensitiveContains(request.query) == true
                    || item.creator.localizedCaseInsensitiveContains(request.query)
                    || item.sourceURL.absoluteString.localizedCaseInsensitiveContains(request.query)
            }
            return page(matches, request: request, pageSize: 24)
        case .nasaSVS:
            return try await OnlineCatalogPublicProviderService().load(request)
        case .dareful, .isoRepublic, .cuteStockFootage:
            return try await OnlineCatalogStockProviderService().load(request)
        }
    }

    private func page(_ items: [OnlineWallpaper], request: OnlineCatalogPageRequest,
                      pageSize: Int) -> OnlineCatalogPage {
        let offset = Int(request.cursor ?? "0") ?? 0
        guard offset >= 0, offset < items.count else { return OnlineCatalogPage(items: [], nextCursor: nil) }
        let end = min(offset + pageSize, items.count)
        return OnlineCatalogPage(items: Array(items[offset..<end]),
                                 nextCursor: end < items.count ? String(end) : nil)
    }
}

enum OnlineCatalogProviderError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case responseTooLarge
    case unimplementedCollection(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The source returned an invalid collection response."
        case .httpStatus(let status): return "The source returned HTTP status \(status)."
        case .responseTooLarge: return "The source response is larger than supported."
        case .unimplementedCollection(let source): return "\(source) collection browsing is not available yet."
        }
    }
}

private actor NPSOnlineArchive {
    static let shared = NPSOnlineArchive()
    private var cache: [OnlineWallpaperSource: [OnlineWallpaper]] = [:]

    func items(for source: OnlineWallpaperSource) async throws -> [OnlineWallpaper] {
        if let cached = cache[source] { return cached }
        let index: URL
        switch source {
        case .grandCanyonNPS:
            index = URL(string: "https://www.nps.gov/grca/learn/photosmultimedia/b-roll_hd_index.htm")!
        case .joshuaTreeNPS:
            index = URL(string: "https://www.nps.gov/jotr/learn/photosmultimedia/broll.htm")!
        default:
            return []
        }

        let html = try await CatalogHTTP.get(index, allowedHosts: ["www.nps.gov", "nps.gov"], limit: 8_000_000)
        let pages = NPSOnlineParser.archivePages(in: html, source: source)
        guard !pages.isEmpty else { throw OnlineCatalogProviderError.invalidResponse }
        let pageHTML = try await CatalogHTTP.getAll(pages, allowedHosts: ["www.nps.gov", "nps.gov"], limit: 8_000_000)
        let items = pageHTML.sorted { $0.0.absoluteString < $1.0.absoluteString }
            .flatMap { NPSOnlineParser.items(in: $0.1, page: $0.0, source: source) }
        var seen = Set<String>()
        let uniqueItems = items.filter { seen.insert($0.id).inserted }
        guard !uniqueItems.isEmpty else { throw OnlineCatalogProviderError.invalidResponse }
        cache[source] = uniqueItems
        return uniqueItems
    }
}

enum NPSOnlineParser {
    static func archivePages(in html: String, source: OnlineWallpaperSource) -> [URL] {
        let allowedPrefix: String
        switch source {
        case .grandCanyonNPS: allowedPrefix = "/grca/learn/photosmultimedia/"
        case .joshuaTreeNPS: allowedPrefix = "/jotr/learn/photosmultimedia/"
        default: return []
        }
        let excluded = source == .grandCanyonNPS ? "b-roll_hd_index.htm" : "broll.htm"
        let links = CatalogHTML.attributeValues("href", in: html)
            + CatalogHTML.captureValues(#"(?:https?://www\.nps\.gov)?(/(?:grca|jotr)/learn/photosmultimedia/[A-Za-z0-9_-]+\.htm)"#, group: 1, in: html)
        return Set(links.compactMap { value -> URL? in
            guard let url = URL(string: CatalogHTML.decode(value), relativeTo: URL(string: "https://www.nps.gov"))?.absoluteURL,
                  url.host?.lowercased() == "www.nps.gov",
                  url.path.hasPrefix(allowedPrefix),
                  url.lastPathComponent != excluded,
                  url.pathExtension.lowercased() == "htm" else { return nil }
            if source == .grandCanyonNPS && !url.lastPathComponent.hasPrefix("b-roll_hd") { return nil }
            return url
        }).sorted { $0.absoluteString < $1.absoluteString }
    }

    static func items(in html: String, page: URL, source: OnlineWallpaperSource) -> [OnlineWallpaper] {
        let blocks = CatalogHTML.elements(className: "VideoHero", containing: "VideoObject", in: html)
        return blocks.compactMap { block in
            guard let title = CatalogHTML.metaContent(for: "name", in: block),
                  let thumbnail = CatalogHTML.metaContent(for: "thumbnailUrl", in: block),
                  let thumbnailURL = URL(string: CatalogHTML.decode(thumbnail), relativeTo: page)?.absoluteURL,
                  let download = CatalogHTML.bestRendition(in: block, preferred: ["1080", "720", "480", "360"]),
                  let downloadURL = URL(string: CatalogHTML.decode(download.url), relativeTo: page)?.absoluteURL,
                  let clipID = CatalogHTML.firstMatch(#"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#, in: downloadURL.path) else { return nil }

            let previewRendition = CatalogHTML.bestRendition(in: block, preferred: ["360", "480", "720", "1080"])
            let previewURL = previewRendition.flatMap { URL(string: CatalogHTML.decode($0.url), relativeTo: page)?.absoluteURL } ?? thumbnailURL
            let cleanTitle = CatalogHTML.decode(title).trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = CatalogHTML.metaContent(for: "description", in: block)
                .map(CatalogHTML.decode)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let name = source.title
            let licenseURL: URL
            switch source {
            case .grandCanyonNPS:
                licenseURL = URL(string: "https://www.nps.gov/grca/learn/photosmultimedia/b-roll_hd_index.htm")!
            case .joshuaTreeNPS:
                licenseURL = URL(string: "https://www.nps.gov/jotr/learn/photosmultimedia/broll.htm")!
            default:
                return nil
            }
            let isAllowed = !block.localizedCaseInsensitiveContains("licensed music")
                && !block.localizedCaseInsensitiveContains("licensed footage")
                && !block.localizedCaseInsensitiveContains("stock footage")
                && !block.localizedCaseInsensitiveContains("arrowhead")
            let sourceID = "\(source.rawValue):\(clipID)"
            return OnlineWallpaper(
                id: sourceID,
                title: cleanTitle,
                summary: summary,
                sourceName: name,
                sourceURL: page,
                creator: "National Park Service; individual creator not listed",
                licenseName: "Public domain (National Park Service)",
                licenseURL: licenseURL,
                modificationNotice: nil,
                thumbnailURL: thumbnailURL,
                previewURL: previewURL,
                previewMode: previewRendition == nil
                    ? .direct : .boundedRange(maximumBytes: 12_000_000, maximumDuration: 2),
                previewUnavailableReason: previewRendition == nil ? "This source does not provide a playable preview for this clip." : nil,
                downloadRoute: isAllowed ? .direct(downloadURL) : .unavailable("This clip has a separate rights restriction."),
                fileExtension: downloadURL.pathExtension
            )
        }
    }
}

enum CatalogHTML {
    private static func regex(_ pattern: String, in value: String) -> [NSTextCheckingResult] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        return expression.matches(in: value, range: NSRange(value.startIndex..., in: value))
    }

    static func attributeValues(_ attribute: String, in html: String) -> [String] {
        let escaped = NSRegularExpression.escapedPattern(for: attribute)
        return regex("\\b\(escaped)\\s*=\\s*['\\\"]([^'\\\"]+)['\\\"]", in: html).compactMap { match in
            guard let range = Range(match.range(at: 1), in: html) else { return nil }
            return String(html[range])
        }
    }

    static func metaContent(for property: String, in html: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: property)
        let pattern = #"<meta\b(?=[^>]*\bitemprop\s*=\s*["']\#(escaped)["'])(?=[^>]*\bcontent\s*=\s*["']([^"']+)["'])[^>]*>"#
        guard let match = regex(pattern, in: html).first,
              let range = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[range])
    }

    static func elements(className: String, containing marker: String, in html: String) -> [String] {
        let escapedClass = NSRegularExpression.escapedPattern(for: className)
        let escapedMarker = NSRegularExpression.escapedPattern(for: marker)
        let starts = regex("<div\\b(?=[^>]*\\bclass\\s*=\\s*['\"][^'\"]*\\b\(escapedClass)\\b)(?=[^>]*\(escapedMarker))[^>]*>", in: html)
        let divTags = try! NSRegularExpression(pattern: "</?div\\b[^>]*>", options: [.caseInsensitive])
        var blocks: [String] = []
        for start in starts {
            guard Range(start.range, in: html) != nil else { continue }
            var depth = 1
            var end = start.range.upperBound
            let tailRange = NSRange(location: start.range.upperBound, length: html.utf16.count - start.range.upperBound)
            for tag in divTags.matches(in: html, range: tailRange) {
                guard let tagRange = Range(tag.range, in: html) else { continue }
                let text = String(html[tagRange]).lowercased()
                if text.hasPrefix("</div") { depth -= 1 } else if !text.hasSuffix("/>") { depth += 1 }
                if depth == 0 { end = tag.range.upperBound; break }
            }
            if depth == 0,
               let wholeRange = Range(NSRange(location: start.range.location, length: end - start.range.location), in: html) {
                blocks.append(String(html[wholeRange]))
            }
        }
        return blocks
    }

    static func bestRendition(in html: String, preferred resolutions: [String]) -> (url: String, resolution: String)? {
        let sources = regex("<source\\b[^>]*>", in: html).compactMap { match -> (String, String)? in
            guard let range = Range(match.range, in: html) else { return nil }
            let tag = String(html[range])
            guard let url = attributeValues("src", in: tag).first,
                  let resolution = attributeValues("res", in: tag).first,
                  url.lowercased().hasSuffix(".mp4") else { return nil }
            return (url, resolution)
        }
        for resolution in resolutions {
            if let match = sources.first(where: { $0.1 == resolution }) { return (match.0, match.1) }
        }
        return nil
    }

    static func decode(_ value: String) -> String {
        var decoded = value
        if let expression = try? NSRegularExpression(pattern: #"&#(?:x([0-9a-fA-F]+)|([0-9]+));"#) {
            let matches = expression.matches(in: value, range: NSRange(value.startIndex..., in: value))
            let mutable = NSMutableString(string: value)
            for match in matches.reversed() {
                let scalarText = (1..<match.numberOfRanges).compactMap { index -> String? in
                    guard match.range(at: index).location != NSNotFound,
                          let range = Range(match.range(at: index), in: value) else { return nil }
                    return String(value[range])
                }.first
                guard let scalarText,
                      let number = UInt32(scalarText, radix: match.range(at: 1).location == NSNotFound ? 10 : 16),
                      let scalar = UnicodeScalar(number),
                      let fullRange = Range(match.range, in: value) else { continue }
                mutable.replaceCharacters(in: NSRange(fullRange, in: value), with: String(scalar))
            }
            decoded = mutable as String
        }
        return decoded.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#8217;", with: "’")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    static func firstMatch(_ pattern: String, in value: String) -> String? {
        guard let match = regex(pattern, in: value).first,
              let range = Range(match.range, in: value) else { return nil }
        return String(value[range])
    }

    static func captureValues(_ pattern: String, group: Int, in value: String) -> [String] {
        regex(pattern, in: value).compactMap { match in
            guard match.numberOfRanges > group,
                  let range = Range(match.range(at: group), in: value) else { return nil }
            return String(value[range])
        }
    }
}

@MainActor
enum CatalogHTTP {
    static func get(_ url: URL, allowedHosts: Set<String>, limit: Int) async throws -> String {
        let (data, _) = try await request(url, allowedHosts: allowedHosts, limit: limit)
        guard let html = String(data: data, encoding: .utf8) else { throw OnlineCatalogProviderError.invalidResponse }
        return html
    }

    static func request(_ url: URL, allowedHosts: Set<String>, limit: Int) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let client = BoundedHTTPSDataRequest(maximumBytes: limit, allowedHosts: allowedHosts)
        do {
            return try await client.fetchResponse(url, configuration: configuration)
        } catch let error as OnlineWallpaperError {
            switch error {
            case .httpStatus(let status): throw OnlineCatalogProviderError.httpStatus(status)
            case .sourcePageTooLarge: throw OnlineCatalogProviderError.responseTooLarge
            default: throw OnlineCatalogProviderError.invalidResponse
            }
        }
    }

    static func getAll(_ urls: [URL], allowedHosts: Set<String>, limit: Int) async throws -> [(URL, String)] {
        var results: [(URL, String)] = []
        for batchStart in stride(from: 0, to: urls.count, by: 4) {
            try Task.checkCancellation()
            let batch = Array(urls[batchStart..<min(batchStart + 4, urls.count)])
            let batchResults = try await withThrowingTaskGroup(of: (URL, String).self) { group in
                for url in batch {
                    group.addTask { (url, try await get(url, allowedHosts: allowedHosts, limit: limit)) }
                }
                var values: [(URL, String)] = []
                for try await value in group { values.append(value) }
                return values
            }
            results.append(contentsOf: batchResults)
        }
        return results
    }

}
