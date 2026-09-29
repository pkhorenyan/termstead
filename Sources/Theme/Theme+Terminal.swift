import Foundation

extension Theme {
    /// The sixteen ANSI colours the terminal needs, in xterm order: black, red,
    /// green, yellow, blue, magenta, cyan, white, then the bright set.
    ///
    /// Themes publish only five of them — the ones the mockup's transcript used.
    /// Magenta and cyan are mixed from their neighbours, and the bright set is
    /// pushed away from the canvas, so every theme gets a full palette without
    /// eleven more seeds each. Black and white are chosen per kind: on a light
    /// canvas "white" text would vanish, so it is a mid grey there.
    var terminalPalette: [RGB] {
        let white = RGB(0xFFFFFF), black = RGB(0x000000)
        let magenta = ansiRed.mix(ansiBlue, 0.5)
        let cyan = ansiGreen.mix(ansiBlue, 0.5)
        let ansiBlack = isDark ? terminal.mix(text, 0.22) : text
        let ansiWhite = isDark ? ansiText : terminal.mix(text, 0.45)

        let normal = [ansiBlack, ansiRed, ansiGreen, ansiYellow, ansiBlue, magenta, cyan, ansiWhite]
        let brighten: (RGB) -> RGB = { $0.mix(self.isDark ? white : black, 0.2) }
        let bright = [ansiDim] + normal[1...6].map(brighten) + [isDark ? text.mix(white, 0.5) : text.mix(terminal, 0.3)]
        return normal + bright
    }

    /// The find match: a solid fill with a text color of its own, the way a
    /// highlighter marks paper. It used to be the selection — a translucent
    /// accent over each cell's own text — which stood out from the canvas by
    /// only 1.4:1 in the light themes and about 2:1 in the dark ones.
    /// The dark themes fill with their own yellow under canvas-dark text
    /// (11:1 and up against the canvas). The light ones have no yellow light
    /// enough to carry dark text, so they share an orange: luminance alone
    /// gives it ~1.9:1 on the canvas, its chroma does the rest, and the text
    /// on it keeps 6.5:1 or better.
    var findMatch: RGB { isDark ? ansiYellow : Self.lightFindMatch }
    var onFindMatch: RGB { isDark ? terminal : text }

    private static let lightFindMatch = RGB(0xFFA51F)
}
