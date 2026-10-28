import Foundation

private enum StockCatalogPagination {
    static func validSearchQuery(_ url: URL, expected query: String) -> Bool {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.allSatisfy({ $0.name == "s" }), items.count <= 1 else { return false }
        return items.first?.value == (query.isEmpty ? nil : query)
    }

    static func validPagePath(_ path: String) -> Bool {
        if path == "/" { return true }
        let parts = path.split(separator: "/")
        return parts.count == 2 && parts[0] == "page" && parts[1].allSatisfy(\.isNumber)
    }
}

struct OnlineCatalogStockProviderService: OnlineCatalogPageLoading, Sendable {
    private static let pageSize = 24
    private static let pageLimit = 8_000_000

    func load(_ request: OnlineCatalogPageRequest) async throws -> OnlineCatalogPage {
        try Task.checkCancellation()
        switch request.source {
        case .dareful:
            return try await loadDareful(request)
        case .isoRepublic:
            return try await loadISORepublic(request)
        case .cuteStockFootage:
            return try await loadCuteStockFootage(request)
        default:
            throw OnlineCatalogProviderError.unimplementedCollection(request.source.title)
        }
    }

    private func loadDareful(_ request: OnlineCatalogPageRequest) async throws -> OnlineCatalogPage {
        let pageURL = try Self.darefulPageURL(request)
        let html = try await CatalogHTTP.get(pageURL, allowedHosts: ["dareful.com", "www.dareful.com"], limit: Self.pageLimit)
        let rows = DarefulStockParser.rows(in: html, page: pageURL)
        guard !rows.isEmpty || CatalogHTML.hasExplicitNoResults(in: html) else { throw OnlineCatalogProviderError.invalidResponse }
        let detailPages = try await CatalogHTTP.getAll(Self.uniqueURLs(rows.map(\.url)), allowedHosts: ["dareful.com", "www.dareful.com"], limit: Self.pageLimit)
        let details = Dictionary(detailPages, uniquingKeysWith: { _, latest in latest })
        let items = rows.compactMap { row in
            details[row.url].flatMap { DarefulStockParser.item(row: row, html: $0) }
        }
        if items.count != rows.count { throw OnlineCatalogProviderError.invalidResponse }
        let next = DarefulStockParser.nextPage(in: html, current: pageURL, query: request.query)
        return OnlineCatalogPage(items: items, nextCursor: next?.absoluteString)
    }

    private func loadISORepublic(_ request: OnlineCatalogPageRequest) async throws -> OnlineCatalogPage {
        let page = try Self.numericPage(request.cursor)
        var components = URLComponents(string: "https://isorepublic.com/wp-json/wp/v2/video_post")!
        components.queryItems = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: String(Self.pageSize)),
            URLQueryItem(name: "_embed", value: "wp:featuredmedia")
        ]
        if !request.query.isEmpty { components.queryItems?.append(URLQueryItem(name: "search", value: request.query)) }
        guard let url = components.url else { throw OnlineCatalogProviderError.invalidResponse }
        let (data, response) = try await CatalogHTTP.request(url, allowedHosts: ["isorepublic.com", "www.isorepublic.com"], limit: Self.pageLimit)
        guard let records = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw OnlineCatalogProviderError.invalidResponse
        }
        let rows = records.compactMap(ISORepublicStockParser.row)
        guard rows.count == records.count else { throw OnlineCatalogProviderError.invalidResponse }
        let detailPages = try await CatalogHTTP.getAll(Self.uniqueURLs(rows.map(\.url)), allowedHosts: ["isorepublic.com", "www.isorepublic.com"], limit: Self.pageLimit)
        let details = Dictionary(detailPages, uniquingKeysWith: { _, latest in latest })
        let items = rows.compactMap { row in
            details[row.url].flatMap { ISORepublicStockParser.item(row: row, html: $0) }
        }
        if !rows.isEmpty && items.isEmpty { throw OnlineCatalogProviderError.invalidResponse }
        let totalPages = (response.value(forHTTPHeaderField: "X-WP-TotalPages")).flatMap(Int.init)
        let hasNextPage = totalPages.map { page < $0 } ?? (records.count == Self.pageSize)
        let next = hasNextPage ? String(page + 1) : nil
        return OnlineCatalogPage(items: items, nextCursor: next)
    }

    private func loadCuteStockFootage(_ request: OnlineCatalogPageRequest) async throws -> OnlineCatalogPage {
        let pageURL = try Self.cutePageURL(request)
        let html = try await CatalogHTTP.get(pageURL, allowedHosts: ["cutestockfootage.com", "www.cutestockfootage.com"], limit: Self.pageLimit)
        var rows = CuteStockFootageParser.rows(in: html, page: pageURL)
        guard !rows.isEmpty || CatalogHTML.hasExplicitNoResults(in: html) else { throw OnlineCatalogProviderError.invalidResponse }
        for index in rows.indices where rows[index].itemID.isEmpty {
            guard let postID = try await resolveCutePostID(for: rows[index]) else { continue }
            rows[index].itemID = postID
        }
        guard !rows.contains(where: { $0.itemID.isEmpty }) else { throw OnlineCatalogProviderError.invalidResponse }
        let items = rows.compactMap(CuteStockFootageParser.item)
        let next = CuteStockFootageParser.nextPage(in: html, current: pageURL, query: request.query)
        return OnlineCatalogPage(items: items, nextCursor: next?.absoluteString)
    }

    private func resolveCutePostID(for row: CuteStockFootageRow) async throws -> String? {
        var components = URLComponents(string: "https://cutestockfootage.com/wp-json/wp/v2/posts")!
        components.queryItems = [URLQueryItem(name: "slug", value: row.slug), URLQueryItem(name: "per_page", value: "1")]
        guard let url = components.url else { throw OnlineCatalogProviderError.invalidResponse }
        let (data, _) = try await CatalogHTTP.request(url, allowedHosts: ["cutestockfootage.com", "www.cutestockfootage.com"], limit: 512_000)
        return try CuteStockFootageParser.postID(in: data, for: row)
    }

    private static func numericPage(_ cursor: String?) throws -> Int {
        guard let cursor else { return 1 }
        guard let page = Int(cursor), page > 0, String(page) == cursor else { throw OnlineCatalogProviderError.invalidResponse }
        return page
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.absoluteString).inserted }
    }

    private static func darefulPageURL(_ request: OnlineCatalogPageRequest) throws -> URL {
        guard let cursor = request.cursor else {
            var components = URLComponents(string: "https://dareful.com/")!
            if !request.query.isEmpty { components.queryItems = [URLQueryItem(name: "s", value: request.query)] }
            return components.url!
        }
        guard let url = URL(string: cursor),
              ["dareful.com", "www.dareful.com"].contains(url.host?.lowercased() ?? ""),
              url.scheme == "https",
              StockCatalogPagination.validPagePath(url.path),
              StockCatalogPagination.validSearchQuery(url, expected: request.query) else {
            throw OnlineCatalogProviderError.invalidResponse
        }
        return url
    }

    private static func cutePageURL(_ request: OnlineCatalogPageRequest) throws -> URL {
        guard let cursor = request.cursor else {
            var components = URLComponents(string: "https://cutestockfootage.com/")!
            if !request.query.isEmpty { components.queryItems = [URLQueryItem(name: "s", value: request.query)] }
            return components.url!
        }
        guard let url = URL(string: cursor),
              ["cutestockfootage.com", "www.cutestockfootage.com"].contains(url.host?.lowercased() ?? ""),
              url.scheme == "https",
              StockCatalogPagination.validPagePath(url.path),
              StockCatalogPagination.validSearchQuery(url, expected: request.query) else {
            throw OnlineCatalogProviderError.invalidResponse
        }
        return url
    }
}

struct DarefulStockRow: Equatable {
    var postID: String
    var title: String
    var url: URL
    var thumbnailURL: URL
}

enum DarefulStockParser {
    static func rows(in html: String, page: URL) -> [DarefulStockRow] {
        let articles = CatalogHTML.captureValues(#"(?is)<article\b[^>]*>.*?</article>"#, group: 0, in: html)
        var seen = Set<String>()
        return articles.compactMap { article in
            guard !restricted(article),
                  let postID = CatalogHTML.firstMatch(#"\bpost-(\d+)\b"#, in: article).flatMap({ CatalogHTML.captureValues(#"\bpost-(\d+)\b"#, group: 1, in: $0).first }),
                  let anchor = CatalogHTML.captureValues(#"(?is)<a\b[^>]*class=[\"'][^\"']*\bgrid-link\b[^\"']*[\"'][^>]*>"#, group: 0, in: article).first,
                  let href = CatalogHTML.attributeValues("href", in: anchor).first,
                  let url = URL(string: CatalogHTML.decode(href), relativeTo: page)?.absoluteURL,
                  isItemURL(url),
                  let title = CatalogHTML.attributeValues("title", in: anchor).first,
                  let image = CatalogHTML.captureValues(#"(?is)<img\b[^>]*class=[\"'][^\"']*vimeo-thumbnail[^\"']*[\"'][^>]*>"#, group: 0, in: article).first,
                  let thumbnail = CatalogHTML.attributeValues("src", in: image).first,
                  let thumbnailURL = URL(string: CatalogHTML.decode(thumbnail), relativeTo: page)?.absoluteURL,
                  isTrustedHTTPSURL(thumbnailURL, hosts: ["dareful.com", "www.dareful.com"]),
                  seen.insert(postID).inserted else { return nil }
            return DarefulStockRow(postID: postID, title: CatalogHTML.decode(title).trimmingCharacters(in: .whitespacesAndNewlines), url: url, thumbnailURL: thumbnailURL)
        }
    }

    static func item(row: DarefulStockRow, html: String) -> OnlineWallpaper? {
        guard !["sponsored", "shutterstock", "licensed music", "licensed footage"].contains(where: row.title.lowercased().contains),
              let licenseAnchor = CatalogHTML.captureValues(#"(?is)<a\b[^>]*href=[\"'](https://creativecommons\.org/licenses/[^\"']+)[\"'][^>]*>(.*?)</a>"#, group: 0, in: html).first,
              let licenseURLString = CatalogHTML.captureValues(#"(?is)<a\b[^>]*href=[\"'](https://creativecommons\.org/licenses/[^\"']+)[\"']"#, group: 1, in: licenseAnchor).first,
              let licenseURL = URL(string: licenseURLString),
              let player = CatalogHTML.captureValues(#"(?is)<mux-player\b[^>]*>"#, group: 0, in: html).first,
              let playbackID = CatalogHTML.attributeValues("playback-id", in: player).first,
              playbackID.range(of: #"^[A-Za-z0-9]+$"#, options: .regularExpression) != nil,
              let button = CatalogHTML.captureValues(#"(?is)<a\b[^>]*class=[\"'][^\"']*\bmux-button\b[^\"']*[\"'][^>]*>"#, group: 0, in: html).first,
              let filename = CatalogHTML.attributeValues("data-file-name", in: button).first,
              filename.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil,
              let preview = CatalogHTML.captureValues(#"(?is)<meta\b(?=[^>]*itemprop=[\"']contentURL[\"'])(?=[^>]*content=[\"']([^\"']+\.m3u8)[\"'])[^>]*>"#, group: 0, in: html).first,
              let previewString = CatalogHTML.attributeValues("content", in: preview).first,
              let previewURL = URL(string: CatalogHTML.decode(previewString)),
              isTrustedHTTPSURL(previewURL, hosts: ["stream.mux.com"]) else { return nil }
        var downloadComponents = URLComponents(string: "https://stream.mux.com/\(playbackID)/high.mp4")!
        downloadComponents.queryItems = [URLQueryItem(name: "download", value: filename)]
        guard let downloadURL = downloadComponents.url else { return nil }
        let licenseName = CatalogHTML.text(from: licenseAnchor)
        return OnlineWallpaper(
            id: "dareful:\(row.postID)",
            title: row.title,
            summary: CatalogHTML.sourceSummary(in: html),
            sourceName: OnlineWallpaperSource.dareful.title,
            sourceURL: row.url,
            creator: "Joel Holland",
            licenseName: licenseURL.path.contains("/by/4.0") ? "Creative Commons Attribution 4.0 International" : (licenseName.isEmpty ? "Creative Commons" : licenseName),
            licenseURL: licenseURL,
            modificationNotice: nil,
            thumbnailURL: row.thumbnailURL,
            previewURL: previewURL,
            downloadRoute: .direct(downloadURL),
            fileExtension: "mp4"
        )
    }

    static func nextPage(in html: String, current: URL, query: String) -> URL? {
        CatalogHTML.nextAnchorURL(in: html, page: current).flatMap { url in
            guard isListingURL(url), StockCatalogPagination.validSearchQuery(url, expected: query) else { return nil }
            return url
        }
    }

    private static func isItemURL(_ url: URL) -> Bool {
        ["dareful.com", "www.dareful.com"].contains(url.host?.lowercased() ?? "")
            && url.scheme == "https"
            && url.path.split(separator: "/").count == 1
            && !["about-dareful-completely-free-4k-stock-video", "sitemap"].contains(url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    private static func isListingURL(_ url: URL) -> Bool {
        ["dareful.com", "www.dareful.com"].contains(url.host?.lowercased() ?? "")
            && url.scheme == "https"
            && StockCatalogPagination.validPagePath(url.path)
    }

    private static func restricted(_ html: String) -> Bool {
        let lower = html.lowercased()
        return ["sponsored", "shutterstock", "licensed music", "licensed footage"].contains(where: lower.contains)
    }
}

struct ISORepublicStockRow: Equatable {
    var title: String
    var slug: String
    var url: URL
    var thumbnailURL: URL?
}

enum ISORepublicStockParser {
    static func row(_ record: [String: Any]) -> ISORepublicStockRow? {
        guard let slug = record["slug"] as? String,
              slug.range(of: #"^[a-z0-9-]+$"#, options: .regularExpression) != nil,
              let link = record["link"] as? String,
              let url = URL(string: link),
              ["isorepublic.com", "www.isorepublic.com"].contains(url.host?.lowercased() ?? ""),
              url.scheme == "https", url.path.hasPrefix("/video/"),
              let titleObject = record["title"] as? [String: Any],
              let title = titleObject["rendered"] as? String,
              record["type"] as? String == "video_post" else { return nil }
        let embedded = record["_embedded"] as? [String: Any]
        let media = (embedded?["wp:featuredmedia"] as? [[String: Any]])?.first
        let details = media?["media_details"] as? [String: Any]
        let sizes = details?["sizes"] as? [String: Any]
        let medium = sizes?["medium"] as? [String: Any]
        let large = sizes?["medium_large"] as? [String: Any]
        let thumbnailString = (medium?["source_url"] as? String) ?? (large?["source_url"] as? String) ?? (media?["source_url"] as? String)
        let thumbnail = thumbnailString.flatMap(URL.init(string:)).flatMap {
            isTrustedHTTPSURL($0, hosts: ["isorepublic.com", "www.isorepublic.com"]) ? $0 : nil
        }
        return ISORepublicStockRow(title: CatalogHTML.decode(title), slug: slug, url: url, thumbnailURL: thumbnail)
    }

    static func item(row: ISORepublicStockRow, html: String) -> OnlineWallpaper? {
        let lower = html.lowercased()
        guard lower.contains("cc0"),
              !["sponsored", "shutterstock", "licensed music", "licensed footage"].contains(where: row.title.lowercased().contains),
              let videoTag = CatalogHTML.captureValues(#"(?is)<source\b[^>]*src=[\"'][^\"']+\.mp4[^\"']*[\"'][^>]*>"#, group: 0, in: html).first,
              let videoString = CatalogHTML.attributeValues("src", in: videoTag).first,
              let downloadURL = URL(string: CatalogHTML.decode(videoString), relativeTo: row.url)?.absoluteURL,
              isTrustedHTTPSURL(downloadURL, hosts: ["isorepublic.com", "www.isorepublic.com"]),
              let thumbnailURL = row.thumbnailURL ?? CatalogHTML.metaValue("og:image", attribute: "property", in: html).flatMap({ URL(string: CatalogHTML.decode($0), relativeTo: row.url)?.absoluteURL }).flatMap({
                  isTrustedHTTPSURL($0, hosts: ["isorepublic.com", "www.isorepublic.com"]) ? $0 : nil
              }) else { return nil }
        let creator = author(in: html) ?? "Creator not listed by ISO Republic"
        return OnlineWallpaper(
            id: "isoRepublic:\(row.slug)",
            title: row.title,
            summary: CatalogHTML.sourceSummary(in: html),
            sourceName: OnlineWallpaperSource.isoRepublic.title,
            sourceURL: row.url,
            creator: creator,
            licenseName: "CC0",
            licenseURL: URL(string: "https://isorepublic.com/license/")!,
            modificationNotice: nil,
            thumbnailURL: thumbnailURL,
            previewURL: downloadURL,
            previewMode: .boundedRange(maximumBytes: 12_000_000, maximumDuration: 2),
            downloadRoute: .direct(downloadURL),
            fileExtension: "mp4"
        )
    }

    private static func author(in html: String) -> String? {
        if let anchor = CatalogHTML.captureValues(#"(?is)<a\b(?=[^>]*\bclass\s*=\s*[\"'][^\"']*\bmedia-author\b[^\"']*[\"'])[^>]*>.*?</a>"#, group: 0, in: html).first,
           let title = CatalogHTML.attributeValues("title", in: anchor).first {
            let creator = CatalogHTML.decode(title).trimmingCharacters(in: .whitespacesAndNewlines)
            if !creator.isEmpty { return creator }
        }
        guard let script = CatalogHTML.captureValues(#"(?is)<script\b[^>]*type=[\"']application/ld\+json[\"'][^>]*>(.*?)</script>"#, group: 1, in: html).first,
              let data = script.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        func find(_ value: Any) -> String? {
            if let dictionary = value as? [String: Any] {
                if let author = dictionary["author"] as? [String: Any],
                   let name = author["name"] as? String {
                    let creator = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !["editor", "admin", "administrator", "webmaster"].contains(creator.lowercased()) {
                        return creator.isEmpty ? nil : creator
                    }
                }
                for child in dictionary.values { if let name = find(child) { return name } }
            } else if let array = value as? [Any] {
                for child in array { if let name = find(child) { return name } }
            }
            return nil
        }
        return find(object)
    }
}

struct CuteStockFootageRow: Equatable {
    var itemID: String
    var slug: String
    var videoID: String
    var title: String
    var url: URL
    var thumbnailURL: URL
}

enum CuteStockFootageParser {
    static func rows(in html: String, page: URL) -> [CuteStockFootageRow] {
        let anchors = CatalogHTML.captureValues(#"(?is)<a\b[^>]*class=[\"'][^\"']*\bgrid-link\b[^\"']*[\"'][^>]*>"#, group: 0, in: html)
        var seen = Set<String>()
        return anchors.compactMap { anchor in
            guard let href = CatalogHTML.attributeValues("href", in: anchor).first,
                  let url = URL(string: CatalogHTML.decode(href), relativeTo: page)?.absoluteURL,
                  ["cutestockfootage.com", "www.cutestockfootage.com"].contains(url.host?.lowercased() ?? ""),
                  url.scheme == "https",
                  let title = CatalogHTML.attributeValues("title", in: anchor).first,
                  let videoID = CatalogHTML.attributeValues("data-vimeo", in: anchor).first,
                  videoID.allSatisfy(\.isNumber), !videoID.isEmpty,
                  let slug = itemSlug(for: url),
                  let imageTag = CatalogHTML.captureValues(#"(?is)<img\b(?=[^>]*id=[\"']vimeo-thumbnail-\#(videoID)[\"'])[^>]*class=[\"'][^\"']*vimeo-thumbnail[^\"']*[\"'][^>]*>"#, group: 0, in: html).first,
                  let image = CatalogHTML.attributeValues("src", in: imageTag).first,
                  let thumbnailURL = URL(string: CatalogHTML.decode(image), relativeTo: page)?.absoluteURL,
                  isTrustedHTTPSURL(thumbnailURL, hosts: ["cutestockfootage.com", "www.cutestockfootage.com"]),
                  seen.insert(url.absoluteString).inserted,
                  !restricted(title) else { return nil }
            return CuteStockFootageRow(itemID: stockItemID(for: url) ?? "", slug: slug, videoID: videoID, title: CatalogHTML.decode(title).trimmingCharacters(in: .whitespacesAndNewlines), url: url, thumbnailURL: thumbnailURL)
        }
    }

    static func item(_ row: CuteStockFootageRow) -> OnlineWallpaper {
        OnlineWallpaper(
            id: "cuteStockFootage:\(row.itemID):\(row.slug)",
            title: row.title,
            summary: nil,
            sourceName: OnlineWallpaperSource.cuteStockFootage.title,
            sourceURL: row.url,
            creator: "CuteStockFootage.com",
            licenseName: "Creative Commons Attribution 4.0 International",
            licenseURL: URL(string: "https://cutestockfootage.com/terms-and-conditions/")!,
            modificationNotice: nil,
            thumbnailURL: row.thumbnailURL,
            previewURL: row.thumbnailURL,
            previewMode: .boundedRange(maximumBytes: 12_000_000, maximumDuration: 2),
            downloadRoute: .cuteStockFootage(pageURL: row.url, videoID: row.videoID),
            fileExtension: "mp4"
        )
    }

    static func postID(in data: Data, for row: CuteStockFootageRow) throws -> String? {
        guard let records = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw OnlineCatalogProviderError.invalidResponse
        }
        guard let record = records.first,
              record["type"] as? String == "post",
              record["slug"] as? String == row.slug,
              let id = record["id"] as? Int, id > 0,
              let link = record["link"] as? String,
              let canonical = URL(string: link),
              ["cutestockfootage.com", "www.cutestockfootage.com"].contains(canonical.host?.lowercased() ?? ""),
              canonical.scheme == "https",
              canonical.path == row.url.path else { return nil }
        return String(id)
    }

    static func nextPage(in html: String, current: URL, query: String) -> URL? {
        CatalogHTML.nextAnchorURL(in: html, page: current).flatMap { url in
            guard ["cutestockfootage.com", "www.cutestockfootage.com"].contains(url.host?.lowercased() ?? ""),
                  url.scheme == "https",
                  StockCatalogPagination.validPagePath(url.path),
                  StockCatalogPagination.validSearchQuery(url, expected: query) else { return nil }
            return url
        }
    }

    private static func restricted(_ title: String) -> Bool {
        let lower = title.lowercased()
        return ["sponsored", "shutterstock", "licensed music", "licensed footage", "editorial use only"].contains(where: lower.contains)
    }

    private static func stockItemID(for url: URL) -> String? {
        let parts = url.path.split(separator: "/").map(String.init)
        if parts.count == 3, parts[0] == "stock-footage", parts[1].allSatisfy(\.isNumber), isSlug(parts[2]) {
            return parts[1]
        }
        return nil
    }

    private static func itemSlug(for url: URL) -> String? {
        let parts = url.path.split(separator: "/").map(String.init)
        if parts.count == 3, parts[0] == "stock-footage", isSlug(parts[2]) { return parts[2] }
        if parts.count == 1, isSlug(parts[0]) { return parts[0] }
        return nil
    }

    private static func isSlug(_ value: String) -> Bool {
        !value.isEmpty && value.range(of: #"^[a-z0-9-]+$"#, options: .regularExpression) != nil
    }
}

extension CatalogHTML {
    static func metaValue(_ key: String, attribute: String, in html: String) -> String? {
        for tag in captureValues(#"(?is)<meta\b[^>]*>"#, group: 0, in: html)
        where attributeValues(attribute, in: tag).contains(key) {
            return attributeValues("content", in: tag).first
        }
        return nil
    }

    static func hasExplicitNoResults(in html: String) -> Bool {
        firstMatch(#"(?i)no\s+.{0,160}videos?\s+found"#, in: text(from: html)) != nil
    }

    static func sourceSummary(in html: String) -> String? {
        let candidates = captureValues(#"(?is)<meta\b(?=[^>]*itemprop=[\"']description[\"'])(?=[^>]*content=[\"']([^\"']+)[\"'])[^>]*>"#, group: 0, in: html)
            + captureValues(#"(?is)<meta\b(?=[^>]*name=[\"']description[\"'])(?=[^>]*content=[\"']([^\"']+)[\"'])[^>]*>"#, group: 0, in: html)
        for candidate in candidates {
            guard let content = attributeValues("content", in: candidate).first else { continue }
            let summary = decode(content).trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = summary.lowercased()
            guard !summary.isEmpty,
                  !normalized.hasPrefix("download royalty-free stock video clip of"),
                  !normalized.hasPrefix("download the free video"),
                  !normalized.hasPrefix("download free stock video") else { continue }
            return summary
        }
        return nil
    }

    static func text(from html: String) -> String {
        let visibleHTML = html.replacingOccurrences(of: #"(?is)<(script|style)\b.*?</\1>"#, with: " ", options: .regularExpression)
        return decode(visibleHTML.replacingOccurrences(of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func nextAnchorURL(in html: String, page: URL) -> URL? {
        let containers = elements(className: "pagination", containing: "pagination", in: html)
        let anchors = containers.flatMap { captureValues(#"(?is)<a\b[^>]*>.*?</a>"#, group: 0, in: $0) }
        for anchor in anchors {
            let content = text(from: anchor).lowercased()
            let classes = attributeValues("class", in: anchor).joined(separator: " ").lowercased()
            guard content.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("next")
                    || classes.split(whereSeparator: \.isWhitespace).contains("next") else { continue }
            guard let href = attributeValues("href", in: anchor).first,
                  let url = URL(string: decode(href), relativeTo: page)?.absoluteURL else { continue }
            return url
        }
        return nil
    }
}

private func isTrustedHTTPSURL(_ url: URL, hosts: Set<String>) -> Bool {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          components.scheme?.lowercased() == "https",
          let host = components.host?.lowercased(), hosts.contains(host),
          components.user == nil, components.password == nil else { return false }
    return true
}
