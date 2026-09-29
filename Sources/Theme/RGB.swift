import SwiftUI

/// A plain sRGB triple. Themes store colors in this form rather than as `Color`
/// so that derived tokens can be mixed arithmetically and so call sites can ask
/// for the tinted variants the design uses (group colors appear at 15%, 35% and
/// 50% alpha over their surface).
struct RGB: Hashable, Sendable {
    var r: Double
    var g: Double
    var b: Double

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(_ hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }

    /// Linear blend towards `other`. `t` is deliberately unclamped: the surface
    /// ramp extrapolates past the `border` anchor to reach the lighter greys.
    func mix(_ other: RGB, _ t: Double) -> RGB {
        RGB(r: r + (other.r - r) * t,
            g: g + (other.g - g) * t,
            b: b + (other.b - b) * t)
    }

    /// Rec. 709 luma on the gamma-encoded values. Good enough to decide whether
    /// text on top of this color should be dark or light.
    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }

    func color(_ opacity: Double) -> Color {
        Color(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    /// `#RRGGBB`, the form a custom color is stored in.
    init?(hex: String) {
        let digits = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(value)
    }

    var hex: String {
        func byte(_ v: Double) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }

    /// WCAG 2 relative luminance, on linearised sRGB.
    var relativeLuminance: Double {
        func linear(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// WCAG 2 contrast ratio, 1 to 21.
    func contrast(with other: RGB) -> Double {
        let a = relativeLuminance, b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
