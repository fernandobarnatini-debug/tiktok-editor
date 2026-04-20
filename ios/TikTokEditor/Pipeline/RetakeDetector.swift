import Foundation

/// Sends labeled VAD speech ranges to Gemini 2.5 Pro, which returns the
/// indices to KEEP. Semantic editorial decisions only — no silence timing.
/// Untranscribed ranges are force-kept (never sent to Gemini for judgment).
enum RetakeDetector {

    private static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private static let model = "google/gemini-2.5-pro"

    private static let systemPrompt = """
You are an expert video editor specialized in TikTok Shop creator footage. Creators batch-record their lines on a phone. They mess up constantly and just re-say the line until they get it right — knowing you'll clean up the raw footage after.

Your ONLY job: identify every messed-up / incomplete / abandoned attempt at a line and cut it, keeping ONLY the final clean version of each intended sentence. This is the whole point of the tool. Err on the side of cutting mess-ups.

# How to think about it

1. Read the full list of segments top to bottom.
2. Group consecutive (or near-consecutive) segments into "intent groups" — attempts at saying the same thing. Group by what the speaker was TRYING to say (semantic intent), NOT just whether the words literally match. "The link is below" and "the links down below" are attempts at the same line.
3. Inside each group with 2+ segments, pick the one winning take — the most complete, fluent version. Almost always the LAST attempt, because creators retake until they nail it. Occasionally an earlier one wins (e.g. if the final attempt also got cut off — use your judgment).
4. Every segment in a group that is NOT the winner → CUT.
5. Segments that are unique (no retake group) → KEEP.

# Mess-up signals (any of these makes a segment a likely cut)

- Trails off mid-thought: "its literally 50% off and the link is..."
- Cursing or frustration mid-sentence: "rn shit", "damn", "fuck"
- Self-correction: "wait", "no", "hold on", "let me do that again", "let me redo", "okay so actually"
- Abrupt stop before the natural sentence end
- Filler-only segments right before a real take: "um", "uh", "okay", "alright"
- Stutters or repeated phrase mid-sentence ("the the the link")
- A shorter, cut-off version of a fuller sentence that comes right after it

# Important: ALWAYS keep the last segment

The last segment is almost always the closing CTA ("link below", "get it now", "flash sale"). Even if it sounds slightly off or garbled in transcription, KEEP it. Losing the CTA ruins the video.

# Examples

Example A — three attempts, keep the last:
[0] "hey guys so this product"
[1] "hey guys so this product is actually"
[2] "hey guys so this product is honestly the best thing I've ever used"
KEEP: [2] — the first two are trail-offs

Example B — mess-up with curse, keep the last:
[3] "its literally 50% off and the link is"  (trails off)
[4] "its 50% off rn and rn shit"  (messes up)
[5] "its literally 50% off rn and the links down below"  (clean)
KEEP: [5]

Example C — self-correction + filler:
[7] "okay wait"
[8] "lemme just"
[9] "so what you do is you click the link"
KEEP: [9] — [7] and [8] are pure filler/self-correction

Example D — unique content stays:
[10] "hey guys welcome back"
[11] "today I'm reviewing this product"
KEEP both: different intents, not retakes

# Output format

Return ONLY a JSON array of integer indices to KEEP. No markdown fences. No explanation. No prose.

Examples of valid output:
[0, 2, 5, 7, 9]
[]
[0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
"""

    static func filter(labeled: [LabeledRange]) async -> [KeepRange] {
        // Partition: untranscribed ranges are force-kept (Gemini only judges text it can read).
        let withText = labeled.filter { $0.text != "[no transcript]" && !$0.text.isEmpty }
        let forceKeep = labeled.filter { $0.text == "[no transcript]" || $0.text.isEmpty }
            .map { KeepRange(start: $0.start, end: $0.end) }

        let fallback = labeled.map { KeepRange(start: $0.start, end: $0.end) }

        guard !Secrets.openRouterAPIKey.isEmpty, !withText.isEmpty else { return fallback }

        var segmentsText = ""
        for (i, r) in withText.enumerated() {
            segmentsText += "[\(i)] [\(String(format: "%.2f", r.start)) → \(String(format: "%.2f", r.end))] \"\(r.text)\"\n"
        }

        let userMsg = """
        Here are \(withText.count) speech segments from a TikTok video:

        \(segmentsText)
        Which segment indices should be KEPT? Return a JSON array of indices.
        """

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMsg],
            ],
            "temperature": 0.1,
        ]

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(Secrets.openRouterAPIKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        NSLog("[Retake] sending %d segments to Gemini (forceKeep=%d untranscribed)",
              withText.count, forceKeep.count)
        for (i, r) in withText.enumerated() {
            NSLog("[Retake] seg %d [%.2f → %.2f] \"%@\"", i, r.start, r.end, r.text)
        }

        var traceBuffer = "PROMPT (\(withText.count) segments, \(forceKeep.count) force-kept untranscribed):\n\(segmentsText)\n"

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let choices = json["choices"] as? [[String: Any]],
                let message = choices.first?["message"] as? [String: Any],
                let raw = message["content"] as? String
            else {
                NSLog("[Retake] malformed response, falling back to keeping all")
                traceBuffer += "REPLY: <malformed response>\nRESULT: fallback keep-all\n"
                appendDebug(traceBuffer)
                return fallback
            }

            traceBuffer += "RAW REPLY:\n\(raw)\n"
            let cleaned = stripCodeFence(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            guard let arrayData = cleaned.data(using: .utf8),
                  let indices = try JSONSerialization.jsonObject(with: arrayData) as? [Int] else {
                NSLog("[Retake] could not parse reply as [Int], falling back")
                traceBuffer += "RESULT: parse-failed → fallback keep-all\ncleaned: \(cleaned)\n"
                appendDebug(traceBuffer)
                return fallback
            }

            let cut = (0..<withText.count).filter { !indices.contains($0) }
            NSLog("[Retake] keeping %@ / cutting %@", indices.description, cut.description)
            traceBuffer += "KEEP: \(indices)\nCUT: \(cut)\n"
            appendDebug(traceBuffer)

            let kept = indices
                .filter { $0 >= 0 && $0 < withText.count }
                .map { KeepRange(start: withText[$0].start, end: withText[$0].end) }

            // Merge Gemini's kept ranges with force-kept untranscribed ranges,
            // sorted by start time so the cutter sees them in order.
            return (kept + forceKeep).sorted { $0.start < $1.start }
        } catch {
            NSLog("[Retake] error calling Gemini: %@", error.localizedDescription)
            traceBuffer += "ERROR: \(error.localizedDescription)\n"
            appendDebug(traceBuffer)
            return fallback
        }
    }

    private static func stripCodeFence(_ s: String) -> String {
        guard s.hasPrefix("```") else { return s }
        var trimmed = s
        if let firstNewline = trimmed.firstIndex(of: "\n") {
            trimmed = String(trimmed[trimmed.index(after: firstNewline)...])
        } else {
            trimmed = String(trimmed.dropFirst(3))
        }
        if trimmed.hasSuffix("```") {
            trimmed = String(trimmed.dropLast(3))
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func appendDebug(_ s: String) {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = docs.appendingPathComponent("retake_debug.log")
        let stamped = "=== \(Date()) ===\n\(s)\n"
        if FileManager.default.fileExists(atPath: url.path),
           let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(stamped.utf8))
            try? h.close()
        } else {
            try? stamped.data(using: .utf8)?.write(to: url)
        }
    }
}
