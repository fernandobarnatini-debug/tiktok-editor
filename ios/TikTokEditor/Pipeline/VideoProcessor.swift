import Foundation
import AVFoundation

struct ProcessingStats {
    let originalDuration: Double
    let finalDuration: Double
    let removedDuration: Double
    let segmentsKept: Int
    let deadSpacePercentage: Double
}

/// Full pipeline output. Carries everything the editor UI needs to visualize
/// what the algorithm did (waveform, ranges, transcript) in addition to the
/// user-facing stats and the exported mp4.
struct ProcessingResult {
    let stats: ProcessingStats
    let samples: [Float]             // Original 16 kHz mono Float32 PCM
    let sampleRate: Double           // = AudioExtractor.targetSampleRate
    let originalDuration: Double
    let segments: [Segment]          // Whisper transcription with word timings
    let initialRanges: [KeepRange]   // Raw VAD output (pre-Gemini)
    let keptRanges: [KeepRange]      // Final snapped ranges (what got exported)
    let sourceVideoURL: URL
    let outputVideoURL: URL
}

enum ProcessingStage: String {
    case loading = "Loading models…"
    case extractingAudio = "Extracting audio…"
    case transcribing = "Transcribing…"
    case detectingSpeech = "Detecting speech…"
    case detectingRetakes = "Finding retakes…"
    case cutting = "Cutting video…"
    case done = "Done"
}

/// Pipeline (reverted to the known-good state that produced 28.9 s output
/// on IMG_3517 — the "this is really good" checkpoint):
///
///   1. Extract audio (AVAssetReader → 16 kHz mono Float32 PCM)
///   2. Transcribe (WhisperKit) → segments with word-level timestamps
///   3. VAD (Silero) → speech ranges with 50 ms leading / 20 ms trailing pad
///   4. RangeLabeler → attach Whisper text to each VAD range
///   5. RetakeDetector → Gemini 2.5 Pro returns keep indices
///   6. detectSpeechEdges → energy-based endpoint detection using Whisper
///      word timings as hints (shrinks range edges to real speech onset/offset)
///   7. snapToQuietEdges (±3 ms) → zero-crossing polish for clean audio
///   8. VideoCutter → AVMutableComposition concat of keep ranges
final class VideoProcessor {

    private let transcriber: Transcriber
    private let vad: VAD

    init() throws {
        self.transcriber = Transcriber()
        self.vad = try VAD()
    }

    func process(
        videoURL: URL,
        outputURL: URL,
        onStage: @Sendable @escaping (ProcessingStage) -> Void
    ) async throws -> ProcessingResult {

        onStage(.loading)
        try await transcriber.ensureLoaded()

        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let originalDuration = CMTimeGetSeconds(duration)

        onStage(.extractingAudio)
        let audio = try await AudioExtractor.extract(from: videoURL)

        onStage(.transcribing)
        let segments = try await transcriber.transcribe(wavURL: audio.wavURL)

        onStage(.detectingSpeech)
        let vadRanges = try vad.detectSpeech(samples: audio.samples, totalDuration: originalDuration)

        let labeled = RangeLabeler.label(ranges: vadRanges, segments: segments)

        onStage(.detectingRetakes)
        let keep = await RetakeDetector.filter(labeled: labeled)

        // Tighten each kept range to its actual speech onset/offset using
        // audio RMS energy. Whisper word timings are used as hints for
        // where to look.
        let edged = Self.detectSpeechEdges(
            keep,
            segments: segments,
            samples: audio.samples,
            sampleRate: AudioExtractor.targetSampleRate
        )

        // Snap each edge to a near-zero-crossing for pop-free audio cuts.
        // Tiny ±3 ms window — doesn't materially change duration.
        let snapped = Self.snapToQuietEdges(
            edged,
            samples: audio.samples,
            sampleRate: AudioExtractor.targetSampleRate,
            windowMs: 3
        )

        NSLog("[Pipeline] duration=%.2fs keep=%d → edged=%d → snapped=%d",
              originalDuration, keep.count, edged.count, snapped.count)

        onStage(.cutting)
        try await VideoCutter.cut(source: videoURL, keep: snapped, to: outputURL)

        let finalAsset = AVURLAsset(url: outputURL)
        let finalDurationCM = try await finalAsset.load(.duration)
        let finalDuration = CMTimeGetSeconds(finalDurationCM)
        let removed = max(0, originalDuration - finalDuration)
        let pct = originalDuration > 0 ? (removed / originalDuration) * 100 : 0

        onStage(.done)

        let stats = ProcessingStats(
            originalDuration: round(originalDuration * 100) / 100,
            finalDuration: round(finalDuration * 100) / 100,
            removedDuration: round(removed * 100) / 100,
            segmentsKept: snapped.count,
            deadSpacePercentage: round(pct * 10) / 10
        )

        return ProcessingResult(
            stats: stats,
            samples: audio.samples,
            sampleRate: AudioExtractor.targetSampleRate,
            originalDuration: originalDuration,
            segments: segments,
            initialRanges: vadRanges,
            keptRanges: snapped,
            sourceVideoURL: videoURL,
            outputVideoURL: outputURL
        )
    }

    // MARK: - Edge detection + snap

    /// Energy-based endpoint detection. For each kept range, use Whisper's
    /// first/last word as a hint for where to look, then scan audio RMS
    /// energy to find the real speech onset/offset transition. Hard-cap
    /// the onset at first_word.start - 80 ms and offset at last_word.end
    /// + 100 ms so voiced fillers after the last word can't extend the range.
    static func detectSpeechEdges(
        _ ranges: [KeepRange],
        segments: [Segment],
        samples: [Float],
        sampleRate: Double
    ) -> [KeepRange] {
        let allWords: [Word] = segments.flatMap { $0.words }
        guard !allWords.isEmpty, !samples.isEmpty else { return ranges }

        let windowSamples = Int(0.010 * sampleRate)  // 10 ms
        guard windowSamples > 0 else { return ranges }
        let numWindows = samples.count / windowSamples
        guard numWindows > 0 else { return ranges }

        var rms = [Float](repeating: 0, count: numWindows)
        for i in 0..<numWindows {
            let lo = i * windowSamples
            let hi = min(lo + windowSamples, samples.count)
            var sumSq: Float = 0
            for j in lo..<hi { sumSq += samples[j] * samples[j] }
            rms[i] = sqrt(sumSq / Float(hi - lo))
        }

        // Adaptive threshold: 20th percentile silence floor × 5.
        // Conservative — only obvious articulated speech counts.
        let sorted = rms.sorted()
        let floorIdx = min(sorted.count - 1, sorted.count / 5)
        let silenceFloor = sorted[floorIdx]
        let threshold = max(silenceFloor * 5.0, 0.003)

        let paddingSec = 0.005
        let windowSec = Double(windowSamples) / sampleRate

        return ranges.map { r in
            let inside = allWords.filter { $0.start < r.end && $0.end > r.start }
            guard let first = inside.first, let last = inside.last else { return r }

            // ONSET: scan forward from first.start - 100 ms to first.start + 50 ms.
            let startHint = Int(first.start / windowSec)
            let startLo = max(0, startHint - Int(0.10 / windowSec))
            let startHi = min(numWindows - 1, startHint + Int(0.05 / windowSec))
            var onsetIdx = startLo
            for i in startLo...startHi {
                if rms[i] >= threshold {
                    onsetIdx = i
                    break
                }
                onsetIdx = startHi
            }
            let onsetTime = Double(onsetIdx) * windowSec - paddingSec
            let minStart = first.start - 0.08
            let newStart = max(r.start, max(minStart, onsetTime))

            // OFFSET: scan backward from last.end + 80 ms to last.end - 50 ms.
            let endHint = Int(last.end / windowSec)
            let endLo = max(0, endHint - Int(0.05 / windowSec))
            let endHi = min(numWindows - 1, endHint + Int(0.08 / windowSec))
            var offsetIdx = endHi
            for i in stride(from: endHi, through: endLo, by: -1) {
                if rms[i] >= threshold {
                    offsetIdx = i
                    break
                }
                offsetIdx = endLo
            }
            let offsetTime = Double(offsetIdx + 1) * windowSec + paddingSec
            let maxEnd = last.end + 0.10
            let newEnd = min(r.end, min(maxEnd, offsetTime))

            return newEnd > newStart + 0.05 ? KeepRange(start: newStart, end: newEnd) : r
        }
    }

    /// Removes sustained internal silence from each range by splitting the
    /// range at every low-energy stretch longer than `minSilenceDuration`.
    /// Solves the "10 s range with 5 s of real speech" problem caused by
    /// Whisper chaining word timings and absorbing silence into word
    /// durations. Adaptive threshold: global 20th-percentile RMS × 5.
    static func splitInternalSilence(
        _ ranges: [KeepRange],
        samples: [Float],
        sampleRate: Double,
        minSilenceDuration: Double = 0.5
    ) -> [KeepRange] {
        guard !ranges.isEmpty, !samples.isEmpty else { return ranges }

        let windowSamples = Int(0.010 * sampleRate)  // 10 ms
        guard windowSamples > 0 else { return ranges }
        let numWindows = samples.count / windowSamples
        guard numWindows > 0 else { return ranges }

        var rms = [Float](repeating: 0, count: numWindows)
        for i in 0..<numWindows {
            let lo = i * windowSamples
            let hi = min(lo + windowSamples, samples.count)
            var sumSq: Float = 0
            for j in lo..<hi { sumSq += samples[j] * samples[j] }
            rms[i] = sqrt(sumSq / Float(hi - lo))
        }

        let sorted = rms.sorted()
        let floorIdx = min(sorted.count - 1, sorted.count / 5)
        let silenceFloor = sorted[floorIdx]
        let threshold = max(silenceFloor * 5.0, 0.003)

        let windowSec = Double(windowSamples) / sampleRate
        let minSilenceWindows = Int(minSilenceDuration / windowSec)
        let trimPadSec = 0.04  // keep a small tail/lead on either side of the silence so cuts don't feel abrupt

        var result: [KeepRange] = []

        for r in ranges {
            let startWin = max(0, Int(r.start / windowSec))
            let endWin = min(numWindows - 1, Int(r.end / windowSec))
            guard startWin <= endWin else {
                result.append(r)
                continue
            }

            var currentStart = r.start
            var silenceRunStart: Int? = nil
            var didSplit = false

            for i in startWin...endWin {
                let isSilent = rms[i] < threshold
                if isSilent {
                    if silenceRunStart == nil { silenceRunStart = i }
                } else {
                    if let runStart = silenceRunStart {
                        let runLen = i - runStart
                        if runLen >= minSilenceWindows {
                            // Emit the portion before the silence
                            let silenceStartSec = Double(runStart) * windowSec
                            let silenceEndSec = Double(i) * windowSec
                            let chunkEnd = max(currentStart, silenceStartSec - trimPadSec)
                            if chunkEnd > currentStart + 0.05 {
                                result.append(KeepRange(start: currentStart, end: chunkEnd))
                            }
                            currentStart = min(r.end, silenceEndSec + trimPadSec)
                            didSplit = true
                        }
                        silenceRunStart = nil
                    }
                }
            }

            // Emit trailing portion
            if currentStart < r.end - 0.05 {
                result.append(KeepRange(start: currentStart, end: r.end))
            } else if !didSplit {
                // No split happened — return the range untouched
                result.append(r)
            }
        }

        NSLog("[splitInternalSilence] %d ranges → %d ranges (minSilence=%.2fs)",
              ranges.count, result.count, minSilenceDuration)
        return result
    }

    /// Snap each edge to the nearest near-zero-amplitude sample in a small
    /// window. Prevents audio pops at cut points. ±3 ms is enough to find a
    /// zero-crossing without materially changing duration.
    static func snapToQuietEdges(
        _ ranges: [KeepRange],
        samples: [Float],
        sampleRate: Double,
        windowMs: Double
    ) -> [KeepRange] {
        guard !ranges.isEmpty, !samples.isEmpty else { return ranges }
        let totalDuration = Double(samples.count) / sampleRate
        let halfWindow = Int(windowMs / 1000.0 * sampleRate)

        func snap(_ timeSec: Double) -> Double {
            let clamped = max(0, min(totalDuration, timeSec))
            let centerIdx = Int(clamped * sampleRate)
            let lo = max(0, centerIdx - halfWindow)
            let hi = min(samples.count - 1, centerIdx + halfWindow)
            guard lo < hi else { return clamped }
            var bestIdx = centerIdx
            var bestAbs: Float = abs(samples[min(max(centerIdx, 0), samples.count - 1)])
            for i in lo...hi {
                let v = abs(samples[i])
                if v < bestAbs { bestAbs = v; bestIdx = i }
            }
            return Double(bestIdx) / sampleRate
        }

        return ranges.map { r in
            let s = snap(r.start)
            let e = snap(r.end)
            return e > s ? KeepRange(start: s, end: e) : r
        }
    }
}
