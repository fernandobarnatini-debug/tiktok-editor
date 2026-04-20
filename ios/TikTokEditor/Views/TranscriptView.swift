import SwiftUI

/// Shows every Whisper word in reading order, colored by whether it
/// survives into the final cut. Tap a word to seek the player to that
/// timestamp.
///
/// - Cyan           = word falls inside a kept range → in final output
/// - Dim grey with  = word falls in a cut region → dropped from output
///   strikethrough
struct TranscriptView: View {

    let segments: [Segment]
    let keptRanges: [KeepRange]
    let playheadTime: Double
    let onWordTap: (Double) -> Void

    private let cyan = Color(red: 37/255, green: 244/255, blue: 238/255)
    private let dim  = Color(white: 0.35)
    private let keptBg = Color(red: 37/255, green: 244/255, blue: 238/255).opacity(0.08)

    private var allWords: [Word] {
        segments.flatMap { $0.words }
    }

    var body: some View {
        FlowLayout(horizontalSpacing: 4, verticalSpacing: 6) {
            ForEach(allWords.indices, id: \.self) { i in
                let w = allWords[i]
                let kept = isKept(w)
                let isUnderPlayhead = playheadTime >= w.start && playheadTime <= w.end

                Button(action: { onWordTap(w.start) }) {
                    Text(w.word)
                        .font(.system(size: 14))
                        .foregroundColor(kept ? .white : dim)
                        .strikethrough(!kept, color: dim)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(isUnderPlayhead ? cyan.opacity(0.4) : (kept ? keptBg : Color.clear))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(white: 0.05))
    }

    private func isKept(_ word: Word) -> Bool {
        keptRanges.contains { word.start < $0.end && word.end > $0.start }
    }
}

/// Simple wrapping flow layout — lays out children left-to-right,
/// wrapping to the next line when width runs out. Used by TranscriptView
/// to make each word a separately-tappable chip while flowing like text.
struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat = 4
    var verticalSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(subviews: subviews, maxWidth: maxWidth)
        let height = rows.reduce(0) { $0 + $1.height }
            + CGFloat(max(0, rows.count - 1)) * verticalSpacing
        return CGSize(width: maxWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(width: item.size.width, height: item.size.height)
                )
                x += item.size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var height: CGFloat = 0
    }

    private func computeRows(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        var x: CGFloat = 0
        for (i, sub) in subviews.enumerated() {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && !rows[rows.count - 1].items.isEmpty {
                rows.append(Row())
                x = 0
            }
            rows[rows.count - 1].items.append((i, size))
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
            x += size.width + horizontalSpacing
        }
        return rows
    }
}
