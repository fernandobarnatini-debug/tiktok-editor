import SwiftUI

/// Horizontally-scrollable timeline showing the full audio waveform with
/// kept ranges highlighted, word labels, and a synced playhead. Supports
/// tap-to-seek on the body and drag gestures on the left/right edges of
/// each kept range to nudge start/end.
struct TimelineView: View {

    let samples: [Float]
    let sampleRate: Double
    let segments: [Segment]
    let duration: Double
    @Binding var keptRanges: [KeepRange]
    let playheadTime: Double
    let onSeek: (Double) -> Void

    @State private var dragOriginal: KeepRange?

    private let pointsPerSecond: Double = 80

    // Timeline coordinate system is anchored to audio-sample time, which is
    // the same reference Whisper uses for word timestamps. If video and
    // audio durations differ, we trust the audio side so the waveform,
    // labels, and ranges all line up.
    private var audioDuration: Double {
        Double(samples.count) / sampleRate
    }
    private var timelineDuration: Double {
        max(audioDuration, duration)
    }
    private let waveformHeight: Double = 120
    private let wordLabelHeight: Double = 16
    private let handleWidth: Double = 20
    private let minRangeDuration: Double = 0.05

    private let cyan = Color(red: 37/255, green: 244/255, blue: 238/255)

    private var contentWidth: Double { timelineDuration * pointsPerSecond }
    private var waveformWidth: Double { audioDuration * pointsPerSecond }
    private var totalHeight: Double { waveformHeight + wordLabelHeight + 4 }

    private var allWords: [Word] {
        segments.flatMap { $0.words }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            ZStack(alignment: .topLeading) {
                // Word labels track (above waveform)
                wordLabelsLayer
                    .frame(width: contentWidth, height: wordLabelHeight, alignment: .topLeading)

                // Timeline body (waveform + ranges + playhead)
                timelineBody
                    .frame(width: contentWidth, height: waveformHeight)
                    .offset(y: wordLabelHeight + 4)
            }
            .frame(width: contentWidth, height: totalHeight, alignment: .topLeading)
        }
        .frame(height: totalHeight)
        .background(Color.black)
    }

    // MARK: - Word labels

    private var wordLabelsLayer: some View {
        ZStack(alignment: .topLeading) {
            ForEach(allWords.indices, id: \.self) { i in
                let w = allWords[i]
                Text(w.word.trimmingCharacters(in: .whitespaces))
                    .font(.system(size: 9))
                    .foregroundColor(Color(white: 0.65))
                    .lineLimit(1)
                    .fixedSize()
                    .offset(x: w.start * pointsPerSecond)
            }
        }
    }

    // MARK: - Timeline body

    private var timelineBody: some View {
        ZStack(alignment: .topLeading) {
            // Background — represents "cut" regions
            Rectangle()
                .fill(Color(white: 0.06))

            // Kept range tints
            ForEach(keptRanges.indices, id: \.self) { i in
                let r = keptRanges[i]
                Rectangle()
                    .fill(cyan.opacity(0.18))
                    .frame(width: max(0, (r.end - r.start) * pointsPerSecond),
                           height: waveformHeight)
                    .offset(x: r.start * pointsPerSecond)
            }

            // Waveform — widthed by actual audio duration so every sample
            // maps to its correct timestamp. If audio ≠ video duration
            // there may be a small empty strip at the right end of the
            // scroll; that's the correct thing to show.
            WaveformCanvas(samples: samples, color: Color(white: 0.55))
                .frame(width: waveformWidth, height: waveformHeight)
                .allowsHitTesting(false)

            // Range outlines + drag handles
            ForEach(keptRanges.indices, id: \.self) { i in
                rangeFrame(index: i)
            }

            // Playhead
            Rectangle()
                .fill(Color.white)
                .frame(width: 2, height: waveformHeight)
                .offset(x: max(0, playheadTime * pointsPerSecond - 1))
                .allowsHitTesting(false)
        }
        // Tap-to-seek on the body. Using onTapGesture (not DragGesture) so
        // horizontal scroll in the parent ScrollView is not intercepted.
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { location in
            let time = Double(location.x) / pointsPerSecond
            onSeek(max(0, min(timelineDuration, time)))
        }
    }

    // MARK: - Range frame + handles

    private func rangeFrame(index: Int) -> some View {
        let r = keptRanges[index]
        let width = max(0, (r.end - r.start) * pointsPerSecond)
        return ZStack(alignment: .topLeading) {
            // Outline (visual boundary of the range)
            Rectangle()
                .stroke(cyan.opacity(0.8), lineWidth: 1)
                .frame(width: width, height: waveformHeight)
                .allowsHitTesting(false)

            // Left handle
            handle(isLeft: true)
                .gesture(edgeDrag(index: index, isLeft: true))

            // Right handle
            handle(isLeft: false)
                .offset(x: max(0, width - handleWidth))
                .gesture(edgeDrag(index: index, isLeft: false))
        }
        .offset(x: r.start * pointsPerSecond)
    }

    private func handle(isLeft: Bool) -> some View {
        Rectangle()
            .fill(cyan.opacity(0.9))
            .frame(width: handleWidth, height: waveformHeight)
            .overlay(
                Rectangle()
                    .fill(Color.black.opacity(0.6))
                    .frame(width: 2, height: waveformHeight * 0.5)
            )
    }

    private func edgeDrag(index: Int, isLeft: Bool) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragOriginal == nil, keptRanges.indices.contains(index) {
                    dragOriginal = keptRanges[index]
                }
                guard let original = dragOriginal else { return }
                updateEdge(index: index, isLeft: isLeft,
                           original: original,
                           translationX: Double(value.translation.width))
            }
            .onEnded { _ in
                dragOriginal = nil
            }
    }

    private func updateEdge(index: Int, isLeft: Bool, original: KeepRange, translationX: Double) {
        guard keptRanges.indices.contains(index) else { return }
        let deltaSec = translationX / pointsPerSecond

        var newStart = original.start
        var newEnd = original.end

        if isLeft {
            newStart = original.start + deltaSec
            newStart = max(0, newStart)
            newStart = min(newStart, original.end - minRangeDuration)
            // Don't cross previous range's end
            if index > 0 {
                newStart = max(newStart, keptRanges[index - 1].end)
            }
        } else {
            newEnd = original.end + deltaSec
            newEnd = min(timelineDuration, newEnd)
            newEnd = max(newEnd, original.start + minRangeDuration)
            // Don't cross next range's start
            if index < keptRanges.count - 1 {
                newEnd = min(newEnd, keptRanges[index + 1].start)
            }
        }

        keptRanges[index] = KeepRange(start: newStart, end: newEnd)
    }
}
