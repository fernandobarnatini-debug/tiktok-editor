import SwiftUI
import AVKit
import AVFoundation

/// Full-screen editor over the processed video. Shows the original video at
/// the top with its waveform + kept-range overlay below. User can scrub, play,
/// nudge range edges, and re-export the cut with updated ranges.
struct EditorView: View {

    @Environment(\.dismiss) private var dismiss

    let result: ProcessingResult
    let onReexported: (URL) -> Void

    @State private var player: AVPlayer
    @State private var playheadTime: Double = 0
    @State private var isPlaying: Bool = false
    @State private var timeObserverToken: Any?
    @State private var keptRanges: [KeepRange]
    @State private var isReexporting: Bool = false
    @State private var errorMessage: String?

    private let accent = Color(red: 254/255, green: 44/255, blue: 85/255)
    private let cyan   = Color(red: 37/255, green: 244/255, blue: 238/255)

    init(result: ProcessingResult, onReexported: @escaping (URL) -> Void) {
        self.result = result
        self.onReexported = onReexported
        _player = State(initialValue: AVPlayer(url: result.sourceVideoURL))
        _keptRanges = State(initialValue: result.keptRanges)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 12) {
                topBar

                VideoPlayer(player: player)
                    .frame(height: 300)
                    .background(Color.black)
                    .cornerRadius(12)
                    .padding(.horizontal, 12)

                statsStrip
                    .padding(.horizontal, 12)

                TimelineView(
                    samples: result.samples,
                    sampleRate: result.sampleRate,
                    segments: result.segments,
                    duration: result.originalDuration,
                    keptRanges: $keptRanges,
                    playheadTime: playheadTime,
                    onSeek: seek(to:)
                )

                controls

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundColor(accent)
                        .font(.system(size: 12))
                        .padding(.horizontal, 16)
                }

                Spacer(minLength: 0)
            }
            .padding(.top, 8)
        }
        .onAppear {
            attachTimeObserver()
        }
        .onDisappear {
            player.pause()
            removeTimeObserver()
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(Color(white: 0.1))
                    .clipShape(Circle())
            }

            Spacer()

            Text("Editor")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)

            Spacer()

            Button(action: { Task { await reexport() } }) {
                if isReexporting {
                    ProgressView().tint(.white)
                        .frame(width: 72, height: 32)
                } else {
                    Text("Re-export")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(accent)
                        .cornerRadius(8)
                }
            }
            .disabled(isReexporting)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Stats strip

    private var statsStrip: some View {
        let s = result.stats
        return HStack(spacing: 10) {
            pill(label: "Orig", value: formatDur(s.originalDuration))
            pill(label: "Clean", value: formatDur(editedFinalDuration), accent: cyan)
            pill(label: "Cut", value: formatDur(s.originalDuration - editedFinalDuration), accent: accent)
            pill(label: "Segs", value: "\(keptRanges.count)")
        }
    }

    private var editedFinalDuration: Double {
        keptRanges.reduce(0.0) { $0 + ($1.end - $1.start) }
    }

    private func pill(label: String, value: String, accent: Color = .white) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.gray)
                .textCase(.uppercase)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(accent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.08)))
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 20) {
            Button(action: jumpToStart) {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.white)
            }

            Button(action: togglePlay) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(cyan)
            }

            Text(formatDur(playheadTime) + " / " + formatDur(result.originalDuration))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.gray)
        }
        .padding(.top, 4)
    }

    // MARK: - Playback

    private func attachTimeObserver() {
        let interval = CMTime(value: 1, timescale: 30)
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { time in
            playheadTime = CMTimeGetSeconds(time)
            isPlaying = player.rate > 0
        }
    }

    private func removeTimeObserver() {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
    }

    private func togglePlay() {
        if player.rate > 0 {
            player.pause()
        } else {
            player.play()
        }
    }

    private func jumpToStart() {
        seek(to: 0)
    }

    private func seek(to time: Double) {
        let target = CMTime(seconds: time, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        playheadTime = time
    }

    // MARK: - Re-export

    private func reexport() async {
        guard !isReexporting else { return }
        player.pause()
        isReexporting = true
        errorMessage = nil
        defer { isReexporting = false }

        let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clean_edit_\(UUID().uuidString).mp4")

        do {
            try await VideoCutter.cut(
                source: result.sourceVideoURL,
                keep: keptRanges,
                to: outURL
            )
            onReexported(outURL)
            dismiss()
        } catch {
            errorMessage = "Re-export failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    private func formatDur(_ seconds: Double) -> String {
        if seconds < 60 {
            return String(format: "%.1fs", max(0, seconds))
        }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return "\(m)m \(s)s"
    }
}
