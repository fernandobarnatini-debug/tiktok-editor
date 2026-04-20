import Foundation

/// Attaches transcript text to each VAD range.
///
/// Primary: find words whose timestamps overlap the VAD range, join them.
/// Fallback: if no word-level overlap, find Whisper segments that overlap
/// the VAD range and use their combined text. Whisper's segment boundaries
/// are coarser than words but don't drift, so they're the safety net.
enum RangeLabeler {

    static func label(ranges: [KeepRange], segments: [Segment]) -> [LabeledRange] {
        let allWords: [Word] = segments.flatMap { $0.words }

        return ranges.map { r in
            // Primary: word-level overlap
            let wordsInRange = allWords
                .filter { $0.start < r.end && $0.end > r.start }
                .map { $0.word }

            if !wordsInRange.isEmpty {
                let text = wordsInRange.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                return LabeledRange(start: r.start, end: r.end, text: text)
            }

            // Fallback: segment-level overlap
            let overlappingSegments = segments.filter { $0.start < r.end && $0.end > r.start }
            if !overlappingSegments.isEmpty {
                let text = overlappingSegments
                    .map { $0.text }
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
                if !text.isEmpty {
                    return LabeledRange(start: r.start, end: r.end, text: text)
                }
            }

            return LabeledRange(start: r.start, end: r.end, text: "[no transcript]")
        }
    }
}
