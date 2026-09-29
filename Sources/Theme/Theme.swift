import SwiftUI

/// The full set of semantic colors a screen can ask for.
///
/// Graphite is written out literally, value for value, from the reference
/// mockup — it is the default theme and the one fidelity is measured against.
/// The other five ship only the nine tokens the Appearance screen publishes
/// (window, sidebar, terminal, text, muted, accent, green, blue, border), so
/// they are expanded by `Theme.derived(...)`, whose ratios are calibrated so
/// that feeding it Graphite's nine seeds reproduces Graphite's literal values.
struct Theme: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case light, dark

        var label: String { self == .dark ? "Dark" : "Light" }
    }

    let id: String
    let name: String
    let kind: Kind

    // Surfaces, from the back of the window forward.
    let window: RGB          // the window body behind everything
    let chrome: RGB          // toolbar and status bar
    let sidebar: RGB         // session tree column
    let terminal: RGB        // terminal canvas
    let field: RGB           // text inputs, recessed wells
    let inset: RGB           // quiet info panels inside a sheet
    let elevated: RGB        // popovers
    let selected: RGB        // selected row
    let selectedStrong: RGB  // pressed / active segment

    // Separators, weakest to strongest.
    let border: RGB
    let borderStrong: RGB
    let borderStronger: RGB

    // Text, brightest to faintest.
    let text: RGB
    let textSecondary: RGB
    let textMuted: RGB
    let textFaint: RGB
    let disabled: RGB

    let accent: RGB
    let accentHover: RGB
    let onAccent: RGB

    // Terminal transcript colors.
    let ansiText: RGB
    let ansiGreen: RGB
    let ansiBlue: RGB
    let ansiYellow: RGB
    let ansiRed: RGB
    let ansiDim: RGB

    var isDark: Bool { kind == .dark }

    var appearance: NSAppearance? {
        NSAppearance(named: isDark ? .darkAqua : .aqua)
    }
}

extension Theme {
    /// Expands the nine published seeds into the full token set.
    ///
    /// Two directions do the work. `terminal` is always the extreme surface —
    /// the darkest in a dark theme, the lightest in a light one — so mixing
    /// towards it *recedes* a surface correctly in both. `border` is always the
    /// more contrasty neighbour of `sidebar`, so the `sidebar → border` ramp
    /// *raises* a surface in both, and is extrapolated past 1 for the greys
    /// above `border`.
    static func derived(
        id: String,
        name: String,
        kind: Kind,
        window w: UInt32,
        sidebar s: UInt32,
        terminal t: UInt32,
        text tx: UInt32,
        muted m: UInt32,
        accent a: UInt32,
        green g: UInt32,
        blue b: UInt32,
        border bd: UInt32,
        yellow y: UInt32,
        red r: UInt32
    ) -> Theme {
        let window = RGB(w), sidebar = RGB(s), terminal = RGB(t)
        let text = RGB(tx), muted = RGB(m), accent = RGB(a), border = RGB(bd)

        // A raised surface in a light theme should approach white rather than
        // step towards the (darker) border, so popovers flip direction there.
        let elevated = kind == .dark
            ? sidebar.mix(border, 0.65)
            : sidebar.mix(terminal, 0.75)

        return Theme(
            id: id,
            name: name,
            kind: kind,
            window: window,
            chrome: sidebar.mix(border, 0.25),
            sidebar: sidebar,
            terminal: terminal,
            field: window.mix(terminal, 0.33),
            inset: sidebar.mix(window, 0.45),
            elevated: elevated,
            selected: sidebar.mix(border, 0.95),
            selectedStrong: sidebar.mix(border, 1.25),
            border: border,
            borderStrong: sidebar.mix(border, 1.6),
            borderStronger: sidebar.mix(border, 1.9),
            text: text,
            textSecondary: text.mix(muted, 0.34),
            textMuted: text.mix(muted, 0.56),
            textFaint: text.mix(muted, 0.445),
            disabled: muted,
            accent: accent,
            accentHover: accent.mix(text, 0.35),
            onAccent: accent.luminance > 0.5 ? terminal : RGB(0xFFFFFF),
            ansiText: text.mix(muted, 0.08),
            ansiGreen: RGB(g),
            ansiBlue: RGB(b),
            ansiYellow: RGB(y),
            ansiRed: RGB(r),
            ansiDim: text.mix(muted, 0.56)
        )
    }
}
