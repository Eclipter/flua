import AVKit
import SwiftUI

@MainActor
private final class OnlineDownloadsViewState: ObservableObject {
    @Published var previewing: String?
}

@MainActor
final class OnlineDownloadCoordinator: ObservableObject {
    enum State: Equatable {
        case ready
        case downloading(Double?)
        case importing
        case cancelling
        case downloaded
        case failed(String)
    }

    @Published private(set) var states: [String: State] = [:]
    private var transferTasks: [String: Task<Void, Never>] = [:]
    private var importTasks: [String: Task<Void, Never>] = [:]
    private var cancelled = Set<String>()

    func state(for item: OnlineWallpaper, library: Library) -> State {
        if isDownloaded(item, library: library) { return .downloaded }
        let current = states[item.id] ?? .ready
        return current == .downloaded ? .ready : current
    }

    func isDownloaded(_ item: OnlineWallpaper, library: Library) -> Bool {
        library.state.wallpapers.contains { wallpaper in
            guard wallpaper.sourceAttribution?.catalogItemID == item.catalogItemID,
                  let file = library.disk.url(for: wallpaper) else { return false }
            return (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    func start(_ item: OnlineWallpaper, library: Library) {
        guard transferTasks[item.id] == nil, importTasks[item.id] == nil,
              !isDownloaded(item, library: library) else { return }
        cancelled.remove(item.id)
        states[item.id] = .downloading(nil)
        transferTasks[item.id] = Task { @MainActor [weak self, weak library] in
            guard let self, let library else { return }
            let downloader = OnlineWallpaperDownload()
            var downloadedFile: URL?
            do {
                let temporaryFile = try await downloader.download(item) { [weak self] progress in
                    self?.states[item.id] = .downloading(progress)
                }
                downloadedFile = temporaryFile
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: temporaryFile)
                    downloadedFile = nil
                    self.transferTasks.removeValue(forKey: item.id)
                    self.cancelled.remove(item.id)
                    self.states[item.id] = .ready
                    return
                }
                self.states[item.id] = .importing
                self.transferTasks.removeValue(forKey: item.id)
                let importTask = library.importMedia([temporaryFile], sourceAttribution: item.attribution,
                    titleOverride: item.title) { [weak self] ids, error in
                        try? FileManager.default.removeItem(at: temporaryFile)
                        guard let self else { return }
                        self.importTasks.removeValue(forKey: item.id)
                        if self.cancelled.contains(item.id) { self.states[item.id] = .ready }
                        else if !ids.isEmpty || self.isDownloaded(item, library: library) {
                            self.states[item.id] = .downloaded
                        }
                        else { self.states[item.id] = .failed(error ?? "The wallpaper could not be added.") }
                    }
                if let importTask {
                    self.importTasks[item.id] = importTask
                    downloadedFile = nil
                }
                else {
                    try? FileManager.default.removeItem(at: temporaryFile)
                    downloadedFile = nil
                    self.states[item.id] = self.isDownloaded(item, library: library)
                        ? .downloaded : .failed("This wallpaper is already in your library.")
                }
            } catch {
                if let downloadedFile { try? FileManager.default.removeItem(at: downloadedFile) }
                self.transferTasks.removeValue(forKey: item.id)
                self.states[item.id] = self.cancelled.contains(item.id) ? .ready : .failed(error.localizedDescription)
                self.cancelled.remove(item.id)
            }
        }
    }

    func cancel(_ item: OnlineWallpaper) {
        cancelled.insert(item.id)
        if let task = transferTasks[item.id] {
            states[item.id] = .cancelling
            task.cancel()
        } else if let task = importTasks[item.id] {
            states[item.id] = .cancelling
            task.cancel()
        }
    }
}

struct OnlineDownloadsView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var downloads: OnlineDownloadCoordinator
    @ObservedObject var browser: OnlineCatalogBrowser
    @StateObject private var viewState = OnlineDownloadsViewState()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Browse licensed videos and add them directly to your library.")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                TextField("Search videos", text: $browser.searchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { runSearch() }
                Picker("Source", selection: $browser.selectedSource) {
                    Text("All sources").tag(OnlineWallpaperSource?.none)
                    ForEach(OnlineWallpaperSource.allCases) { source in
                        Text(source.title).tag(Optional(source))
                    }
                }
                .frame(width: 230)
                Button("Search", action: runSearch).fluaProminentButton()
                if browser.isLoading {
                    Button("Cancel") { browser.cancel() }.fluaGlassButton()
                }
            }
            if browser.isLoading && browser.items.isEmpty {
                ProgressView("Loading source collections…")
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else if browser.wasCancelled && browser.items.isEmpty {
                ContentUnavailableView("Search Canceled", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else if browser.hasCompletedSearch && browser.items.isEmpty && browser.errors.isEmpty && browser.hasMore {
                ContentUnavailableView("No Videos On This Page", systemImage: "film",
                                       description: Text("Continue loading the source collections to find eligible videos."))
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else if browser.hasCompletedSearch && browser.items.isEmpty && browser.errors.isEmpty {
                ContentUnavailableView("No Videos Found", systemImage: "magnifyingglass",
                                       description: Text("Try another search or source."))
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else if !browser.items.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16, alignment: .top)], spacing: 16) {
                    ForEach(browser.items) { item in itemCard(item) }
                }
            }
            if browser.wasCancelled && !browser.items.isEmpty {
                Label("Search canceled. Some source results may be missing.", systemImage: "xmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if browser.isLoading && !browser.items.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading more source results…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !browser.errors.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Some Sources Need Attention").font(.headline)
                    ForEach(OnlineWallpaperSource.allCases.filter { browser.errors[$0] != nil }) { source in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(source.title).font(.callout.weight(.medium))
                                Text(browser.errors[source] ?? "Unable to load this collection.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Retry") { browser.retry(source) }
                                .fluaGlassButton().disabled(browser.isLoading)
                        }
                    }
                }
                .padding(14)
                .fluaGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            if browser.hasMore {
                HStack {
                    Spacer()
                    if browser.isLoading { ProgressView().controlSize(.small) }
                    Button("Load More") { browser.loadMore() }
                        .fluaGlassButton().disabled(browser.isLoading)
                    Spacer()
                }
                .padding(.top, 4)
            }
            if browser.hasCompletedSearch && browser.items.isEmpty && !browser.errors.isEmpty {
                HStack {
                    Spacer()
                    Button("Retry All") { runSearch() }.fluaGlassButton()
                    Spacer()
                }
            }
        }
        .padding(24)
        .onAppear { if !browser.hasStartedSearch { runSearch() } }
        .onChange(of: browser.selectedSource) { _, _ in runSearch() }
        .onDisappear { viewState.previewing = nil }
    }

    private func runSearch() {
        browser.searchCurrentSelection()
    }

    private func itemCard(_ item: OnlineWallpaper) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if viewState.previewing == item.id {
                OnlinePreviewFrame {
                    OnlineVideoPreview(item: item)
                }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        Button { viewState.previewing = nil } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel("Close preview")
                        .fluaGlassButton()
                        .padding(8)
                    }
            } else {
                OnlinePreviewFrame {
                    AsyncImage(url: item.thumbnailURL) { phase in
                        Group {
                            if let image = phase.image {
                                image.resizable().scaledToFill()
                            } else {
                                Rectangle().fill(Color(nsColor: .quaternarySystemFill))
                                    .overlay(Image(systemName: phase.error == nil ? "arrow.clockwise" : "photo")
                                        .foregroundStyle(.secondary))
                            }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if item.previewUnavailableReason == nil {
                        Button { viewState.previewing = item.id } label: { Label("Preview", systemImage: "play.fill") }
                            .fluaGlassButton().padding(8)
                    } else {
                        Text("Still image only").font(.caption2).padding(6)
                            .background(.regularMaterial, in: Capsule()).padding(8)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.headline).lineLimit(2)
                if let summary = item.summary, !summary.isEmpty {
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if let reason = item.previewUnavailableReason {
                    Text(reason).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                if let notice = item.modificationNotice {
                    Text(notice).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 148, alignment: .topLeading).clipped()
            downloadControl(item)
                .frame(maxWidth: .infinity).frame(height: 64, alignment: .center)
            HStack(alignment: .firstTextBaseline) {
                Link("Source", destination: item.sourceURL).font(.caption).fixedSize()
                Spacer()
                Link("License", destination: item.licenseURL).font(.caption).fixedSize()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .fluaGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func downloadControl(_ item: OnlineWallpaper) -> some View {
        if case .unavailable(let reason) = item.downloadRoute {
            VStack(alignment: .trailing, spacing: 4) {
                Label("Unavailable", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
                Text(reason).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        } else {
            downloadStateControl(item)
        }
    }

    @ViewBuilder
    private func downloadStateControl(_ item: OnlineWallpaper) -> some View {
        switch downloads.state(for: item, library: library) {
        case .ready:
            Button("Download") { downloads.start(item, library: library) }.fluaProminentButton()
        case .downloading(let progress):
            HStack(spacing: 8) {
                if let progress { ProgressView(value: progress).frame(width: 80) }
                else { ProgressView().controlSize(.small) }
                Button("Cancel") { downloads.cancel(item) }.fluaGlassButton()
            }
        case .importing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Adding…").font(.caption)
                Button("Cancel") { downloads.cancel(item) }.fluaGlassButton()
            }
        case .cancelling:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Cancelling…").font(.caption)
            }
        case .downloaded:
            Label("Downloaded", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            VStack(alignment: .trailing, spacing: 4) {
                Button("Retry") { downloads.start(item, library: library) }.fluaGlassButton()
                Text(message).font(.caption2).foregroundStyle(.red).lineLimit(2)
            }
        }
    }
}

enum OnlinePreviewFrameLayout {
    static let aspectRatio: CGFloat = 16 / 9
}

struct OnlinePreviewFrame<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            content
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
        }
        .aspectRatio(OnlinePreviewFrameLayout.aspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
    }
}

private struct OnlineVideoPreview: View {
    let item: OnlineWallpaper
    @StateObject private var state = OnlineVideoPreviewState()

    var body: some View {
        Group {
            if let message = state.error {
                ContentUnavailableView("Preview Unavailable", systemImage: "video.slash", description: Text(message))
            } else {
                ZStack {
                    if let player = state.player { EditorPlayer(player: player, aspectFill: true) }
                    else { Rectangle().fill(Color.black.opacity(0.8)) }
                    if state.isLoading || state.isBuffering {
                        Rectangle().fill(Color.black.opacity(0.55)).overlay {
                            ProgressView("Loading preview…").controlSize(.small)
                        }
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if state.canReplay {
                Button("Replay preview") { state.replay() }
                    .fluaGlassButton().padding(10)
            }
        }
        .task {
            await state.play(item: item)
        }
        .onDisappear {
            state.stop()
        }
    }
}

@MainActor
private final class OnlineVideoPreviewState: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var error: String?
    @Published private(set) var canReplay = false
    @Published private(set) var isLoading = true
    @Published private(set) var isBuffering = false
    private var itemObservation: NSKeyValueObservation?
    private var playbackObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var previewTimeoutTask: Task<Void, Never>?
    private var previewDirectoryURL: URL?
    private var stopped = false
    private var previewItem: OnlineWallpaper?

    func play(item wallpaper: OnlineWallpaper) async {
        guard !stopped else { return }
        previewItem = wallpaper
        var stagedPreview: OnlineRangePreviewArtifact?
        do {
            let url: URL
            switch wallpaper.downloadRoute {
            case .cuteStockFootage where wallpaper.previewMode != .direct:
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpCookieStorage = nil
                configuration.httpShouldSetCookies = false
                configuration.urlCredentialStorage = nil
                url = try await OnlineWallpaperDownloadURLResolver.resolve(wallpaper.downloadRoute,
                                                                            configuration: configuration)
            case .cuteStockFootage:
                url = wallpaper.previewURL
            case .direct:
                url = wallpaper.previewURL
            case .unavailable:
                throw OnlineWallpaperError.previewUnavailable
            }
            try Task.checkCancellation()
            guard !stopped else { return }
            let playerItem: AVPlayerItem
            let maximumDuration: Double?
            var waitsForReadyToPlay = false
            if case .boundedRange(let maximumBytes, let duration) = wallpaper.previewMode {
                let artifact = try await OnlineRangePreviewBuilder.build(
                    sourceURL: url, allowedHosts: wallpaper.downloadRoute.allowedRedirectHosts,
                    maximumBytes: maximumBytes, maximumDuration: duration)
                stagedPreview = artifact
                try Task.checkCancellation()
                guard !stopped else {
                    try? FileManager.default.removeItem(at: artifact.directoryURL)
                    stagedPreview = nil
                    return
                }
                previewDirectoryURL = artifact.directoryURL
                stagedPreview = nil
                playerItem = AVPlayerItem(url: artifact.videoURL)
                playerItem.forwardPlaybackEndTime = CMTime(seconds: duration, preferredTimescale: 600)
                maximumDuration = duration
            } else {
                playerItem = AVPlayerItem(url: url)
                if url.pathExtension.lowercased() == "m3u8" {
                    playerItem.preferredMaximumResolution = CGSize(width: 640, height: 360)
                    playerItem.preferredPeakBitRate = 800_000
                    playerItem.preferredForwardBufferDuration = 1
                    maximumDuration = 2
                    waitsForReadyToPlay = true
                } else {
                    maximumDuration = nil
                }
            }
            let player = AVPlayer(playerItem: playerItem)
            player.isMuted = true
            self.player = player
            if maximumDuration != nil { player.automaticallyWaitsToMinimizeStalling = false }
            itemObservation = playerItem.observe(\.status, options: [.initial, .new]) { [weak self, weak player] observedItem, _ in
                Task { @MainActor in
                    guard let self, let player, !self.stopped,
                          self.player === player, player.currentItem === observedItem else { return }
                    switch observedItem.status {
                    case .readyToPlay:
                        self.isLoading = false
                        if waitsForReadyToPlay { player.play() }
                    case .failed:
                        self.isLoading = false
                        self.error = observedItem.error?.localizedDescription ?? "This preview is unavailable."
                    default:
                        break
                    }
                }
            }
            playbackObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                }
            }
            if let maximumDuration {
                observePreviewLimit(maximumDuration, player: player)
                endObserver = NotificationCenter.default.addObserver(
                    forName: AVPlayerItem.didPlayToEndTimeNotification, object: playerItem, queue: .main
                ) { [weak self] _ in Task { @MainActor in self?.finishBoundedPreview() } }
                previewTimeoutTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    guard let self, !self.stopped, !self.canReplay,
                          self.isLoading || self.isBuffering else { return }
                    self.errorMessage(OnlineWallpaperError.previewUnavailable)
                    self.player?.pause()
                    self.player?.replaceCurrentItem(with: nil)
                }
            }
            if !waitsForReadyToPlay { player.play() }
        } catch is CancellationError {
            if let stagedPreview { try? FileManager.default.removeItem(at: stagedPreview.directoryURL) }
            return
        } catch {
            if let stagedPreview { try? FileManager.default.removeItem(at: stagedPreview.directoryURL) }
            errorMessage(error)
        }
    }

    func stop() {
        stopped = true
        let currentPlayer = player
        currentPlayer?.pause()
        currentPlayer?.replaceCurrentItem(with: nil)
        if let timeObserver, let currentPlayer { currentPlayer.removeTimeObserver(timeObserver) }
        player = nil
        error = nil
        canReplay = false
        isLoading = false
        isBuffering = false
        itemObservation = nil
        playbackObservation = nil
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        previewTimeoutTask?.cancel()
        previewTimeoutTask = nil
        if let previewDirectoryURL { try? FileManager.default.removeItem(at: previewDirectoryURL) }
        previewDirectoryURL = nil
        previewItem = nil
    }

    func replay() {
        guard canReplay, let previewItem else { return }
        if previewDirectoryURL != nil, let player {
            canReplay = false
            isLoading = false
            isBuffering = false
            player.seek(to: .zero) { [weak player] _ in
                Task { @MainActor in player?.play() }
            }
            return
        }
        let currentPlayer = player
        currentPlayer?.replaceCurrentItem(with: nil)
        itemObservation = nil
        playbackObservation = nil
        if let timeObserver, let currentPlayer { currentPlayer.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        previewTimeoutTask?.cancel()
        previewTimeoutTask = nil
        player = nil
        error = nil
        isLoading = true
        isBuffering = false
        canReplay = false
        Task { await play(item: previewItem) }
    }

    private func observePreviewLimit(_ duration: Double, player: AVPlayer) {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
                                                      queue: .main) { [weak self] time in
            guard time.seconds >= duration, player.rate != 0 else { return }
            Task { @MainActor in
                guard let self, !self.canReplay else { return }
                self.finishBoundedPreview()
            }
        }
    }

    private func finishBoundedPreview() {
        guard !canReplay, let player else { return }
        player.pause()
        previewTimeoutTask?.cancel()
        previewTimeoutTask = nil
        canReplay = true
        isLoading = false
        isBuffering = false
    }

    private func errorMessage(_ error: Error) {
        if let previewDirectoryURL { try? FileManager.default.removeItem(at: previewDirectoryURL) }
        previewDirectoryURL = nil
        isLoading = false
        self.error = error.localizedDescription
    }
}
