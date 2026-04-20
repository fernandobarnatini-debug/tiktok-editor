import SwiftUI

/// Renders a waveform from a Float32 PCM sample array.
/// Downsamples to one min/max peak pair per horizontal pixel column.
struct WaveformCanvas: View {

    let samples: [Float]
    let color: Color

    init(samples: [Float], color: Color = Color(white: 0.6)) {
        self.samples = samples
        self.color = color
    }

    var body: some View {
        Canvas { context, size in
            guard !samples.isEmpty, size.width > 0, size.height > 0 else { return }

            let columns = max(1, Int(size.width))
            let samplesPerColumn = max(1, samples.count / columns)
            let midY = size.height / 2
            let halfHeight = size.height / 2

            var path = Path()
            for col in 0..<columns {
                let lo = col * samplesPerColumn
                let hi = min(lo + samplesPerColumn, samples.count)
                guard lo < hi else { continue }

                var minV: Float = 0
                var maxV: Float = 0
                for i in lo..<hi {
                    let v = samples[i]
                    if v < minV { minV = v }
                    if v > maxV { maxV = v }
                }

                let x = Double(col) + 0.5
                let yTop = midY - Double(maxV) * halfHeight
                let yBot = midY - Double(minV) * halfHeight
                path.move(to: CGPoint(x: x, y: yTop))
                path.addLine(to: CGPoint(x: x, y: max(yBot, yTop + 0.5)))
            }

            context.stroke(path, with: .color(color), lineWidth: 1)
        }
    }
}
