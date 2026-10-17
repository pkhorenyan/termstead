import SwiftUI

extension Theme {
    /// Literal, token for token, from the reference mockup. Everything else in
    /// the app is measured against this theme, so it is never derived.
    static let graphite = Theme(
        id: "graphite",
        name: "Graphite",
        kind: .dark,
        window: RGB(0x17191C),
        chrome: RGB(0x1F2227),
        sidebar: RGB(0x1B1E22),
        terminal: RGB(0x0E1012),
        field: RGB(0x141619),
        inset: RGB(0x191C20),
        elevated: RGB(0x25292F),
        selected: RGB(0x2A2E35),
        selectedStrong: RGB(0x2F343C),
        border: RGB(0x2B2F35),
        borderStrong: RGB(0x353A41),
        borderStronger: RGB(0x3A3F46),
        text: RGB(0xE4E6E9),
        textSecondary: RGB(0xAEB5BE),
        textMuted: RGB(0x8A929C),
        textFaint: RGB(0x9BA3AD),
        disabled: RGB(0x4A5058),
        accent: RGB(0x5FD4A8),
        accentHover: RGB(0x8BE3C2),
        onAccent: RGB(0x0E1012),
        ansiText: RGB(0xD7DAE0),
        ansiGreen: RGB(0x7FD88F),
        ansiBlue: RGB(0x6CB6FF),
        ansiYellow: RGB(0xE5C07B),
        ansiRed: RGB(0xF07178),
        ansiDim: RGB(0x8A929C)
    )

    static let daylight = derived(
        id: "daylight", name: "Daylight", kind: .light,
        window: 0xF4F5F7, sidebar: 0xECEEF1, terminal: 0xFFFFFF,
        text: 0x1F2328, muted: 0xC3C8CF, accent: 0x0F8A63,
        green: 0x1A7F37, blue: 0x0A58CA, border: 0xD7DBE0,
        yellow: 0x9A6700, red: 0xCF222E
    )

    static let midnight = derived(
        id: "midnight", name: "Midnight", kind: .dark,
        window: 0x141A26, sidebar: 0x18202E, terminal: 0x0D121C,
        text: 0xDFE6F2, muted: 0x3A4760, accent: 0x7AA2FF,
        green: 0x8BD49C, blue: 0x82B1FF, border: 0x273248,
        yellow: 0xE3C78A, red: 0xFF8A9B
    )

    static let sepia = derived(
        id: "sepia", name: "Sepia", kind: .light,
        window: 0xF3EDE2, sidebar: 0xEBE3D4, terminal: 0xFBF7EF,
        text: 0x3B2F22, muted: 0xCDBFA6, accent: 0xB5562B,
        green: 0x4F6B24, blue: 0x2F5D8A, border: 0xD8CCB6,
        yellow: 0x8A6A1F, red: 0xB3261E
    )

    static let ember = derived(
        id: "ember", name: "Ember", kind: .dark,
        window: 0x1C1714, sidebar: 0x221C18, terminal: 0x120E0C,
        text: 0xEFE6DD, muted: 0x4A3F37, accent: 0xF0A35E,
        green: 0xB5CF6B, blue: 0x86B4D6, border: 0x3A302A,
        yellow: 0xE8C06A, red: 0xEF7A6A
    )

    static let highContrast = derived(
        id: "contrast", name: "High contrast", kind: .dark,
        window: 0x000000, sidebar: 0x0A0A0A, terminal: 0x000000,
        text: 0xFFFFFF, muted: 0x6A6A6A, accent: 0xFFD400,
        green: 0x5DFF7A, blue: 0x6FC3FF, border: 0x5A5A5A,
        yellow: 0xFFD400, red: 0xFF5F5F
    )

    // Four palettes people know from their editors and other terminals, so
    // the app can look like the rest of their setup. The canvas, text and
    // ANSI colors are each palette's own; the chrome around them is derived.

    /// Dracula (draculatheme.com, MIT): its purple doubles as the blue, as in
    /// its own terminal palettes.
    static let dracula = derived(
        id: "dracula", name: "Dracula", kind: .dark,
        window: 0x21222C, sidebar: 0x1E1F29, terminal: 0x282A36,
        text: 0xF8F8F2, muted: 0x535771, accent: 0xBD93F9,
        green: 0x50FA7B, blue: 0xBD93F9, border: 0x343746,
        yellow: 0xF1FA8C, red: 0xFF5555
    )

    /// Nord (nordtheme.com, MIT): Polar Night surfaces, Frost accent.
    static let nord = derived(
        id: "nord", name: "Nord", kind: .dark,
        window: 0x2B303B, sidebar: 0x272C36, terminal: 0x2E3440,
        text: 0xD8DEE9, muted: 0x4C566A, accent: 0x88C0D0,
        green: 0xA3BE8C, blue: 0x81A1C1, border: 0x3B4252,
        yellow: 0xEBCB8B, red: 0xBF616A
    )

    /// Catppuccin Mocha (catppuccin.com, MIT): mantle around a base canvas.
    static let catppuccin = derived(
        id: "catppuccin", name: "Catppuccin", kind: .dark,
        window: 0x1B1B29, sidebar: 0x181825, terminal: 0x1E1E2E,
        text: 0xCDD6F4, muted: 0x45475A, accent: 0xCBA6F7,
        green: 0xA6E3A1, blue: 0x89B4FA, border: 0x313244,
        yellow: 0xF9E2AF, red: 0xF38BA8
    )

    /// Solarized Light (ethanschoonover.com/solarized, MIT). Text is base02,
    /// not the low-contrast base00 body color, so the find match stays
    /// readable.
    static let solarized = derived(
        id: "solarized", name: "Solarized", kind: .light,
        window: 0xF5EFDC, sidebar: 0xEEE8D5, terminal: 0xFDF6E3,
        text: 0x073642, muted: 0xC9C4B0, accent: 0x268BD2,
        green: 0x859900, blue: 0x268BD2, border: 0xDCD5BF,
        yellow: 0xB58900, red: 0xDC322F
    )

    /// Order matches the 5×2 grid on the Appearance screen.
    static let all: [Theme] = [graphite, daylight, midnight, sepia, ember,
                               highContrast, dracula, solarized, nord, catppuccin]

    static func named(_ id: String) -> Theme {
        all.first { $0.id == id } ?? .graphite
    }

    /// The theme used when the system is in light mode and the user asked to
    /// follow it. Their own pick wins if it is already a light theme.
    static let systemLight = daylight
}
