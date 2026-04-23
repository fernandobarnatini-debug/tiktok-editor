import Foundation

/// Drops single-word curses / false-starts and very short isolated ranges
/// that slipped past RetakeFilter. Handles the case where the creator says
/// something like "fuck" or "wait" as a standalone exclamation mid-pitch —
/// not a retake (nothing to compare against), just abandoned speech.
///
/// Rules:
///   1. EXACT fumble-expression match → drop (e.g. range text is just "fuck").
///   2. Short + few words + not first/last range → drop (catches stuff like
///      "ugh" or "uh" or a quarter-second cough that the curse list missed).
///   3. First and last ranges are NEVER dropped (hook/CTA protection).
enum FumbleFilter {

    /// Expressions that, when they are the ENTIRE range text, mean the
    /// creator abandoned the thought. Kept conservative — words that can
    /// also be used naturally ("fucking amazing", "wait let me show you")
    /// only match when they stand alone, not when mixed with other words.
    private static let fumbleExpressions: Set<String> = [
        // standalone curses
        "fuck", "shit", "damn", "crap", "bitch", "ass",
        // false starts / aborts
        "wait", "oops", "nevermind", "never mind", "hold on", "hold up",
        "scratch that", "let me redo", "let me redo that", "hold up wait",
        // pure filler
        "ugh", "agh", "argh", "huh", "eh", "uh", "um", "umm", "uhh",
    ]

    /// Range is "probably a stray fumble" if it's under this duration
    /// AND has ≤ 2 words AND is surrounded by other ranges.
    private static let shortRangeMaxDurationSec: Double = 0.40
    private static let shortRangeMaxWords: Int = 2

    static func filter(_ ranges: [LabeledRange]) -> [LabeledRange] {
        guard ranges.count > 1 else { return ranges }

        var keep = Array(repeating: true, count: ranges.count)

        for (i, r) in ranges.enumerated() {
            let isFirst = i == 0
            let isLast = i == ranges.count - 1
            if isFirst || isLast { continue }

            let normalized = normalize(r.text)
            let wordCount = normalized.isEmpty
                ? 0
                : normalized.split(separator: " ").count
            let duration = r.end - r.start

            // Rule 1: exact fumble-expression match
            if fumbleExpressions.contains(normalized) {
                keep[i] = false
                NSLog("[FumbleFilter] DROP [%d] \"%@\" — fumble expression", i, r.text)
                continue
            }

            // Rule 2: short + few words (generic catch-all)
            if duration < shortRangeMaxDurationSec && wordCount <= shortRangeMaxWords && wordCount > 0 {
                keep[i] = false
                NSLog("[FumbleFilter] DROP [%d] \"%@\" — short isolated (%dw, %.2fs)",
                      i, r.text, wordCount, duration)
                continue
            }
        }

        return zip(ranges, keep).compactMap { $1 ? $0 : nil }
    }

    // MARK: - Helpers

    /// Lowercase, remove punctuation, collapse whitespace. "Fuck!" → "fuck".
    private static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        var result = ""
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == " " {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }
}
