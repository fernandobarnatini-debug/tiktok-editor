import Foundation

/// Drops standalone curses / false-starts / pure fillers that RetakeFilter
/// can't catch. Handles the case where the creator says something like
/// "fuck" or "wait" as a one-word exclamation mid-pitch — not a retake
/// (nothing similar to compare against), just abandoned speech.
///
/// Rules:
///   1. EXACT fumble-expression match → drop (range text is just "fuck",
///      "uh", "wait", etc.). Words can still be used naturally inside
///      longer phrases (e.g. "wait let me show you") because that text
///      won't equal "wait" exactly.
///   2. First and last ranges are NEVER dropped (hook/CTA protection).
///
/// Note: an earlier "short isolated range" catch-all rule was removed
/// because it was murdering meaningful 1-word interjections like "Yeah",
/// "Right", "Wow", "Look" — which are core TikTok creator speech. The
/// editor is the fallback for any rare stray noise that slips through.
enum FumbleFilter {

    /// Expressions that, when they form the ENTIRE range text, mean the
    /// creator abandoned the thought. Match is exact (after normalization)
    /// so "fucking amazing" or "wait let me show you" are unaffected — only
    /// the standalone single-expression case is cut.
    private static let fumbleExpressions: Set<String> = [
        // standalone curses
        "fuck", "shit", "damn", "crap", "bitch", "ass",
        // false starts / aborts
        "wait", "oops", "nevermind", "never mind", "hold on", "hold up",
        "scratch that", "let me redo", "let me redo that", "hold up wait",
        // pure filler
        "ugh", "agh", "argh", "huh", "eh", "uh", "um", "umm", "uhh",
    ]

    static func filter(_ ranges: [LabeledRange]) -> [LabeledRange] {
        guard ranges.count > 1 else { return ranges }

        var keep = Array(repeating: true, count: ranges.count)

        for (i, r) in ranges.enumerated() {
            let isFirst = i == 0
            let isLast = i == ranges.count - 1
            if isFirst || isLast { continue }

            let normalized = normalize(r.text)

            if fumbleExpressions.contains(normalized) {
                keep[i] = false
                NSLog("[FumbleFilter] DROP [%d] \"%@\" — fumble expression", i, r.text)
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
