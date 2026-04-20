import Foundation
import AVFoundation

/// Second-pass cleaner that removes ONLY literal "um" / "uh" / "umm" / "uhh"
/// words from the transcript. If Whisper doesn't emit those tokens, the
/// button does NOTHING — no aggressive acoustic guessing, no collateral cuts.
/// Better to preserve the video than to mangle it.
///
/// Note: on real devices with `base.en` + bias prompt, Whisper does emit
/// filler words. On simulator with `tiny.en`, it often doesn't — in which
/// case this button is a no-op and the user sees "0 fillers found".
enum FillerRemover {

    struct Result {
        let outputURL: URL
        let originalDuration: Double
        let finalDuration: Double
        let removedDuration: Double
        let fillersFound: Int
    }

    /// Literal filler words to cut — strict set, case-insensitive, punctuation stripped.
    private static let fillerWords: Set<String> = [
        "um", "umm", "ummm", "ummmm",
        "uh", "uhh", "uhhh", "uhhhh",
    ]

    static func process(
        inputURL: URL,
        outputURL: URL
    ) async throws -> Result {
        let asset = AVURLAsset(url: inputURL)
        let duration = try await asset.load(.duration)
        let inputDuration = CMTimeGetSeconds(duration)

        let audio = try await AudioExtractor.extract(from: inputURL)
        defer { try? FileManager.default.removeItem(at: audio.wavURL) }

        // Transcribe with a prompt that biases Whisper to emit fillers as text.
        let transcriber = Transcriber()
        let segments = try await transcriber.transcribeFillerBiased(wavURL: audio.wavURL)

        // Walk every transcribed word. If it matches a filler token, mark it.
        var fillerRanges: [(start: Double, end: Double, word: String)] = []
        for seg in segments {
            for word in seg.words {
                let normalized = word.word
                    .lowercased()
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet.punctuationCharacters)
                if fillerWords.contains(normalized) {
                    fillerRanges.append((word.start, word.end, normalized))
                }
            }
        }

        NSLog("[FillerRemover] scanned transcript, found %d filler words: %@",
              fillerRanges.count,
              fillerRanges.map { "\"\($0.word)\"@\(String(format: "%.2f", $0.start))" }.joined(separator: ", "))

        // If none found, return input unchanged. No aggressive guessing.
        if fillerRanges.isEmpty {
            try? FileManager.default.removeItem(at: outputURL)
            try FileManager.default.copyItem(at: inputURL, to: outputURL)
            return Result(
                outputURL: outputURL,
                originalDuration: round(inputDuration * 100) / 100,
                finalDuration: round(inputDuration * 100) / 100,
                removedDuration: 0,
                fillersFound: 0
            )
        }

        // Merge overlapping and build keep ranges.
        let sorted = fillerRanges.sorted { $0.start < $1.start }
        var merged: [(start: Double, end: Double)] = []
        for f in sorted {
            if let last = merged.last, f.start <= last.end + 0.05 {
                merged[merged.count - 1] = (last.start, max(last.end, f.end))
            } else {
                merged.append((f.start, f.end))
            }
        }

        var keep: [KeepRange] = []
        var cursor = 0.0
        for f in merged {
            // Tiny buffer so we don't clip the word before/after the filler.
            let cutStart = max(cursor, f.start - 0.02)
            let cutEnd = min(inputDuration, f.end + 0.02)
            if cutStart > cursor + 0.05 {
                keep.append(KeepRange(start: cursor, end: cutStart))
            }
            cursor = max(cursor, cutEnd)
        }
        if inputDuration > cursor + 0.05 {
            keep.append(KeepRange(start: cursor, end: inputDuration))
        }

        guard !keep.isEmpty else {
            throw NSError(domain: "FillerRemover", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No content remaining after filler removal"
            ])
        }

        try await VideoCutter.cut(source: inputURL, keep: keep, to: outputURL)

        let outAsset = AVURLAsset(url: outputURL)
        let outDur = CMTimeGetSeconds(try await outAsset.load(.duration))

        return Result(
            outputURL: outputURL,
            originalDuration: round(inputDuration * 100) / 100,
            finalDuration: round(outDur * 100) / 100,
            removedDuration: round((inputDuration - outDur) * 100) / 100,
            fillersFound: merged.count
        )
    }
}
