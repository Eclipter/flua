import Foundation

struct OnlineCatalogPublicProviderService: OnlineCatalogPageLoading {
    private static let pageSize = 24

    func load(_ request: OnlineCatalogPageRequest) async throws -> OnlineCatalogPage {
        switch request.source {
        case .grandCanyonNPS, .joshuaTreeNPS:
            return try await OnlineCatalogProviderService().load(request)
        case .nasaSVS:
            return try await NASAOnlineCatalog.load(request, pageSize: Self.pageSize)
        default:
            throw OnlineCatalogProviderError.unimplementedCollection(request.source.title)
        }
    }
}

enum NASAOnlineCatalog {
    private static let host = "svs.gsfc.nasa.gov"
    private static let licenseURL = URL(string: "https://svs.gsfc.nasa.gov/help/")!

    static func load(_ request: OnlineCatalogPageRequest, pageSize: Int) async throws -> OnlineCatalogPage {
        let offset = Int(request.cursor ?? "0") ?? 0
        guard offset >= 0, String(offset) == (request.cursor ?? "0") else {
            throw OnlineCatalogProviderError.invalidResponse
        }
        var components = URLComponents(string: "https://svs.gsfc.nasa.gov/api/search/")!
        components.queryItems = [
            URLQueryItem(name: "limit", value: String(pageSize)),
            URLQueryItem(name: "offset", value: String(offset))
        ]
        if !request.query.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "search", value: request.query))
        }
        let (data, _) = try await CatalogHTTP.request(components.url!, allowedHosts: [host], limit: 8_000_000)
        let parsed = try parseSearchResponse(data, offset: offset)

        var items: [OnlineWallpaper] = []
        for batchStart in stride(from: 0, to: parsed.pageIDs.count, by: 4) {
            try Task.checkCancellation()
            let batch = Array(parsed.pageIDs[batchStart..<min(batchStart + 4, parsed.pageIDs.count)])
            let batchItems = try await withThrowingTaskGroup(of: [OnlineWallpaper].self) { group in
                for pageID in batch {
                    group.addTask { try await pageItems(pageID: pageID) }
                }
                var resolved: [OnlineWallpaper] = []
                for try await page in group { resolved.append(contentsOf: page) }
                return resolved
            }
            items.append(contentsOf: batchItems)
        }
        return OnlineCatalogPage(items: items, nextCursor: parsed.nextCursor)
    }

    static func parseSearchResponse(_ data: Data, offset: Int) throws -> (pageIDs: [Int], nextCursor: String?) {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let response = json as? [String: Any],
              let results = response["results"] as? [[String: Any]],
              let count = response["count"] as? Int else {
            throw OnlineCatalogProviderError.invalidResponse
        }
        let pageIDs = results.compactMap { $0["id"] as? Int }
        guard pageIDs.count == results.count else { throw OnlineCatalogProviderError.invalidResponse }
        let nextOffset = offset + results.count
        return (pageIDs, nextOffset < count ? String(nextOffset) : nil)
    }

    private static func pageItems(pageID: Int) async throws -> [OnlineWallpaper] {
        let apiURL = URL(string: "https://svs.gsfc.nasa.gov/api/\(pageID)/")!
        let (data, _) = try await CatalogHTTP.request(apiURL, allowedHosts: [host], limit: 12_000_000)
        let json = try JSONSerialization.jsonObject(with: data)
        guard let page = json as? [String: Any] else { throw OnlineCatalogProviderError.invalidResponse }
        return parsePage(page, pageID: pageID)
    }

    static func parsePage(_ page: [String: Any], pageID: Int) -> [OnlineWallpaper] {
        guard let groups = page["media_groups"] as? [[String: Any]] else { return [] }
        let pageURL = URL(string: "https://svs.gsfc.nasa.gov/\(pageID)/")!
        let title = page["title"] as? String ?? "NASA Scientific Visualization"
        let pageDescription = plainText(page["description"] as? String ?? "")
        let pageRightsText = rightsText(in: page, fields: ["description", "main_credits", "credits", "audio_track"])
        let pageHasSeparateAudio = hasSeparateAudioRestriction(pageRightsText)
        guard !hasThirdPartyRights(pageRightsText) else { return [] }
        let thumbnail = (page["main_image"] as? [String: Any])?["url"] as? String
        let creator = credits(in: page["main_credits"] ?? page["credits"])
        var items: [OnlineWallpaper] = []
        for group in groups {
            guard let media = group["items"] as? [[String: Any]] else { continue }
            let groupRightsText = rightsText(in: group, fields: ["title", "caption", "description", "credits", "extra_data"])
            guard !hasThirdPartyRights(groupRightsText) else { continue }
            let hasSeparateAudio = pageHasSeparateAudio || hasSeparateAudioRestriction(groupRightsText)
            let groupTitle = [group["title"] as? String, group["caption"] as? String,
                              group["description"] as? String]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty && $0 != "<br>" }
            let movies = media.compactMap { entry -> (asset: [String: Any], url: URL)? in
                let asset = entry["instance"] as? [String: Any]
                    ?? entry["media"] as? [String: Any]
                    ?? entry
                guard (asset["media_type"] as? String ?? entry["media_type"] as? String) == "Movie",
                      let rawURL = asset["url"] as? String,
                      let url = httpsURL(rawURL, expectedHost: host) else { return nil }
                return (asset, url)
            }
            guard let fallbackMovie = movies.first,
                  let clipID = (group["id"] as? Int) ?? (fallbackMovie.asset["id"] as? Int) else { continue }
            let nativeMovies = movies.filter { ["mp4", "mov", "m4v"].contains($0.url.pathExtension.lowercased()) }
            let bestDownload = nativeMovies.max { pixelArea($0.asset) < pixelArea($1.asset) }
            let previewMovie = nativeMovies.filter { pixelArea($0.asset) > 0 && pixelArea($0.asset) <= 1280 * 720 }
                .min { pixelArea($0.asset) < pixelArea($1.asset) }
            let imageURL = thumbnail.flatMap { httpsURL($0, expectedHost: host) }
                ?? media.compactMap { entry -> URL? in
                    let asset = entry["instance"] as? [String: Any]
                        ?? entry["media"] as? [String: Any]
                        ?? entry
                    guard (asset["media_type"] as? String ?? entry["media_type"] as? String) == "Image",
                          let raw = asset["url"] as? String else { return nil }
                    return httpsURL(raw, expectedHost: host)
                }.first
            guard let imageURL else { continue }
            let groupDescription = plainText(group["description"] as? String ?? "")
            let altText = plainText(fallbackMovie.asset["alt_text"] as? String ?? "")
            let mediaTitle = groupTitle.flatMap { plainText($0).nilIfEmpty } ?? title
            let summary = groupDescription.nilIfEmpty ?? altText.nilIfEmpty ?? pageDescription.nilIfEmpty
            let route: OnlineWallpaperDownloadRoute
            let fileExtension: String
            if hasSeparateAudio {
                route = .unavailable("This visualization includes separately licensed audio and cannot be downloaded here.")
                fileExtension = bestDownload?.url.pathExtension.lowercased() ?? "mp4"
            } else if let bestDownload {
                route = .direct(bestDownload.url)
                fileExtension = bestDownload.url.pathExtension.lowercased()
            } else {
                route = .unavailable("NASA SVS does not provide a native MP4 or QuickTime rendition for this clip.")
                fileExtension = "mp4"
            }
            let previewURL = previewMovie?.url ?? bestDownload?.url ?? fallbackMovie.url
            let previewUnavailableReason = bestDownload == nil || hasSeparateAudio
                ? "NASA SVS does not provide an eligible lightweight native video preview for this clip."
                : nil
            items.append(OnlineWallpaper(
                id: "nasaSVS:\(pageID):\(clipID)",
                title: mediaTitle,
                summary: summary,
                sourceName: OnlineWallpaperSource.nasaSVS.title,
                sourceURL: pageURL,
                creator: creator,
                licenseName: hasSeparateAudio ? "Public domain visuals; separately licensed audio" : "Public domain (unless otherwise noted)",
                licenseURL: licenseURL,
                modificationNotice: nil,
                thumbnailURL: imageURL,
                previewURL: previewURL,
                previewMode: previewUnavailableReason == nil
                    ? .boundedRange(maximumBytes: 12_000_000, maximumDuration: 2) : .direct,
                previewUnavailableReason: previewUnavailableReason,
                downloadRoute: route,
                fileExtension: fileExtension
            ))
        }
        return items
    }

    private static func pixelArea(_ asset: [String: Any]) -> Int {
        (asset["width"] as? Int ?? 0) * (asset["height"] as? Int ?? 0)
    }

    private static func httpsURL(_ value: String, expectedHost: String) -> URL? {
        guard var components = URLComponents(string: value),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host?.lowercased() == expectedHost,
              components.user == nil, components.password == nil else { return nil }
        components.scheme = "https"
        return components.url
    }

    private static func rightsText(in object: [String: Any], fields: [String]) -> String {
        fields.flatMap { field -> [String] in
            let value = object[field] ?? NSNull()
            let category = ["main_credits", "credits"].contains(field) ? (value as? [String: Any]).map { Array($0.keys) } ?? [] : []
            return category + allStrings(in: value)
        }.joined(separator: " ").lowercased()
    }

    private static func hasSeparateAudioRestriction(_ value: String) -> Bool {
        ["licensed music", "music licensed separately", "separately licensed music",
         "licensed audio", "audio licensed separately", "separately licensed audio",
         "third-party music", "third party music", "third-party audio", "third party audio",
         "universal music", "koka music", "nova music"]
            .contains { value.localizedCaseInsensitiveContains($0) }
    }

    private static func hasThirdPartyRights(_ value: String) -> Bool {
        ["licensed footage", "footage licensed separately", "licensed video", "third-party footage",
         "third party footage", "pond5", "getty images", "shutterstock", "adobe stock", "alamy",
         "reuters", "associated press"]
            .contains { value.localizedCaseInsensitiveContains($0) }
    }

    private static func allStrings(in value: Any) -> [String] {
        if let string = value as? String { return [string] }
        if let values = value as? [Any] { return values.flatMap(allStrings(in:)) }
        if let dictionary = value as? [String: Any] { return dictionary.values.flatMap(allStrings(in:)) }
        return []
    }

    private static func credits(in value: Any?) -> String {
        let names = allStrings(in: value ?? NSNull()).compactMap { string -> String? in
            let text = string.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : CatalogHTML.decode(text)
        }
        return Array(NSOrderedSet(array: names)).compactMap { $0 as? String }.joined(separator: ", ")
            .nilIfEmpty ?? "NASA Scientific Visualization Studio"
    }

    private static func plainText(_ value: String) -> String {
        let text = value.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        return CatalogHTML.decode(text).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
