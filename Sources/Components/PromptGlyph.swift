import SwiftUI

/// The shell prompt mark — a chevron over a baseline. Ported directly from the
/// mockup's SVG (`polyline 4,17 10,11 4,5` plus `line 12,19 → 20,19` in a 24×24
/// box) because no SF Symbol matches it.
struct PromptGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let originX = rect.minX + (rect.width - 24 * scale) / 2
        let originY = rect.minY + (rect.height - 24 * scale) / 2
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: originX + x * scale, y: originY + y * scale)
        }

        var path = Path()
        path.move(to: point(4, 17))
        path.addLine(to: point(10, 11))
        path.addLine(to: point(4, 5))
        path.move(to: point(12, 19))
        path.addLine(to: point(20, 19))
        return path
    }
}

extension PromptGlyph {
    /// Stroked the way the mockup draws it: round caps and joins.
    static func view(size: CGFloat, lineWidth: CGFloat = 1.8, color: Color) -> some View {
        PromptGlyph()
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }
}
