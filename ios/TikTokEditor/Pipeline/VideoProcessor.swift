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

enum VideoProcessorError: Error, LocalizedError {
    case invalidDuration(Double)
    case exportProducedNoFile
    var errorDescription: String? {
        switch self {
        case .invalidDuration(let d): return "Video has invalid duration (\(d)s). Try a different file."
        case .exportProducedNoFile: return "Export finished but produced no output file."
        }
    }
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

        DebugLog.section("PIPELINE START")
        DebugLog.append("video=\(videoURL.lastPathComponent)")

        onStage(.loading)
        try await transcriber.ensureLoaded()

        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let originalDuration = CMTimeGetSeconds(duration)
        DebugLog.append("originalDuration=\(String(format: "%.2f", originalDuration))s")
        guard originalDuration.isFinite, originalDuration > 0 else {
            throw VideoProcessorError.invalidDuration(originalDuration)
        }
        // Fail fast (and with a clear message) if the picked file isn't actually
        // a video — beats running the whole pipeline and dying at the export step.
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        guard !videoTracks.isEmpty else {
            DebugLog.append("ABORT: source has no video track")
            throw VideoCutterError.noVideoTrack
        }

        onStage(.extractingAudio)
        let audio = try await AudioExtractor.extract(from: videoURL)
        // Clean up the intermediate WAV regardless of how this function exits.
        defer { try? FileManager.default.removeItem(at: audio.wavURL) }

        onStage(.transcribing)
        let segments = try await transcriber.transcribe(wavURL: audio.wavURL)

        onStage(.detectingSpeech)
        let vadRanges = try vad.detectSpeech(samples: audio.samples, totalDuration: originalDuration)
        DebugLog.section("VAD")
        DebugLog.append("ranges=\(vadRanges.count)")
        for (i, r) in vadRanges.enumerated() {
            DebugLog.append("  [\(i)] \(String(format: "%.2f", r.start))→\(String(format: "%.2f", r.end)) (\(String(format: "%.2f", r.end - r.start))s)")
        }

        // Attach Whisper transcript to each VAD range so RetakeFilter can
        // compare text between adjacent ranges.
        let allWords = segments.flatMap { $0.words }
        let (labeled, wordsByRange) = Self.labelRanges(vadRanges, allWords: allWords)
        DebugLog.section("LABELED (pre-split)")
        for (i, r) in labeled.enumerated() {
            DebugLog.append("  [\(i)] \(String(format: "%.2f", r.start))→\(String(format: "%.2f", r.end)) \"\(r.text)\"")
        }

        // Trim abandoned prefixes inside each range — "Place the shi oh plus..."
        // → "plus..." — when speaker stuttered/cut-off and recovered with an
        // interjection. Has to happen before split since the abandoned phrase
        // usually has no punctuation between it and the recovery.
        let (trimmedLabeled, trimmedWordsByRange) = Self.trimAbandonedPrefixes(labeled, wordsByRange)

        // When creators speak fast (<90 ms pause between takes) VAD fuses
        // multiple takes into one range. Split those ranges at Whisper's
        // sentence-boundary punctuation so RetakeFilter can see each take.
        let sentences = Self.splitOnPunctuation(trimmedLabeled, wordsByRange: trimmedWordsByRange)
        NSLog("[Pipeline] punctuation split: %d → %d ranges", labeled.count, sentences.count)
        DebugLog.section("LABELED (post-split)")
        DebugLog.append("split: \(labeled.count) → \(sentences.count)")
        for (i, r) in sentences.enumerated() {
            DebugLog.append("  [\(i)] \(String(format: "%.3f", r.start))→\(String(format: "%.3f", r.end)) \"\(r.text)\"")
        }

        // Retake detection: drop back-to-back duplicate lines, keeping the last.
        // Text similarity first; Claude Haiku tiebreaker on borderline pairs.
        // See RetakeFilter.swift + RetakeLLM.swift.
        onStage(.llmRetakeCheck)
        let filtered = await RetakeFilter.filter(sentences)
        DebugLog.section("AFTER RETAKE FILTER")
        DebugLog.append("survivors: \(filtered.count) of \(sentences.count)")
        for (i, r) in filtered.enumerated() {
            DebugLog.append("  [\(i)] \(String(format: "%.3f", r.start))→\(String(format: "%.3f", r.end)) \"\(r.text)\"")
        }

        // Drop standalone curses / false-starts ("fuck", "wait", etc.)
        // that aren't retakes but shouldn't survive either.
        let defumbled = FumbleFilter.filter(filtered)
        DebugLog.section("AFTER FUMBLE FILTER")
        DebugLog.append("survivors: \(defumbled.count) of \(filtered.count)")
        for (i, r) in defumbled.enumerated() {
            DebugLog.append("  [\(i)] \(String(format: "%.3f", r.start))→\(String(format: "%.3f", r.end)) \"\(r.text)\"")
        }

        // Final cleanup: drop ranges that are essentially noise.
        //   1. Empty-text ranges — VAD detected speech but Whisper got
        //      no words (background noise, breath, off-screen sounds).
        //   2. Single-word ranges < 0.5 s — orphan fragments from
        //      "All right" → "right." where VAD only caught the tail.
        let cleaned = Self.dropEmptyAndFragments(defumbled)
        DebugLog.section("AFTER NOISE CLEANUP")
        DebugLog.append("survivors: \(cleaned.count) of \(defumbled.count)")
        for (i, r) in cleaned.enumerated() {
            DebugLog.append("  [\(i)] \(String(format: "%.3f", r.start))→\(String(format: "%.3f", r.end)) \"\(r.text)\"")
        }

        // Re-merge adjacent kept sub-ranges that are still touching each
        // other (i.e. both sides of a punctuation split survived). This
        // undoes the split where it wasn't needed, so the final cut doesn't
        // chop mid-sentence commas. Only actual retake drops leave gaps.
        let keepLabeled = cleaned.map { KeepRange(start: $0.start, end: $0.end) }
        let keep = Self.mergeContiguous(keepLabeled)
        NSLog("[Pipeline] retake+fumble filter: %d → %d ranges (post-merge %d)",
              vadRanges.count, keepLabeled.count, keep.count)
        DebugLog.section("AFTER MERGE")
        DebugLog.append("merged: \(keepLabeled.count) → \(keep.count)")
        for (i, r) in keep.enumerated() {
            DebugLog.append("  [\(i)] \(String(format: "%.3f", r.start))→\(String(format: "%.3f", r.end))")
        }

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
        DebugLog.section("AFTER EDGE+SNAP (final)")
        for (i, r) in snapped.enumerated() {
            DebugLog.append("  [\(i)] \(String(format: "%.3f", r.start))→\(String(format: "%.3f", r.end))")
        }

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

    /// Final cleanup pass: kills two classes of garbage that survive the
    /// retake/fumble filters because there's nothing to compare them to:
    ///   - Empty-text ranges (VAD heard noise, Whisper got no words)
    ///   - Single-word fragments under 0.5 s (e.g. "right." surviving from
    ///     a clipped "All right" where VAD missed the leading word)
    /// Both produce silent slivers and orphan one-word clips in the output.
    static func dropEmptyAndFragments(_ ranges: [LabeledRange]) -> [LabeledRange] {
        ranges.compactMap { r in
            let trimmed = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            let wordCount = trimmed
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
                .count
            let duration = r.end - r.start
            if wordCount <= 1 && duration < 0.5 { return nil }
            return r
        }
    }

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

    /// Assigns each Whisper word to exactly one VAD range based on its start
    /// time. A word "belongs" to the range whose [start, end) contains its
    /// start. Words whose start falls outside any range (Whisper and Silero
    /// disagreeing on speech edges by a few hundred ms) attach to the nearest
    /// range — preferring the preceding range on ties (trailing-slope case),
    /// capped at 1 s so hallucinated/far-away words don't get pulled in.
    /// Returns both the labels and the per-range word lists so downstream
    /// stages (splitter) can use the same assignments.
    static func labelRanges(_ ranges: [KeepRange], allWords: [Word]) -> (labels: [LabeledRange], wordsByRange: [[Word]]) {
        let sortedRanges = ranges.sorted { $0.start < $1.start }
        let sortedWords = allWords.sorted { $0.start < $1.start }
        var rangeWords: [[Word]] = Array(repeating: [], count: sortedRanges.count)

        for w in sortedWords {
            var assigned: Int? = sortedRanges.firstIndex { r in
                w.start >= r.start && w.start < r.end
            }
            if assigned == nil {
                var bestIdx: Int? = nil
                var bestDistance: Double = .infinity
                for (i, r) in sortedRanges.enumerated() {
                    let distance = w.start < r.start
                        ? r.start - w.start
                        : w.start - r.end
                    if distance < bestDistance {
                        bestDistance = distance
                        bestIdx = i
                    }
                }
                if let idx = bestIdx, bestDistance <= 1.0 {
                    assigned = idx
                }
            }
            if let idx = assigned { rangeWords[idx].append(w) }
        }

        let labels = sortedRanges.enumerated().map { (i, r) -> LabeledRange in
            let text = rangeWords[i].map { $0.word }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return LabeledRange(start: r.start, end: r.end, text: text)
        }
        return (labels, rangeWords)
    }

    /// Common interjection words a creator says when recovering from a stutter
    /// or aborted word. When one of these appears just after a short fragment-
    /// looking word in the first few words of a range, that prefix is the
    /// abandoned attempt and gets trimmed.
    private static let interjections: Set<String> = [
        "oh", "uh", "um", "umm", "uhh", "wait", "hmm", "er", "ah", "eh",
    ]

    /// Whitelist of common ≤3-char English words. Anything ≤3 chars NOT in
    /// here is treated as a likely word fragment ("shi-", "wha-", "th-").
    private static let knownShortWords: Set<String> = [
        "i", "a", "an", "the", "you", "we", "us", "my", "me", "he", "his", "she", "her", "it", "its", "him",
        "am", "is", "are", "was", "be", "do", "go", "did", "had", "has", "may", "let", "get", "got", "ran", "saw", "say", "see", "set", "sit", "use",
        "of", "to", "in", "on", "at", "by", "for",
        "and", "or", "but", "if", "so", "as",
        "yes", "no", "not", "all", "any", "now", "out", "up", "off", "old", "new", "one", "two", "ten", "six", "way", "own", "our", "won", "war", "who", "why", "how", "yet",
        "im", "id", "ill", "ive", "youre", "youve", "hes", "shes", "its", "were", "theyre", "thats",
        "oh", "uh", "um", "ah", "eh", "ok", "hi", "hey",
    ]

    /// Detects "abandoned prefix" pattern within a range — a stuttered/aborted
    /// attempt followed by an interjection and the real content. Trims the
    /// prefix so the survivor is just the real take.
    /// Trigger: short fragment word (≤3 chars, not a common word, no end
    /// punctuation) → interjection → ≥3 substantive words.
    static func trimAbandonedPrefix(_ words: [Word]) -> [Word] {
        guard words.count >= 5 else { return words }
        let scanLimit = min(4, words.count - 3)
        for i in 1..<scanLimit {
            let normalized = words[i].word.lowercased()
                .trimmingCharacters(in: .punctuationCharacters)
            guard interjections.contains(normalized) else { continue }

            let prev = words[i - 1].word
            let endsInTerminator = prev.last.map { ".?!".contains($0) } ?? false
            if endsInTerminator { continue }

            let prevStripped = prev.lowercased()
                .replacingOccurrences(of: "'", with: "")
                .trimmingCharacters(in: .punctuationCharacters)
            let isFragment = prevStripped.count <= 3 && !knownShortWords.contains(prevStripped)
            if !isFragment { continue }

            let remaining = Array(words[(i + 1)...])
            if remaining.count >= 3 { return remaining }
        }
        return words
    }

    /// Wraps trimAbandonedPrefix per range, updating both labels and the
    /// per-range word arrays. Logs every trim so we can see them later.
    static func trimAbandonedPrefixes(_ labeled: [LabeledRange], _ wordsByRange: [[Word]]) -> (labels: [LabeledRange], wordsByRange: [[Word]]) {
        DebugLog.section("ABANDONED PREFIX TRIM")
        var newLabeled: [LabeledRange] = []
        var newWords: [[Word]] = []
        var trimCount = 0
        for (i, words) in wordsByRange.enumerated() {
            let trimmed = trimAbandonedPrefix(words)
            if trimmed.count != words.count, let firstWord = trimmed.first {
                let r = labeled[i]
                let newText = trimmed.map { $0.word }
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                DebugLog.append("[\(i)] trimmed \(words.count - trimmed.count) words: \"\(r.text)\" → \"\(newText)\"")
                newLabeled.append(LabeledRange(start: firstWord.start, end: r.end, text: newText))
                newWords.append(trimmed)
                trimCount += 1
            } else {
                newLabeled.append(labeled[i])
                newWords.append(words)
            }
        }
        if trimCount == 0 { DebugLog.append("no trims applied") }
        return (newLabeled, newWords)
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
    static func splitOnPunctuation(_ ranges: [LabeledRange], wordsByRange: [[Word]]) -> [LabeledRange] {
        let terminators: Set<Character> = [",", ".", "?", "!", ";"]
        let trailingPadSec: Double = 0.030
        let minSplitTokens = 3
        var out: [LabeledRange] = []

        for (idx, r) in ranges.enumerated() {
            let wordsInRange = wordsByRange[idx]

            guard wordsInRange.count > 1 else {
                out.append(r)
                continue
            }

            var chunkStart = r.start
            var chunkWords: [Word] = []

            for (wIdx, w) in wordsInRange.enumerated() {
                chunkWords.append(w)
                let last = w.word.last
                let isTerminator = last.map { terminators.contains($0) } ?? false
                let isLastWord = wIdx == wordsInRange.count - 1
                let remainingWords = wordsInRange.count - wIdx - 1

                // Only split when BOTH the current chunk and what's left
                // would have ≥ minSplitTokens words. Prevents tiny lead-in
                // orphans like "So yeah," surviving a dropped abandoned take.
                if isTerminator && !isLastWord
                   && chunkWords.count >= minSplitTokens
                   && remainingWords >= minSplitTokens {
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
