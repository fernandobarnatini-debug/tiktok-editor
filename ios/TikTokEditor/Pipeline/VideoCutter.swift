import Foundation
import AVFoundation

enum VideoCutterError: Error {
    case noVideoTrack
    case noAudioTrack
    case exportFailed(String)
    case exporterInitFailed
}

/// Mirrors cutter.py — take keep_ranges, produce a single concatenated MP4.
/// Uses AVMutableComposition (native iOS) instead of FFmpeg concat.
enum VideoCutter {

    static func cut(source: URL, keep: [KeepRange], to output: URL) async throws {
        guard !keep.isEmpty else { throw VideoCutterError.exportFailed("no keep ranges") }

        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }

        let asset = AVURLAsset(url: source)

        // Force the asset to fully load before querying tracks. The async
        // loadTracks(withMediaType:) API is flaky on iOS 26 simulator.
        _ = try? await asset.load(.tracks, .duration)

        // Resolve video + audio tracks. Try the async API first, fall back to
        // the sync accessor which is more reliable on iOS 26 simulator.
        let asyncVideo = try? await asset.loadTracks(withMediaType: .video)
        let asyncAudio = try? await asset.loadTracks(withMediaType: .audio)

        let sourceVideo: AVAssetTrack
        if let v = asyncVideo?.first {
            sourceVideo = v
        } else if let v = asset.tracks(withMediaType: .video).first {
            sourceVideo = v
        } else {
            throw VideoCutterError.noVideoTrack
        }

        let sourceAudio: AVAssetTrack? = asyncAudio?.first ?? asset.tracks(withMediaType: .audio).first

        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw VideoCutterError.noVideoTrack }

        let compAudio: AVMutableCompositionTrack? = sourceAudio != nil
            ? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            : nil

        // Preserve original orientation / transform (TikTok videos are portrait).
        let transform = (try? await sourceVideo.load(.preferredTransform)) ?? sourceVideo.preferredTransform
        compVideo.preferredTransform = transform

        var cursor = CMTime.zero
        let timescale: CMTimeScale = 600

        for r in keep {
            let start = CMTime(seconds: r.start, preferredTimescale: timescale)
            let end = CMTime(seconds: r.end, preferredTimescale: timescale)
            let range = CMTimeRange(start: start, end: end)

            try compVideo.insertTimeRange(range, of: sourceVideo, at: cursor)
            if let compAudio, let sourceAudio {
                try compAudio.insertTimeRange(range, of: sourceAudio, at: cursor)
            }
            cursor = CMTimeAdd(cursor, range.duration)
        }

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else { throw VideoCutterError.exporterInitFailed }

        exporter.outputURL = output
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true

        await exporter.export()
        if exporter.status != .completed {
            throw VideoCutterError.exportFailed(exporter.error?.localizedDescription ?? "unknown")
        }
    }
}
