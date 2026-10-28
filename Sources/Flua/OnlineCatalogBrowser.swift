import Combine
import Foundation

enum OnlineWallpaperSourceFilter: Equatable, Sendable {
    case all
    case source(OnlineWallpaperSource)

    var sources: [OnlineWallpaperSource] {
        switch self {
        case .all: return OnlineWallpaperSource.allCases
        case .source(let source): return [source]
        }
    }
}

struct OnlineCatalogPageRequest: Equatable, Sendable {
    var source: OnlineWallpaperSource
    var query: String
    var cursor: String?
}

struct OnlineCatalogPage: Sendable {
    var items: [OnlineWallpaper]
    var nextCursor: String?
}

protocol OnlineCatalogPageLoading: Sendable {
    func load(_ request: OnlineCatalogPageRequest) async throws -> OnlineCatalogPage
}

private struct OnlineCatalogPageFailure: Error, Sendable {
    var message: String
}

@MainActor
final class OnlineCatalogBrowser: ObservableObject {
    @Published private(set) var items: [OnlineWallpaper] = []
    @Published private(set) var filter: OnlineWallpaperSourceFilter = .all
    @Published private(set) var query = ""
    @Published var searchText = ""
    @Published var selectedSource: OnlineWallpaperSource?
    @Published private(set) var loadingSources = Set<OnlineWallpaperSource>()
    @Published private(set) var errors: [OnlineWallpaperSource: String] = [:]
    @Published private(set) var hasCompletedSearch = false
    @Published private(set) var hasStartedSearch = false
    @Published private(set) var wasCancelled = false

    private let loader: any OnlineCatalogPageLoading
    private var cursors: [OnlineWallpaperSource: String] = [:]
    private var failedRequests: [OnlineWallpaperSource: OnlineCatalogPageRequest] = [:]
    private var activeRequests: [OnlineWallpaperSource: OnlineCatalogPageRequest] = [:]
    private var requestTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(loader: any OnlineCatalogPageLoading) {
        self.loader = loader
    }

    var hasMore: Bool { !cursors.isEmpty }
    var isLoading: Bool { !loadingSources.isEmpty }

    func search(query: String, filter: OnlineWallpaperSourceFilter) {
        generation &+= 1
        requestTask?.cancel()
        hasStartedSearch = true
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.filter = filter
        items = []
        cursors = [:]
        failedRequests = [:]
        activeRequests = Dictionary(uniqueKeysWithValues: filter.sources.map {
            ($0, OnlineCatalogPageRequest(source: $0, query: self.query, cursor: nil))
        })
        errors = [:]
        loadingSources = Set(filter.sources)
        hasCompletedSearch = false
        wasCancelled = false

        let currentGeneration = generation
        let requests = Array(activeRequests.values)
        requestTask = Task { @MainActor [weak self] in
            await self?.load(requests, generation: currentGeneration)
        }
    }

    func searchCurrentSelection() {
        search(query: searchText, filter: selectedSource.map(OnlineWallpaperSourceFilter.source) ?? .all)
    }

    func loadMore() {
        guard !isLoading, !cursors.isEmpty else { return }
        let currentGeneration = generation
        let requests = cursors.map { OnlineCatalogPageRequest(source: $0.key, query: query, cursor: $0.value) }
        activeRequests = Dictionary(uniqueKeysWithValues: requests.map { ($0.source, $0) })
        loadingSources = Set(requests.map(\.source))
        requestTask = Task { @MainActor [weak self] in
            await self?.load(requests, generation: currentGeneration)
        }
    }

    func retry(_ source: OnlineWallpaperSource) {
        guard !isLoading, let request = failedRequests[source] else { return }
        let currentGeneration = generation
        loadingSources.insert(source)
        activeRequests[source] = request
        requestTask = Task { @MainActor [weak self] in
            await self?.load([request], generation: currentGeneration)
        }
    }

    func cancel() {
        generation &+= 1
        requestTask?.cancel()
        requestTask = nil
        for (source, request) in activeRequests {
            failedRequests[source] = request
            errors[source] = "Search canceled before this collection finished."
        }
        activeRequests = [:]
        loadingSources = []
        wasCancelled = true
        if !hasCompletedSearch {
            hasCompletedSearch = true
        }
    }

    private func load(_ requests: [OnlineCatalogPageRequest], generation currentGeneration: UInt64) async {
        let loader = self.loader
        await withTaskGroup(of: (OnlineWallpaperSource, Result<OnlineCatalogPage, OnlineCatalogPageFailure>).self) { group in
            for request in requests {
                group.addTask {
                    do { return (request.source, .success(try await loader.load(request))) }
                    catch is CancellationError { return (request.source, .failure(OnlineCatalogPageFailure(message: "Cancelled"))) }
                    catch { return (request.source, .failure(OnlineCatalogPageFailure(message: error.localizedDescription))) }
                }
            }
            for await (source, result) in group {
                guard currentGeneration == generation else { continue }
                let request = requests.first { $0.source == source }
                loadingSources.remove(source)
                if activeRequests[source] == request { activeRequests.removeValue(forKey: source) }
                switch result {
                case .success(let page):
                    errors.removeValue(forKey: source)
                    failedRequests.removeValue(forKey: source)
                    if let nextCursor = page.nextCursor, !nextCursor.isEmpty { cursors[source] = nextCursor }
                    else { cursors.removeValue(forKey: source) }
                    if errors.isEmpty && failedRequests.isEmpty { wasCancelled = false }
                    var knownIDs = Set(items.map(\.id))
                    for item in page.items where knownIDs.insert(item.id).inserted { items.append(item) }
                case .failure(let failure):
                    guard failure.message != "Cancelled" else { continue }
                    errors[source] = failure.message
                    failedRequests[source] = request
                }
                hasCompletedSearch = true
            }
        }

        guard currentGeneration == generation else { return }
        for request in requests {
            let source = request.source
            if !loadingSources.contains(source) { continue }
            loadingSources.remove(source)
            if activeRequests[source] == request { activeRequests.removeValue(forKey: source) }
        }
        requestTask = nil
    }
}
