import Foundation

/// Detects when a creator said the same line back-to-back and drops all
/// but the last take. Primary signal: text similarity (deterministic, free,
/// instant). Secondary signal for borderline cases only: Claude Haiku LLM
/// tiebreaker — catches ASR substitution errors and paraphrases that pure
/// text comparison can't see.
///
/// Rules:
///   1. Never drop the last range (it's always the CTA).
///   2. Only compare ranges within 15 s of each other (≥ 15 s gap = new topic).
///   3. Both ranges must be ≥ 2 words.
///   4. Compare each range to every kept range ahead of it within the window
///      (not just the immediate next one) — so a short interruption like
///      "ugh wait" doesn't block detection of take A vs take C.
///   5. Similarity is the MAX of two metrics:
///      - raw-token overlap (catches literal prefix retakes like "Hey guys" → "Hey guys welcome back")
///      - content-token overlap (stop-words stripped — catches paraphrased
///        CTAs like "link in bio" / "link in bio don't sleep on it")
///   6. Decision:
///      - simBest ≥ 0.60 → confident retake, drop
///      - simBest < 0.30 → confident not-retake, keep
///      - 0.30 ≤ simBest < 0.60 → borderline, ask Claude Haiku
enum RetakeFilter {

    static let similarityThreshold: Double = 0.60
    static let llmBorderlineLow: Double = 0.30
    static let maxTimeGapSec: Double = 15.0
    static let minWordsForRetake: Int = 2

    /// Words we strip before computing content similarity. Keeps the comparison
    /// focused on content words. Kept conservative — we don't want to strip
    /// anything that might be meaningful in creator speech.
    private static let stopWords: Set<String> = [
        "a", "an", "the",
        "i", "me", "my", "mine", "you", "your", "yours",
        "he", "him", "his", "she", "her", "hers",
        "it", "its", "we", "us", "our", "ours",
        "they", "them", "their", "theirs",
        "am", "is", "are", "was", "were", "be", "been", "being",
        "have", "has", "had", "having",
        "do", "does", "did", "doing",
        "in", "on", "at", "to", "for", "of", "with", "by", "from", "as", "about",
        "and", "or", "but", "so", "if", "then",
        "this", "that", "these", "those",
        // Common contraction fragments our tokenizer produces
        "s", "t", "m", "re", "ve", "ll", "d",
    ]

    static func filter(_ ranges: [LabeledRange]) async -> [LabeledRange] {
        guard ranges.count > 1 else { return ranges }

        var keep = Array(repeating: true, count: ranges.count)

        for i in 0..<ranges.count - 1 {
            if !keep[i] { continue }
            let a = ranges[i]
            let wordsA = tokenize(a.text)
            let contentA = wordsA.subtracting(stopWords)

            // Walk forward through every still-kept range until we pass the
            // time window. This lets us see past short interruptions.
            for j in (i + 1)..<ranges.count {
                if !keep[j] { continue }
                let b = ranges[j]

                let gap = b.start - a.end
                if gap > maxTimeGapSec { break }

                // Both ranges need enough words to be retake candidates.
                let wordsB = tokenize(b.text)
                guard wordsA.count >= minWordsForRetake,
                      wordsB.count >= minWordsForRetake else { continue }

                // Compute both similarity metrics. Use the MAX — if either one
                // crosses the upper threshold, it's a confident retake.
                let simRaw = overlapRatio(wordsA, wordsB)

                let contentB = wordsB.subtracting(stopWords)
                let simContent: Double =
                    (contentA.count >= minWordsForRetake && contentB.count >= minWordsForRetake)
                    ? overlapRatio(contentA, contentB)
                    : 0

                let simBest = max(simRaw, simContent)
                var matched = false

                if simBest >= similarityThreshold {
                    // Confident retake — drop on text similarity alone.
                    matched = true
                    NSLog("[RetakeFilter] DROP [%d] \"%@\" — %.0f%% overlap with [%d] \"%@\"",
                          i, a.text, simBest * 100, j, b.text)
                } else if simBest >= llmBorderlineLow {
                    // Borderline — ask Claude Haiku as tiebreaker.
                    NSLog("[RetakeFilter] LLM called on [%d] \"%@\" vs [%d] \"%@\" (%.0f%% overlap)",
                          i, a.text, j, b.text, simBest * 100)
                    let llmYes = await RetakeLLM.isRetake(of: a.text, next: b.text)
                    if llmYes {
                        matched = true
                        NSLog("[RetakeFilter] DROP [%d] \"%@\" — LLM YES vs [%d] \"%@\"",
                              i, a.text, j, b.text)
                    }
                }
                // simBest < llmBorderlineLow → don't even ask, keep range

                if matched {
                    keep[i] = false
                    break
                }
            }
        }

        // Safety: never drop the final range (CTA protection).
        keep[ranges.count - 1] = true

        return zip(ranges, keep).compactMap { $1 ? $0 : nil }
    }

    // MARK: - Helpers

    private static func tokenize(_ text: String) -> Set<String> {
        let tokens = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map(stem)
        return Set(tokens)
    }

    /// Tiny English stemmer — strips a trailing "s" on words longer than 3
    /// chars so "links" and "link" collapse to the same token. Length gate
    /// avoids destroying short words like "is" / "as" / "us" / "bus".
    private static func stem(_ word: String) -> String {
        guard word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss") else {
            return word
        }
        return String(word.dropLast())
    }

    /// Overlap ratio = |A ∩ B| / min(|A|, |B|). Using min (not max) so a short
    /// early take can match inside a longer final take.
    private static func overlapRatio(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let shared = a.intersection(b).count
        let minSize = min(a.count, b.count)
        return Double(shared) / Double(minSize)
    }
}
