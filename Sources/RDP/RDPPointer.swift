import CoreGraphics

/// The mouse for a remote desktop: RDP's pointer flags, where a point in the
/// view lands on the desktop, and the wheel in RDP's units.
enum RDPPointer {
    // PTR_FLAGS_* (MS-RDPBCGR 2.2.8.1.1.3.1.1.3).
    static let move = 0x0800
    static let down = 0x8000
    static let left = 0x1000
    static let right = 0x2000
    static let middle = 0x4000
    static let wheel = 0x0200
    static let horizontalWheel = 0x0400
    /// One wheel notch, as Windows counts it.
    static let notch = 120.0

    /// The desktop as the view shows it: scaled to fit, keeping its shape,
    /// centred (the layer's `.resizeAspect`).
    static func shownRect(of desktop: CGSize, in bounds: CGSize) -> CGRect {
        guard desktop.width > 0, desktop.height > 0 else { return .zero }
        let scale = min(bounds.width / desktop.width, bounds.height / desktop.height)
        let size = CGSize(width: desktop.width * scale, height: desktop.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// A point in the view, top-left origin, as a desktop pixel. Outside the
    /// desktop it is held to the nearest edge, so a drag that leaves the
    /// view still ends somewhere on it.
    static func pixel(at point: CGPoint, desktop: CGSize, bounds: CGSize) -> (x: Int, y: Int) {
        let shown = shownRect(of: desktop, in: bounds)
        guard shown.width > 0, shown.height > 0 else { return (0, 0) }
        let x = (point.x - shown.minX) / shown.width * desktop.width
        let y = (point.y - shown.minY) / shown.height * desktop.height
        return (min(max(Int(x), 0), Int(desktop.width) - 1), min(max(Int(y), 0), Int(desktop.height) - 1))
    }

    /// A wheel step's flags: the rotation is a 9-bit two's complement
    /// value, so one message carries at most 255 either way.
    static func wheelFlags(_ rotation: Int, horizontal: Bool) -> Int {
        let clamped = min(max(rotation, -255), 255)
        return (horizontal ? horizontalWheel : wheel) | (clamped & 0x1FF)
    }

    /// Wheel movement gathered into whole RDP steps. A mouse wheel moves in
    /// lines; a trackpad in points, many small ones, which add up.
    struct Wheel {
        private var pending = 0.0

        /// RDP rotation units for this much scrolling, positive away from
        /// the user (up, or right), as Windows has it.
        mutating func steps(for delta: Double, precise: Bool) -> [Int] {
            // A line is a notch; about fifteen points of a trackpad are.
            pending += delta * (precise ? RDPPointer.notch / 15 : RDPPointer.notch)
            var out: [Int] = []
            while abs(pending) >= 1 {
                let step = min(max(Int(pending), -255), 255)
                out.append(step)
                pending -= Double(step)
            }
            return out
        }
    }
}
