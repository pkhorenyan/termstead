import SwiftUI

/// Lays subviews out left to right, wrapping to a new line when the next one
/// would overflow. Used for the Route chain, which can grow past one line as
/// jump hosts are added.
struct FlowRow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6
    var alignment: VerticalAlignment = .center

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let lines = layout(subviews: subviews, maxWidth: maxWidth)
        let height = lines.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, lines.count - 1))
        let width = lines.map(\.width).max() ?? 0
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let lines = layout(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY

        for line in lines {
            var x = bounds.minX
            for item in line.items {
                let size = subviews[item].sizeThatFits(.unspecified)
                let dy = (line.height - size.height) / 2
                subviews[item].place(
                    at: CGPoint(x: x, y: y + (alignment == .center ? dy : 0)),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private struct Line {
        var items: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func layout(subviews: Subviews, maxWidth: CGFloat) -> [Line] {
        var lines: [Line] = []
        var current = Line()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let advance = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if !current.items.isEmpty, advance > maxWidth {
                lines.append(current)
                current = Line()
                current.items = [index]
                current.width = size.width
                current.height = size.height
            } else {
                current.items.append(index)
                current.width = advance
                current.height = max(current.height, size.height)
            }
        }
        if !current.items.isEmpty { lines.append(current) }
        return lines
    }
}
