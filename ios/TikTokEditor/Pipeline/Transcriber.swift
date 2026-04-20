import Foundation
import WhisperKit

enum TranscriberError: Error {
    case modelLoadFailed(String)
}

/// Mirrors transcriber.py. Wraps WhisperKit (base.en) and emits Segments with
/// word-level timestamps — same shape as the Python pipeline consumes.
///
/// Critical: WhisperKit returns one TranscriptionResult per ~30 s chunk, and
/// segment/word timestamps inside each result are relative to that chunk's
/// start. We add `result.seekTime` (chunk offset in seconds) to every
/// timestamp so downstream code sees absolute audio time.
actor Transcriber {

    private var pipeline: WhisperKit?
    /// Separately loaded base.en used ONLY for the filler pass. Larger model,
    /// better at emitting disfluencies when biased with a prompt. Lazy-loaded
    /// the first time transcribeFillerBiased() is called.
    private var fillerPipeline: WhisperKit?

    func ensureLoaded() async throws {
        if pipeline != nil { return }
        // On simulator CPU, WhisperKit's CoreML path has numerical precision
        // issues with base.en on multi-chunk audio — decoder silently emits
        // only special tokens. tiny.en works reliably everywhere. Real-device
        // runs can swap back to base.en for better accuracy.
        #if targetEnvironment(simulator)
        let modelName = "openai_whisper-tiny.en"
        #else
        let modelName = "openai_whisper-base.en"
        #endif
        do {
            pipeline = try await WhisperKit(
                WhisperKitConfig(model: modelName, verbose: true, logLevel: .debug)
            )
        } catch {
            throw TranscriberError.modelLoadFailed(error.localizedDescription)
        }
    }

    private func ensureFillerPipelineLoaded() async throws {
        if fillerPipeline != nil { return }
        do {
            fillerPipeline = try await WhisperKit(
                WhisperKitConfig(model: "openai_whisper-base.en", verbose: true, logLevel: .info)
            )
        } catch {
            throw TranscriberError.modelLoadFailed("base.en load failed: \(error.localizedDescription)")
        }
    }

    func transcribe(wavURL: URL) async throws -> [Segment] {
        return try await transcribeInternal(wavURL: wavURL, biasFillers: false)
    }

    /// Transcribe with a prompt that biases Whisper to include filler words
    /// ("um", "uh", "umm", "uhh") in the output. Uses base.en (larger model,
    /// better at emitting disfluencies) regardless of platform, falls back
    /// to the main pipeline if base.en fails to load.
    func transcribeFillerBiased(wavURL: URL) async throws -> [Segment] {
        // Try base.en first. If it fails to load or returns empty, fall
        // back to the main pipeline with the bias prompt.
        do {
            try await ensureFillerPipelineLoaded()
            if let pipe = fillerPipeline {
                let result = try await runTranscribe(pipeline: pipe, wavURL: wavURL, biasFillers: true)
                let totalWords = result.reduce(0) { $0 + $1.words.count }
                if totalWords > 0 {
                    NSLog("[Transcriber] filler pass via base.en: %d segments, %d words",
                          result.count, totalWords)
                    return result
                }
                NSLog("[Transcriber] base.en returned empty, falling back to tiny.en")
            }
        } catch {
            NSLog("[Transcriber] base.en unavailable (%@), falling back to tiny.en",
                  error.localizedDescription)
        }
        return try await transcribeInternal(wavURL: wavURL, biasFillers: true)
    }

    private func transcribeInternal(wavURL: URL, biasFillers: Bool) async throws -> [Segment] {
        try await ensureLoaded()
        guard let pipeline else { throw TranscriberError.modelLoadFailed("pipeline nil") }
        return try await runTranscribe(pipeline: pipeline, wavURL: wavURL, biasFillers: biasFillers)
    }

    private func runTranscribe(pipeline: WhisperKit, wavURL: URL, biasFillers: Bool) async throws -> [Segment] {

        // Filler-bias prompt: Whisper conditions on this "previous context"
        // when decoding. Giving it a natural sample with lots of fillers
        // makes it more likely to emit um/uh when they occur in the audio
        // instead of silently skipping them. Only applied for opt-in pass.
        var promptTokens: [Int]? = nil
        if biasFillers, let tok = pipeline.tokenizer {
            let promptText = " So I was, um, going to the store, uh, yesterday, and umm, I saw, uhh, my friend there."
            let encoded = tok.encode(text: promptText).filter { $0 < 50257 }
            promptTokens = encoded.isEmpty ? nil : encoded
        }

        // Thresholds: we disable noSpeech / logProb in general because they
        // trip on simulator CPU and silently drop chunks. But we KEEP
        // compressionRatioThreshold enabled — it catches decoder-loop failures
        // like "the the the the the…" and forces Whisper to retry at higher
        // temperature. Without it, base.en on simulator produces runaway loops.
        let options = DecodingOptions(
            task: .transcribe,
            language: "en",
            temperatureFallbackCount: 5,
            skipSpecialTokens: true,
            wordTimestamps: true,
            promptTokens: promptTokens,
            compressionRatioThreshold: 2.4,     // re-enabled: catches "the the the" loops
            logProbThreshold: nil,
            firstTokenLogProbThreshold: nil,
            noSpeechThreshold: nil
        )

        let results = try await pipeline.transcribe(
            audioPath: wavURL.path,
            decodeOptions: options
        )

        var out: [Segment] = []
        var dump = "WhisperKit returned \(results.count) result(s):\n"

        for (ri, result) in results.enumerated() {
            let offset = Double(result.seekTime ?? 0)
            dump += "  result[\(ri)] seekTime=\(offset) segments=\(result.segments.count) text=\"\(result.text.prefix(120))\"\n"

            for seg in result.segments {
                let segStart = Double(seg.start) + offset
                let segEnd = Double(seg.end) + offset

                let words: [Word] = (seg.words ?? []).map { w in
                    Word(
                        word: w.word.trimmingCharacters(in: .whitespaces),
                        start: round((Double(w.start) + offset) * 100) / 100,
                        end: round((Double(w.end) + offset) * 100) / 100
                    )
                }

                dump += "    seg[\(seg.id)] abs=[\(String(format: "%.2f", segStart))→\(String(format: "%.2f", segEnd))] words=\(words.count) \"\(seg.text.prefix(80))\"\n"
                if let firstWords = words.prefix(3) as ArraySlice<Word>? {
                    for w in firstWords {
                        dump += "      word [\(w.start)→\(w.end)] \"\(w.word)\"\n"
                    }
                }

                out.append(Segment(
                    text: seg.text.trimmingCharacters(in: .whitespaces),
                    start: round(segStart * 100) / 100,
                    end: round(segEnd * 100) / 100,
                    words: words
                ))
            }
        }

        let totalWords = out.reduce(0) { $0 + $1.words.count }
        NSLog("[Transcriber] %d segments, %d total words", out.count, totalWords)
        Self.appendDebug(dump)

        // Hard-fail if Whisper produced no words at all. Better than silently
        // feeding blank segments downstream and getting a useless final cut.
        if totalWords == 0 {
            throw TranscriberError.modelLoadFailed(
                "Whisper returned no words — the transcription model failed on this audio. " +
                "This is a known issue with base.en on simulator CPU; check that tiny.en is being used."
            )
        }

        return out
    }

    private static func appendDebug(_ s: String) {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = docs.appendingPathComponent("retake_debug.log")
        let stamped = "=== WHISPER \(Date()) ===\n\(s)\n"
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
