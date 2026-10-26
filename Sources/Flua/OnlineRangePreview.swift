import AVFoundation
import Foundation

struct OnlinePreviewByteSpan: Equatable, Comparable, Sendable {
    let start: Int64
    let endExclusive: Int64

    init(start: Int64, endExclusive: Int64) throws {
        guard start >= 0, endExclusive > start else { throw OnlineWallpaperError.previewUnavailable }
        self.start = start
        self.endExclusive = endExclusive
    }

    private init(validStart start: Int64, endExclusive: Int64) {
        self.start = start
        self.endExclusive = endExclusive
    }

    var count: Int64 { endExclusive - start }

    static func < (lhs: OnlinePreviewByteSpan, rhs: OnlinePreviewByteSpan) -> Bool {
        lhs.start == rhs.start ? lhs.endExclusive < rhs.endExclusive : lhs.start < rhs.start
    }

    static func merged(_ spans: [OnlinePreviewByteSpan]) -> [OnlinePreviewByteSpan] {
        let sorted = spans.sorted()
        var result: [OnlinePreviewByteSpan] = []
        for span in sorted {
            guard let last = result.last else {
                result.append(span)
                continue
            }
            if span.start <= last.endExclusive {
                result[result.count - 1] = OnlinePreviewByteSpan(
                    validStart: last.start, endExclusive: max(last.endExclusive, span.endExclusive))
            } else {
                result.append(span)
            }
        }
        return result
    }

    static func uncovered(_ needed: [OnlinePreviewByteSpan], by covered: [OnlinePreviewByteSpan]) throws -> [OnlinePreviewByteSpan] {
        let coverage = merged(covered)
        var missing: [OnlinePreviewByteSpan] = []
        for span in merged(needed) {
            var cursor = span.start
            for existing in coverage where existing.endExclusive > cursor && existing.start < span.endExclusive {
                if existing.start > cursor {
                    missing.append(try OnlinePreviewByteSpan(start: cursor, endExclusive: min(existing.start, span.endExclusive)))
                }
                cursor = max(cursor, existing.endExclusive)
                if cursor >= span.endExclusive { break }
            }
            if cursor < span.endExclusive {
                missing.append(try OnlinePreviewByteSpan(start: cursor, endExclusive: span.endExclusive))
            }
        }
        return missing
    }
}

struct OnlineRangePreviewArtifact: Sendable {
    let videoURL: URL
    let directoryURL: URL
}

@MainActor
enum OnlineRangePreviewBuilder {
    private static let prefixBytes: Int64 = 8 * 1024 * 1024
    private static let tailBytes: Int64 = 2 * 1024 * 1024
    private static let maximumSourceLength: Int64 = 1_000_000_000

    static func build(sourceURL: URL, allowedHosts: Set<String>, maximumBytes: Int64,
                      maximumDuration: Double) async throws -> OnlineRangePreviewArtifact {
        guard (1_024 * 1_024...12_000_000).contains(maximumBytes),
              (0.25...5).contains(maximumDuration) else {
            throw OnlineWallpaperError.previewUnavailable
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FluaOnlinePreview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let output = try await makeExcerpt(sourceURL: sourceURL, allowedHosts: allowedHosts,
                                               maximumBytes: maximumBytes, maximumDuration: maximumDuration,
                                               in: directory)
            return OnlineRangePreviewArtifact(videoURL: output, directoryURL: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func makeExcerpt(sourceURL: URL, allowedHosts: Set<String>, maximumBytes: Int64,
                                    maximumDuration: Double, in directory: URL) async throws -> URL {
        let input = directory.appendingPathComponent("source.mp4")
        let output = directory.appendingPathComponent("preview.mp4")
        guard FileManager.default.createFile(atPath: input.path, contents: nil) else {
            throw OnlineWallpaperError.previewUnavailable
        }
        let file = try FileHandle(forWritingTo: input)
        defer { try? file.close() }

        var covered: [OnlinePreviewByteSpan] = []
        var transferred: Int64 = 0
        let initial = try await fetch(start: 0, endExclusive: 2, sourceURL: sourceURL,
                                      totalLength: nil, allowedHosts: allowedHosts, remaining: maximumBytes)
        let totalLength = initial.totalLength
        guard totalLength > 2, totalLength <= maximumSourceLength else {
            throw OnlineWallpaperError.previewUnavailable
        }
        try file.truncate(atOffset: UInt64(totalLength))
        try write(initial.data, at: 0, to: file)
        covered.append(try OnlinePreviewByteSpan(start: 0, endExclusive: 2))
        transferred += 2

        let prefixEnd = min(totalLength, prefixBytes)
        if prefixEnd > 2 {
            let prefix = try await fetch(start: 2, endExclusive: prefixEnd, sourceURL: sourceURL,
                                        totalLength: totalLength, allowedHosts: allowedHosts,
                                        remaining: maximumBytes - transferred)
            try write(prefix.data, at: 2, to: file)
            covered.append(try OnlinePreviewByteSpan(start: 2, endExclusive: prefixEnd))
            transferred += Int64(prefix.data.count)
        }

        if totalLength > prefixEnd {
            let tailStart = max(prefixEnd, totalLength - tailBytes)
            if tailStart < totalLength {
                let tail = try await fetch(start: tailStart, endExclusive: totalLength, sourceURL: sourceURL,
                                           totalLength: totalLength, allowedHosts: allowedHosts,
                                           remaining: maximumBytes - transferred)
                try write(tail.data, at: tailStart, to: file)
                covered.append(try OnlinePreviewByteSpan(start: tailStart, endExclusive: totalLength))
                transferred += Int64(tail.data.count)
            }
        }

        try Task.checkCancellation()
        let asset = AVURLAsset(url: input, options: [AVURLAssetReferenceRestrictionsKey:
                                                         AVAssetReferenceRestrictions.forbidAll.rawValue])
        let sourceDuration = try await asset.load(.duration)
        guard sourceDuration.isNumeric, sourceDuration.seconds.isFinite, sourceDuration.seconds > 0,
              let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw OnlineWallpaperError.previewUnavailable
        }
        let sampleSpans = try await sampleSpans(in: asset, track: videoTrack, sourceURL: input,
                                                totalLength: totalLength, maximumDuration: maximumDuration)
        let missing = try OnlinePreviewByteSpan.uncovered(sampleSpans, by: covered)
        for span in missing {
            try Task.checkCancellation()
            guard span.count <= maximumBytes - transferred else { throw OnlineWallpaperError.previewUnavailable }
            let range = try await fetch(start: span.start, endExclusive: span.endExclusive,
                                        sourceURL: sourceURL, totalLength: totalLength,
                                        allowedHosts: allowedHosts, remaining: maximumBytes - transferred)
            try write(range.data, at: span.start, to: file)
            covered.append(span)
            transferred += Int64(range.data.count)
        }
        try file.synchronize()
        try file.close()

        let duration = min(maximumDuration, sourceDuration.seconds)
        let composition = AVMutableComposition()
        guard let destinationTrack = composition.addMutableTrack(withMediaType: .video,
                                                                  preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw OnlineWallpaperError.previewUnavailable
        }
        destinationTrack.preferredTransform = try await videoTrack.load(.preferredTransform)
        try destinationTrack.insertTimeRange(CMTimeRange(start: .zero,
                                                         duration: CMTime(seconds: duration, preferredTimescale: 600)),
                                             of: videoTrack, at: .zero)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetMediumQuality) else {
            throw OnlineWallpaperError.previewUnavailable
        }
        try await exporter.export(to: output, as: .mp4)
        try Task.checkCancellation()
        let values = try output.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0,
              Int64(size) <= maximumBytes else {
            throw OnlineWallpaperError.previewUnavailable
        }
        return output
    }

    private static func sampleSpans(in asset: AVAsset, track: AVAssetTrack, sourceURL: URL,
                                    totalLength: Int64, maximumDuration: Double) async throws -> [OnlinePreviewByteSpan] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderSampleReferenceOutput(track: track)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: maximumDuration, preferredTimescale: 600))
        let provider = reader.outputProvider(for: output)
        try reader.start()
        let inputPath = sourceURL.standardizedFileURL
        var spans: [OnlinePreviewByteSpan] = []
        while reader.status == .reading, let readySample = try await provider.next() {
            try Task.checkCancellation()
            guard readySample.totalSampleSize > 0 else { continue }
            try readySample.withUnsafeSampleBuffer { sample in
                let size = Int64(CMSampleBufferGetTotalSampleSize(sample))
                var attachmentMode = CMAttachmentMode(0)
                guard let offsetNumber = CMGetAttachment(sample,
                                                          key: kCMSampleBufferAttachmentKey_SampleReferenceByteOffset,
                                                          attachmentModeOut: &attachmentMode) as? NSNumber,
                      let referenceValue = CMGetAttachment(sample,
                                                           key: kCMSampleBufferAttachmentKey_SampleReferenceURL,
                                                           attachmentModeOut: &attachmentMode) else {
                    throw OnlineWallpaperError.previewUnavailable
                }
                let referenceURL: URL?
                if let value = referenceValue as? URL { referenceURL = value }
                else if let value = referenceValue as? String { referenceURL = URL(string: value) }
                else { referenceURL = nil }
                guard referenceURL?.standardizedFileURL == inputPath else {
                    throw OnlineWallpaperError.previewUnavailable
                }
                let offset = offsetNumber.int64Value
                let (end, overflow) = offset.addingReportingOverflow(size)
                guard !overflow, offset >= 0, end <= totalLength else {
                    throw OnlineWallpaperError.previewUnavailable
                }
                spans.append(try OnlinePreviewByteSpan(start: offset, endExclusive: end))
            }
        }
        guard reader.status == .completed, !spans.isEmpty else {
            throw reader.error ?? OnlineWallpaperError.previewUnavailable
        }
        return OnlinePreviewByteSpan.merged(spans)
    }

    private static func fetch(start: Int64, endExclusive: Int64, sourceURL: URL, totalLength: Int64?,
                              allowedHosts: Set<String>, remaining: Int64) async throws -> (data: Data, totalLength: Int64) {
        let (end, overflow) = endExclusive.subtractingReportingOverflow(1)
        let (length, lengthOverflow) = endExclusive.subtractingReportingOverflow(start)
        guard !overflow, !lengthOverflow, start >= 0, length > 0,
              length <= remaining, length <= Int64(Int.max) else {
            throw OnlineWallpaperError.previewUnavailable
        }
        let client = BoundedHTTPSDataRequest(maximumBytes: Int(length), allowedHosts: allowedHosts,
                                             byteRange: start...end)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let (data, response) = try await client.fetchResponse(sourceURL, configuration: configuration)
        guard let contentRange = HTTPByteContentRange.parse(response.value(forHTTPHeaderField: "Content-Range")),
              contentRange.start == start, contentRange.end == end,
              totalLength == nil || contentRange.total == totalLength,
              Int64(data.count) == length else {
            throw OnlineWallpaperError.previewUnavailable
        }
        return (data, contentRange.total)
    }

    private static func write(_ data: Data, at offset: Int64, to file: FileHandle) throws {
        try file.seek(toOffset: UInt64(offset))
        try file.write(contentsOf: data)
    }
}
