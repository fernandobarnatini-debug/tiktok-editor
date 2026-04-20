import SwiftUI
import PhotosUI
import AVKit
import Photos

struct ContentView: View {

    @State private var pickerItem: PhotosPickerItem?
    @State private var videoURL: URL?
    @State private var stage: ProcessingStage?
    @State private var stats: ProcessingStats?
    @State private var result: ProcessingResult?
    @State private var outputURL: URL?
    @State private var errorMessage: String?
    @State private var isProcessing = false
    @State private var isRemovingFillers = false
    @State private var fillersRemoved = false
    @State private var showEditor = false

    private let accent = Color(red: 254/255, green: 44/255, blue: 85/255)    // #fe2c55
    private let cyan   = Color(red: 37/255,  green: 244/255, blue: 238/255) // #25f4ee

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    header

                    if stats == nil {
                        picker
                    }

                    if let videoURL, stats == nil {
                        fileBadge(url: videoURL)
                        processButton
                    }

                    if isProcessing, let stage {
                        stageView(stage: stage)
                    }

                    if let stats {
                        statsCards(stats)
                        if isRemovingFillers {
                            fillerProgressView
                        }
                        if let outputURL {
                            if result != nil && !isRemovingFillers {
                                openEditorButton
                            }
                            if !fillersRemoved && !isRemovingFillers {
                                removeFillersButton(outputURL: outputURL)
                            }
                            saveButton(outputURL: outputURL)
                            resetButton
                        }
                    }

                    if let errorMessage {
                        errorBanner(errorMessage)
                    }
                }
                .padding(24)
                .frame(maxWidth: 520)
            }
        }
        .fullScreenCover(isPresented: $showEditor) {
            if let result {
                EditorView(result: result) { newOutputURL in
                    handleReexport(newOutputURL: newOutputURL)
                }
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                Text("TikTok")
                    .foregroundColor(accent)
                Text(" Editor")
                    .foregroundColor(.white)
            }
            .font(.system(size: 28, weight: .bold))

            Text("Remove dead space. One tap.")
                .foregroundColor(.gray)
                .font(.system(size: 14))
        }
        .padding(.top, 20)
    }

    private var picker: some View {
        PhotosPicker(selection: $pickerItem, matching: .videos) {
            VStack(spacing: 10) {
                Image(systemName: "video.badge.plus")
                    .font(.system(size: 36))
                    .foregroundColor(.white)
                Text(videoURL == nil ? "Pick a video" : "Pick a different video")
                    .foregroundColor(.white)
                Text("mp4, mov, m4v up to 300 MB")
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
            .padding(.horizontal, 24)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(videoURL == nil ? Color(white: 0.2) : cyan, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(videoURL == nil ? Color.clear : cyan.opacity(0.05))
                    )
            )
        }
        .onChange(of: pickerItem) { _, newValue in
            Task { await loadPicked(item: newValue) }
        }
    }

    private func fileBadge(url: URL) -> some View {
        HStack {
            Image(systemName: "film")
                .foregroundColor(cyan)
            Text(url.lastPathComponent)
                .foregroundColor(.white)
                .font(.system(size: 14))
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.1)))
    }

    private var processButton: some View {
        Button(action: { Task { await process() } }) {
            Text("Remove Dead Space")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(accent)
                .cornerRadius(12)
        }
        .disabled(isProcessing)
        .opacity(isProcessing ? 0.5 : 1.0)
    }

    private func stageView(stage: ProcessingStage) -> some View {
        VStack(spacing: 12) {
            ProgressView().tint(accent)
            Text(stage.rawValue)
                .foregroundColor(.gray)
                .font(.system(size: 14))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.08)))
    }

    private func statsCards(_ s: ProcessingStats) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                statCard(label: "Original", value: "\(formatDur(s.originalDuration))")
                statCard(label: "Clean", value: "\(formatDur(s.finalDuration))", accent: cyan)
            }
            HStack(spacing: 12) {
                statCard(label: "Removed", value: "\(formatDur(s.removedDuration))", accent: accent)
                statCard(label: "Saved", value: "\(Int(s.deadSpacePercentage))%", accent: accent)
            }
            Text("\(s.segmentsKept) segments kept")
                .foregroundColor(.gray)
                .font(.system(size: 12))
        }
    }

    private func statCard(label: String, value: String, accent: Color = .white) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.gray)
                .textCase(.uppercase)
            Text(value)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.08)))
    }

    private var openEditorButton: some View {
        Button(action: { showEditor = true }) {
            Label("Open Editor", systemImage: "waveform")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(cyan)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(cyan, lineWidth: 1))
                .cornerRadius(12)
        }
    }

    private func removeFillersButton(outputURL: URL) -> some View {
        Button(action: { Task { await removeFillers(inputURL: outputURL) } }) {
            Label("Remove Fillers (um / uh)", systemImage: "scissors")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(accent, lineWidth: 1))
                .cornerRadius(12)
        }
    }

    private var fillerProgressView: some View {
        VStack(spacing: 10) {
            ProgressView().tint(accent)
            Text("Removing fillers…")
                .foregroundColor(.gray)
                .font(.system(size: 13))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.08)))
    }

    private func saveButton(outputURL: URL) -> some View {
        Button(action: { Task { await saveToPhotos(url: outputURL) } }) {
            Label("Save to Photos", systemImage: "square.and.arrow.down")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(cyan.opacity(0.2))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(cyan, lineWidth: 1))
                .cornerRadius(12)
        }
    }

    private var resetButton: some View {
        Button(action: reset) {
            Text("Process another")
                .foregroundColor(.gray)
                .font(.system(size: 14))
        }
        .padding(.top, 8)
    }

    private func errorBanner(_ msg: String) -> some View {
        Text(msg)
            .foregroundColor(accent)
            .font(.system(size: 13))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(accent.opacity(0.1)))
    }

    // MARK: - Actions

    private func loadPicked(item: PhotosPickerItem?) async {
        guard let item else { return }
        errorMessage = nil
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                errorMessage = "Could not load the selected video."
                return
            }
            let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "mov"
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("pick_\(UUID().uuidString).\(ext)")
            try data.write(to: url)
            videoURL = url
            stats = nil
            outputURL = nil
        } catch {
            errorMessage = "Load failed: \(error.localizedDescription)"
        }
    }

    private func process() async {
        guard let videoURL else { return }
        errorMessage = nil
        isProcessing = true
        defer { isProcessing = false }

        let output = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clean_\(UUID().uuidString).mp4")

        do {
            let processor = try VideoProcessor()
            let pipelineResult = try await processor.process(videoURL: videoURL, outputURL: output) { newStage in
                Task { @MainActor in self.stage = newStage }
            }
            await MainActor.run {
                self.result = pipelineResult
                self.stats = pipelineResult.stats
                self.outputURL = output
            }
        } catch {
            errorMessage = "Processing failed: \(error.localizedDescription)"
        }
    }

    private func handleReexport(newOutputURL: URL) {
        // Editor re-exported with tweaked ranges. Point save-to-Photos
        // at the new mp4 and recompute stats from the asset's actual duration.
        Task {
            let asset = AVURLAsset(url: newOutputURL)
            let finalDur = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
            await MainActor.run {
                self.outputURL = newOutputURL
                if let current = self.stats {
                    let removed = max(0, current.originalDuration - finalDur)
                    let pct = current.originalDuration > 0 ? (removed / current.originalDuration) * 100 : 0
                    self.stats = ProcessingStats(
                        originalDuration: current.originalDuration,
                        finalDuration: round(finalDur * 100) / 100,
                        removedDuration: round(removed * 100) / 100,
                        segmentsKept: self.result?.keptRanges.count ?? current.segmentsKept,
                        deadSpacePercentage: round(pct * 10) / 10
                    )
                }
                self.errorMessage = "Re-exported with edits."
            }
        }
    }

    private func removeFillers(inputURL: URL) async {
        errorMessage = nil
        isRemovingFillers = true
        defer { isRemovingFillers = false }

        let output = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nofiller_\(UUID().uuidString).mp4")

        do {
            let result = try await FillerRemover.process(inputURL: inputURL, outputURL: output)
            await MainActor.run {
                self.outputURL = result.outputURL
                self.stats = ProcessingStats(
                    originalDuration: self.stats?.originalDuration ?? result.originalDuration,
                    finalDuration: result.finalDuration,
                    removedDuration: (self.stats?.removedDuration ?? 0) + result.removedDuration,
                    segmentsKept: (self.stats?.segmentsKept ?? 0),
                    deadSpacePercentage: self.stats?.deadSpacePercentage ?? 0
                )
                self.fillersRemoved = true
                self.errorMessage = "Removed \(result.fillersFound) filler \(result.fillersFound == 1 ? "region" : "regions")."
            }
        } catch {
            errorMessage = "Filler removal failed: \(error.localizedDescription)"
        }
    }

    private func saveToPhotos(url: URL) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            errorMessage = "Photos access denied."
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
            }
            errorMessage = "Saved to Photos."
        } catch {
            errorMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    private func reset() {
        pickerItem = nil
        videoURL = nil
        stats = nil
        result = nil
        outputURL = nil
        stage = nil
        errorMessage = nil
        fillersRemoved = false
        isRemovingFillers = false
        showEditor = false
    }

    private func formatDur(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return "\(m)m \(s)s"
    }
}

#Preview {
    ContentView()
}
