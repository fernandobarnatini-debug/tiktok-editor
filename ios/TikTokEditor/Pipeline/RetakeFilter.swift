import Foundation

/// Detects when a creator said the same line back-to-back and drops all
/// but the last take. Pure text similarity — no LLM, no API call, no cost.
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
///      Drop if either crosses 60 %.
enum RetakeFilter {

    static let similarityThreshold: Double = 0.60
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

    static func filter(_ ranges: [LabeledRange]) -> [LabeledRange] {
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

                let wordsB = tokenize(b.text)
                var matched = false

                // Try raw-token overlap
                if wordsA.count >= minWordsForRetake,
                   wordsB.count >= minWordsForRetake {
                    let sim = overlapRatio(wordsA, wordsB)
                    if sim >= similarityThreshold {
                        matched = true
                        NSLog("[RetakeFilter] DROP [%d] \"%@\" — %.0f%% raw overlap with [%d] \"%@\"",
                              i, a.text, sim * 100, j, b.text)
                    }
                }

                // If raw didn't match, try content-token overlap (stop-words stripped)
                if !matched {
                    let contentB = wordsB.subtracting(stopWords)
                    if contentA.count >= minWordsForRetake,
                       contentB.count >= minWordsForRetake {
                        let sim = overlapRatio(contentA, contentB)
                        if sim >= similarityThreshold {
                            matched = true
                            NSLog("[RetakeFilter] DROP [%d] \"%@\" — %.0f%% content overlap with [%d] \"%@\"",
                                  i, a.text, sim * 100, j, b.text)
                        }
                    }
                }

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
