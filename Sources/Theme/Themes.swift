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

    /// Order matches the 3×2 grid on the Appearance screen.
    static let all: [Theme] = [graphite, daylight, midnight, sepia, ember, highContrast]

    static func named(_ id: String) -> Theme {
        all.first { $0.id == id } ?? .graphite
    }

    /// The theme used when the system is in light mode and the user asked to
    /// follow it. Their own pick wins if it is already a light theme.
    static let systemLight = daylight
}
