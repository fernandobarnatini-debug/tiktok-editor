import Foundation
import AVFoundation

enum AudioExtractorError: Error {
    case noAudioTrack
    case readerFailed(String)
    case writeFailed(String)
}

/// Extracts mono 16 kHz Float32 PCM from a video file.
/// Returns both a file URL (WAV) that WhisperKit can load and the raw sample array
/// for the VAD. Mirrors the `ffmpeg -ar 16000 -ac 1` step in Python.
enum AudioExtractor {

    static let targetSampleRate: Double = 16_000

    struct Output {
        let wavURL: URL
        let samples: [Float]
    }

    static func extract(from videoURL: URL) async throws -> Output {
        let asset = AVURLAsset(url: videoURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = audioTracks.first else {
            throw AudioExtractorError.noAudioTrack
        }

        // Diagnostic: log any mismatch between video duration and audio
        // track's placement in the composition. A non-zero timeRange.start
        // means Whisper word times (relative to the WAV) will be shifted
        // from AVPlayer video times by that offset.
        let videoDur = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? -1
        let trackRange = (try? await track.load(.timeRange)) ?? CMTimeRange.zero
        let trackStart = CMTimeGetSeconds(trackRange.start)
        let trackDur = CMTimeGetSeconds(trackRange.duration)
        NSLog("[AudioExtractor] videoDuration=%.3fs audioTrack.start=%.3fs audioTrack.duration=%.3fs",
              videoDur, trackStart, trackDur)

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)

        guard reader.startReading() else {
            throw AudioExtractorError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }

        var samples: [Float] = []
        samples.reserveCapacity(Int(targetSampleRate * 60))

        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
            if let ptr = dataPointer {
                let floatCount = length / MemoryLayout<Float>.size
                ptr.withMemoryRebound(to: Float.self, capacity: floatCount) { floatPtr in
                    samples.append(contentsOf: UnsafeBufferPointer(start: floatPtr, count: floatCount))
                }
            }
            CMSampleBufferInvalidate(buffer)
        }

        if reader.status == .failed {
            throw AudioExtractorError.readerFailed(reader.error?.localizedDescription ?? "reader failed")
        }

        // Diagnostic: find the first sample with meaningful energy so we can
        // compare with Whisper's first reported word timestamp. If Whisper
        // says "before" at 4.44s but energy starts at 2.2s, the timestamps
        // are drifting from the real audio.
        let energyThreshold: Float = 0.01
        let firstSoundIdx = samples.firstIndex { abs($0) > energyThreshold } ?? -1
        let firstSoundSec = firstSoundIdx >= 0 ? Double(firstSoundIdx) / targetSampleRate : -1
        NSLog("[AudioExtractor] extracted samples=%d (%.3fs @ %.0fHz), firstNonSilentSample=%.3fs",
              samples.count, Double(samples.count) / targetSampleRate, targetSampleRate, firstSoundSec)

        let wavURL = try writeWav(samples: samples, sampleRate: Int(targetSampleRate))
        return Output(wavURL: wavURL, samples: samples)
    }

    /// Writes Float32 PCM samples to a 16-bit mono WAV file WhisperKit can load.
    private static func writeWav(samples: [Float], sampleRate: Int) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tiktok_audio_\(UUID().uuidString).wav")

        var data = Data()
        let byteRate = sampleRate * 2
        let dataSize = samples.count * 2

        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }

        data.append("RIFF".data(using: .ascii)!)
        appendLE(UInt32(36 + dataSize))
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        appendLE(UInt32(16))
        appendLE(UInt16(1))
        appendLE(UInt16(1))
        appendLE(UInt32(sampleRate))
        appendLE(UInt32(byteRate))
        appendLE(UInt16(2))
        appendLE(UInt16(16))
        data.append("data".data(using: .ascii)!)
        appendLE(UInt32(dataSize))

        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16 = Int16(clamped * Float(Int16.max))
            appendLE(int16)
        }

        try data.write(to: url, options: .atomic)
        return url
    }
}
