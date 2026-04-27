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
    let keptRanges: [KeepRange]      // Final snapped ranges (what got exported)
    let sourceVideoURL: URL
    let outputVideoURL: URL
}

enum ProcessingStage: String {
    case loading = "Loading models…"
    case extractingAudio = "Extracting audio…"
    case transcribing = "Transcribing…"
    case detectingSpeech = "Detecting speech…"
    case llmRetakeCheck = "Checking retakes…"
    case cutting = "Cutting video…"
    case done = "Done"
}

/// Pipeline (silence-only, V1 — no semantic/retake decisions):
///
///   1. Extract audio (AVAssetReader → 16 kHz mono Float32 PCM)
///   2. Transcribe (WhisperKit) → segments with word-level timestamps
///      (used for the editor's transcript view and edge-detection hints only —
///      NOT for deciding which ranges to cut)
///   3. VAD (Silero) → speech ranges with 50 ms leading / 20 ms trailing pad
///   4. Keep every VAD range (no Gemini, no retake detection)
///   5. detectSpeechEdges → energy-based endpoint tightening
///   6. snapToQuietEdges (±3 ms) → zero-crossing polish for clean audio
///   7. VideoCutter → AVMutableComposition concat of keep ranges
///
/// Retakes / fumbles survive into the output. The editor (EditorView.swift)
/// is how users remove them manually — drag the edges of kept ranges to
/// clip anything they don't want, then re-export.
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

        // Attach Whisper transcript to each VAD range so RetakeFilter can
        // compare text between adjacent ranges.
        let allWords = segments.flatMap { $0.words }
        let labeled: [LabeledRange] = vadRanges.map { r in
            let text = allWords
                .filter { $0.start < r.end && $0.end > r.start }
                .map { $0.word }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return LabeledRange(start: r.start, end: r.end, text: text)
        }

        // When creators speak fast (<90 ms pause between takes) VAD fuses
        // multiple takes into one range. Split those ranges at Whisper's
        // sentence-boundary punctuation so RetakeFilter can see each take.
        let sentences = Self.splitOnPunctuation(labeled, allWords: allWords)
        NSLog("[Pipeline] punctuation split: %d → %d ranges", labeled.count, sentences.count)

        // Retake detection: drop back-to-back duplicate lines, keeping the last.
        // Text similarity first; Claude Haiku tiebreaker on borderline pairs.
        // See RetakeFilter.swift + RetakeLLM.swift.
        onStage(.llmRetakeCheck)
        let filtered = await RetakeFilter.filter(sentences)

        // Drop standalone curses / false-starts ("fuck", "wait", etc.)
        // that aren't retakes but shouldn't survive either.
        let defumbled = FumbleFilter.filter(filtered)

        // Re-merge adjacent kept sub-ranges that are still touching each
        // other (i.e. both sides of a punctuation split survived). This
        // undoes the split where it wasn't needed, so the final cut doesn't
        // chop mid-sentence commas. Only actual retake drops leave gaps.
        let keepLabeled = defumbled.map { KeepRange(start: $0.start, end: $0.end) }
        let keep = Self.mergeContiguous(keepLabeled)
        NSLog("[Pipeline] retake+fumble filter: %d → %d ranges (post-merge %d)",
              vadRanges.count, keepLabeled.count, keep.count)

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
            keptRanges: snapped,
            sourceVideoURL: videoURL,
            outputVideoURL: outputURL
        )
    }

    // MARK: - Edge detection + snap

    /// Merges consecutive kept ranges whose boundaries are touching (within
    /// a tiny tolerance). Used after RetakeFilter to undo punctuation splits
    /// when both halves survive — preserves natural mid-sentence pauses so
    /// we don't get choppy micro-cuts.
    static func mergeContiguous(_ ranges: [KeepRange], tolerance: Double = 0.01) -> [KeepRange] {
        guard let first = ranges.first else { return ranges }
        var out: [KeepRange] = [first]
        for r in ranges.dropFirst() {
            let last = out[out.count - 1]
            if r.start - last.end <= tolerance {
                out[out.count - 1] = KeepRange(start: last.start, end: r.end)
            } else {
                out.append(r)
            }
        }
        return out
    }

    /// Splits each labeled range at Whisper-level sentence boundaries
    /// (any word ending with `,` `.` `?` `!` `;`). Fixes the case where a
    /// creator records multiple takes fast enough that VAD fuses them into
    /// one range — we still get separate sub-ranges for retake comparison.
    ///
    /// Sub-range ends get a 30 ms trailing pad past Whisper's reported word
    /// end. Whisper systematically reports word boundaries ~30-80 ms early
    /// because its CTC alignment greedily assigns trailing consonant
    /// releases to silence/next-word. Without this pad, when one sub-range
    /// gets dropped as a retake, the surviving sub-range gets cut
    /// mid-syllable (e.g. "Not one" → "Not on—"). The next sub-range still
    /// starts at the unpadded word boundary, so adjacent sub-ranges
    /// **overlap by 30 ms**. mergeContiguous handles this correctly:
    ///   - Both kept → overlap collapses into one continuous range
    ///   - One dropped → survivor keeps the trailing pad, no mid-word cut
    static func splitOnPunctuation(_ ranges: [LabeledRange], allWords: [Word]) -> [LabeledRange] {
        let terminators: Set<Character> = [",", ".", "?", "!", ";"]
        let trailingPadSec: Double = 0.030
        var out: [LabeledRange] = []

        for r in ranges {
            let wordsInRange = allWords
                .filter { $0.start < r.end && $0.end > r.start }
                .sorted(by: { $0.start < $1.start })

            guard wordsInRange.count > 1 else {
                out.append(r)
                continue
            }

            var chunkStart = r.start
            var chunkWords: [Word] = []

            for (idx, w) in wordsInRange.enumerated() {
                chunkWords.append(w)
                let last = w.word.last
                let isTerminator = last.map { terminators.contains($0) } ?? false
                let isLastWord = idx == wordsInRange.count - 1

                if isTerminator && !isLastWord {
                    let text = chunkWords
                        .map { $0.word }
                        .joined(separator: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    // Pad the end past Whisper's word boundary, but never
                    // exceed the parent VAD range's end.
                    let paddedEnd = min(r.end, w.end + trailingPadSec)
                    out.append(LabeledRange(start: chunkStart, end: paddedEnd, text: text))
                    // Next chunk starts at the unpadded boundary so adjacent
                    // sub-ranges overlap by `trailingPadSec`.
                    chunkStart = w.end
                    chunkWords = []
                }
            }

            // Emit the trailing chunk. Use the original r.end so any trailing
            // padding VAD added for the overall range stays intact.
            if !chunkWords.isEmpty {
                let text = chunkWords
                    .map { $0.word }
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                out.append(LabeledRange(start: chunkStart, end: r.end, text: text))
            }
        }

        return out
    }

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
