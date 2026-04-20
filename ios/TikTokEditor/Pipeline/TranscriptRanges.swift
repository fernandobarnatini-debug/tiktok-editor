import Foundation

/// Builds speech ranges directly from Whisper word-level timestamps.
/// Replaces Silero VAD, which was rejecting quiet words that Whisper heard
/// (e.g. dropping "before" in "before and after").
///
/// Grouping rule: split into a new range whenever the gap between
/// consecutive words exceeds `gapThresholdSec`. A natural sentence pause
/// (300-500 ms) stays inside one range; a pause between takes (>1 s) forces
/// a split. Each range carries the joined word text.
enum TranscriptRanges {

    static func rangesFromWords(
        segments: [Segment],
        gapThresholdSec: Double = 0.4
    ) -> [LabeledRange] {
        let allWords: [Word] = segments
            .flatMap { $0.words }
            .sorted { $0.start < $1.start }

        guard !allWords.isEmpty else { return [] }

        var ranges: [LabeledRange] = []
        var current: [Word] = [allWords[0]]

        for i in 1..<allWords.count {
            let prev = current.last!
            let cur = allWords[i]
            let gap = cur.start - prev.end

            if gap > gapThresholdSec {
                ranges.append(flush(current))
                current = [cur]
            } else {
                current.append(cur)
            }
        }
        ranges.append(flush(current))

        NSLog("[TranscriptRanges] %d ranges from %d words (gap threshold %.2f s)",
              ranges.count, allWords.count, gapThresholdSec)
        return ranges
    }

    private static func flush(_ words: [Word]) -> LabeledRange {
        let text = words
            .map { $0.word }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return LabeledRange(
            start: words.first!.start,
            end: words.last!.end,
            text: text
        )
    }
}
