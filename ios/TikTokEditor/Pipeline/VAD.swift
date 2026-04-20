import Foundation
import OnnxRuntimeBindings

enum VADError: Error {
    case modelNotFound
    case inferenceFailed(String)
}

/// Silero VAD running via ONNX Runtime. Mirrors `_get_vad_ranges` in analyzer.py.
///
/// Default Silero params (match snakers4/silero-vad Python):
///   threshold: 0.5
///   min_speech_duration_ms: 250
///   min_silence_duration_ms: 100
///   speech_pad_ms: 30
///   window_size_samples: 512 (at 16 kHz)
///
/// After get_speech_timestamps we apply analyzer.py's extra 0.05 s padding
/// and merge ranges closer than 0.15 s — identical to the Python flow.
final class VAD {

    private let session: ORTSession
    private let env: ORTEnv

    static let sampleRate: Int = 16_000
    private static let windowSize: Int = 512
    private static let contextSize: Int = 64   // Silero v5 @ 16 kHz: prepend 64 prior samples

    init() throws {
        guard let modelURL = Bundle.main.url(forResource: "silero_vad", withExtension: "onnx") else {
            throw VADError.modelNotFound
        }
        self.env = try ORTEnv(loggingLevel: .warning)
        let opts = try ORTSessionOptions()
        try opts.setIntraOpNumThreads(1)
        self.session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: opts)
    }

    /// Returns keep ranges in seconds, merged + padded, covering detected speech.
    func detectSpeech(samples: [Float], totalDuration: Double) throws -> [KeepRange] {
        let rawRanges = try rawSpeechTimestamps(samples: samples)

        // Step 1: convert sample indices → seconds. Tighter pads than the
        // original analyzer.py (was 50 ms lead / 20 ms trail) — creator
        // wanted cuts to hug the edges of speech. The downstream edge
        // detector (detectSpeechEdges) still protects word boundaries.
        let keep: [KeepRange] = rawRanges.map { r in
            let start = max(0.0, Double(r.start) / Double(Self.sampleRate) - 0.020)
            let end = min(totalDuration, Double(r.end) / Double(Self.sampleRate) + 0.007)
            return KeepRange(start: round(start * 100) / 100, end: round(end * 100) / 100)
        }

        guard !keep.isEmpty else { return [] }

        // Step 2: merge ranges with gap ≤ 0.15 s (same as analyzer.py).
        var merged: [KeepRange] = [keep[0]]
        for r in keep.dropFirst() {
            let last = merged[merged.count - 1]
            if r.start - last.end <= 0.15 {
                merged[merged.count - 1] = KeepRange(start: last.start, end: r.end)
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    // MARK: - Silero get_speech_timestamps port

    private struct RawRange {
        var start: Int
        var end: Int
    }

    private func rawSpeechTimestamps(samples: [Float]) throws -> [RawRange] {
        let threshold: Float = 0.5
        let negThreshold: Float = threshold - 0.15
        let minSpeechSamples = Self.sampleRate * 250 / 1000       // 250ms
        let minSilenceSamples = Self.sampleRate * 100 / 1000      // 100ms
        let speechPadSamples = Self.sampleRate * 30 / 1000        // 30ms

        // LSTM state, zeroed.
        var state = [Float](repeating: 0, count: 2 * 1 * 128)
        // 64-sample lookback context — zeros for the first window, then last 64
        // samples of each concatenated input (Silero v5 OnnxWrapper convention).
        var context = [Float](repeating: 0, count: Self.contextSize)

        var triggered = false
        var tempEnd = 0
        var currentStart = 0
        var ranges: [RawRange] = []

        var i = 0
        while i + Self.windowSize <= samples.count {
            let chunk = Array(samples[i..<(i + Self.windowSize)])
            let prob = try runStep(chunk: chunk, context: &context, state: &state)

            if prob >= threshold && tempEnd != 0 {
                tempEnd = 0
            }
            if prob >= threshold && !triggered {
                triggered = true
                currentStart = i
            }
            if prob < negThreshold && triggered {
                if tempEnd == 0 { tempEnd = i + Self.windowSize }
                if i + Self.windowSize - tempEnd < minSilenceSamples {
                    // keep waiting — silence too short
                } else {
                    if tempEnd - currentStart >= minSpeechSamples {
                        ranges.append(RawRange(start: currentStart, end: tempEnd))
                    }
                    triggered = false
                    tempEnd = 0
                }
            }
            i += Self.windowSize
        }

        if triggered && samples.count - currentStart >= minSpeechSamples {
            ranges.append(RawRange(start: currentStart, end: samples.count))
        }

        // Pad each range by speechPadSamples and clamp.
        for idx in ranges.indices {
            ranges[idx].start = max(0, ranges[idx].start - speechPadSamples)
            ranges[idx].end = min(samples.count, ranges[idx].end + speechPadSamples)
        }

        // Merge overlapping after padding.
        guard !ranges.isEmpty else { return [] }
        var merged: [RawRange] = [ranges[0]]
        for r in ranges.dropFirst() {
            if r.start <= merged[merged.count - 1].end {
                merged[merged.count - 1].end = max(merged[merged.count - 1].end, r.end)
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    private func runStep(chunk: [Float], context: inout [Float], state: inout [Float]) throws -> Float {
        // Silero v5 wants [1, contextSize + windowSize] = [1, 576] @ 16 kHz.
        let input = context + chunk
        let inputData = NSMutableData(bytes: input, length: input.count * MemoryLayout<Float>.size)
        let inputTensor = try ORTValue(
            tensorData: inputData,
            elementType: .float,
            shape: [1, NSNumber(value: input.count)]
        )
        // Carry the last `contextSize` samples of the concatenated input forward.
        context = Array(input.suffix(Self.contextSize))

        // state: [2, 1, 128] float32
        let stateData = NSMutableData(bytes: state, length: state.count * MemoryLayout<Float>.size)
        let stateTensor = try ORTValue(
            tensorData: stateData,
            elementType: .float,
            shape: [2, 1, 128]
        )

        // sr: scalar int64
        var srValue: Int64 = Int64(Self.sampleRate)
        let srData = NSMutableData(bytes: &srValue, length: MemoryLayout<Int64>.size)
        let srTensor = try ORTValue(
            tensorData: srData,
            elementType: .int64,
            shape: []
        )

        let outputs = try session.run(
            withInputs: [
                "input": inputTensor,
                "state": stateTensor,
                "sr": srTensor,
            ],
            outputNames: Set(["output", "stateN"]),
            runOptions: nil
        )

        guard let outTensor = outputs["output"], let newStateTensor = outputs["stateN"] else {
            throw VADError.inferenceFailed("missing outputs")
        }

        let probData = try outTensor.tensorData() as Data
        let prob: Float = probData.withUnsafeBytes { $0.load(as: Float.self) }

        let newStateData = try newStateTensor.tensorData() as Data
        newStateData.withUnsafeBytes { raw in
            let floatPtr = raw.bindMemory(to: Float.self)
            for j in 0..<min(state.count, floatPtr.count) {
                state[j] = floatPtr[j]
            }
        }

        return prob
    }
}
