import SwiftUI

/// A swatch offered for a group. `nil` is the first entry — "No color" — and
/// means the group inherits from its parent.
///
/// Each swatch carries two values. The pastels were tuned against the dark
/// themes; as plain text on a light sidebar they fall to about 3:1, and simply
/// darkening them towards the text color until they read takes so much of the
/// chroma out that the eight become hard to tell apart. So the light themes get
/// their own dark-on-light variants instead, the same way each theme defines
/// its own ANSI colors. Every variant clears 4.5:1 against both light themes'
/// sidebar and selected-row backgrounds.
struct GroupColor: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    /// Shown on the swatch itself and used on the dark themes.
    let rgb: RGB?
    /// Used wherever the color carries text or a glyph on a light theme.
    let onLight: RGB?

    private init(id: String, label: String, dark: UInt32?, light: UInt32?) {
        self.id = id
        self.label = label
        rgb = dark.map(RGB.init)
        onLight = light.map(RGB.init)
    }

    private init(id: String, label: String, rgb: RGB, onLight: RGB) {
        self.id = id
        self.label = label
        self.rgb = rgb
        self.onLight = onLight
    }

    static let palette: [GroupColor] = [
        GroupColor(id: "none", label: "No color", dark: nil, light: nil),
        GroupColor(id: "mint", label: "Mint", dark: 0x5FD4A8, light: 0x0E663B),
        GroupColor(id: "blue", label: "Blue", dark: 0x6CB6FF, light: 0x0953BF),
        GroupColor(id: "violet", label: "Violet", dark: 0xB392F0, light: 0x6034B0),
        GroupColor(id: "pink", label: "Pink", dark: 0xF38BA8, light: 0xA2295D),
        GroupColor(id: "red", label: "Red", dark: 0xF07178, light: 0xAB241D),
        GroupColor(id: "orange", label: "Orange", dark: 0xF5A97F, light: 0x874A00),
        GroupColor(id: "yellow", label: "Yellow", dark: 0xE5C07B, light: 0x6F5400),
        GroupColor(id: "gray", label: "Gray", dark: 0x9BA3AD, light: 0x515B64),
    ]

    static func swatch(for id: String?) -> GroupColor? {
        guard let id else { return nil }
        if isCustom(id) { return custom(id) }
        return palette.first { $0.id == id }
    }

    /// The color a session shows, given its own and the one its groups pass
    /// down. A colored group decides for every session in it; a session's
    /// own color counts only where no group colors it (none set, or "No
    /// color"). Its own stays stored meanwhile, and shows again once the
    /// session is moved out.
    static func sessionColorID(own: String?, inherited: String?) -> String? {
        rgb(for: inherited) != nil ? inherited : (own ?? inherited)
    }

    // MARK: - Custom colors

    /// A color picked by hand is stored as its hex, `#RRGGBB`, in the same
    /// field a palette id goes in — so everything that resolves a color id
    /// handles it without knowing.
    static func isCustom(_ id: String?) -> Bool { id?.hasPrefix("#") == true }

    static func customID(_ color: RGB) -> String { color.hex }

    /// The picked color itself, as shown on its swatch.
    static func picked(_ id: String?) -> RGB? {
        guard let id, isCustom(id) else { return nil }
        return RGB(hex: id)
    }

    /// Like the palette, a custom color gets one variant per kind of theme,
    /// each nudged — towards white on the dark themes, black on the light
    /// ones — only as far as it takes to clear 4.5:1, and held to the bar the
    /// palette itself meets: every sidebar on the dark themes, and every
    /// sidebar and selected row on the light ones. (High Contrast's selected
    /// row is light; even the palette's red is 2.6:1 on it, and chasing it
    /// would bleach every custom color.) A color that already reads stays as
    /// picked.
    private static func custom(_ id: String) -> GroupColor? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = customCache[id] { return cached }
        guard let picked = RGB(hex: id) else { return nil }
        let made = GroupColor(id: id, label: "Custom",
                              rgb: readable(picked, against: Theme.all.filter(\.isDark).map(\.sidebar),
                                            toward: RGB(0xFFFFFF)),
                              onLight: readable(picked, against: Theme.all.filter { !$0.isDark }
                                                  .flatMap { [$0.sidebar, $0.selected] },
                                                toward: RGB(0x000000)))
        customCache[id] = made
        return made
    }

    static let minimumContrast = 4.5

    static func readable(_ color: RGB, against backgrounds: [RGB], toward target: RGB) -> RGB {
        func reads(_ candidate: RGB) -> Bool {
            backgrounds.allSatisfy { candidate.contrast(with: $0) >= minimumContrast }
        }
        var step = 0.0
        while step <= 1 {
            let candidate = color.mix(target, step)
            if reads(candidate) { return candidate }
            step += 0.02
        }
        return target
    }

    /// Resolving happens per sidebar row per render; the derivation walks
    /// every theme, so it is done once per color.
    nonisolated(unsafe) private static var customCache: [String: GroupColor] = [:]
    private static let cacheLock = NSLock()

    /// The color as shown on the swatch — always the dark-theme pastel.
    static func rgb(for id: String?) -> RGB? {
        swatch(for: id)?.rgb
    }

    /// The variant to use for text and glyphs on the given theme.
    static func rgb(for id: String?, on theme: Theme) -> RGB? {
        guard let swatch = swatch(for: id) else { return nil }
        return theme.isDark ? swatch.rgb : swatch.onLight
    }
}

extension RGB {
    /// Alpha steps the mockup uses for group tints: `color + '26'` for a tile
    /// background, `'59'` for a tree guide, `'80'` for an inactive tab line.
    var tileFill: Color { color(0x26 / 255) }
    var guideStroke: Color { color(0x59 / 255) }
    var halfStrength: Color { color(0x80 / 255) }
}
