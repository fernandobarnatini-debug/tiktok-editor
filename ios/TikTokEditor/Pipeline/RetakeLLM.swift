import Foundation

/// Claude Haiku tiebreaker for the RetakeFilter. Called only when raw/content
/// text overlap lands in the borderline 30–60 % range. Fail-safe: any error
/// returns `false` so we keep the range instead of silently dropping content.
///
/// Uses OpenRouter (Claude Haiku 4.5), reusing `Secrets.openRouterAPIKey`.
enum RetakeLLM {

    private static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private static let model = "anthropic/claude-haiku-4.5"

    private static let systemPrompt = """
You are helping edit a TikTok Shop creator's raw selfie footage. Creators \
record multiple attempts at the same marketing point — hook, product \
feature, CTA — and don't always repeat the exact words. They often \
rephrase, swap singular/plural, or change a word or two while meaning \
the same thing. When in doubt between "this is a retake" vs "these are \
two different points" — if segments A and B make basically the same \
marketing point (same hook, same feature, same CTA), call it a retake.

Your job: decide if segment A is an earlier version of segment B. A is \
earlier, B is the cleaner/fuller version the creator landed on. Reply \
with exactly one word: YES or NO. No explanation.
"""

    /// Returns true if segment A is plausibly a retake of segment B.
    /// Falls back to `false` on any error — callers should treat false as
    /// "keep the range" to avoid silently dropping content on API flakiness.
    static func isRetake(of previous: String, next: String) async -> Bool {
        guard !Secrets.openRouterAPIKey.isEmpty else {
            NSLog("[RetakeLLM] no API key, skipping")
            return false
        }

        let userMsg = "Segment A: \"\(previous)\"\nSegment B: \"\(next)\""

        let body: [String: Any] = [
            "model": model,
            "temperature": 0.0,
            "max_tokens": 4,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": userMsg],
            ],
        ]

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(Secrets.openRouterAPIKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let choices = json["choices"] as? [[String: Any]],
                let message = choices.first?["message"] as? [String: Any],
                let raw = message["content"] as? String
            else {
                NSLog("[RetakeLLM] malformed response")
                return false
            }

            let normalized = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            // Accept only a clean YES. Anything else → keep the range.
            let yes = normalized == "YES" || normalized.hasPrefix("YES")
            NSLog("[RetakeLLM] reply=\"%@\" → %@", raw, yes ? "YES" : "NO")
            return yes
        } catch {
            NSLog("[RetakeLLM] error: %@", error.localizedDescription)
            return false
        }
    }
}
