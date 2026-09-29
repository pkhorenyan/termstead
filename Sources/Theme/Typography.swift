import SwiftUI

/// The bundled faces.
///
/// The static TTFs register Medium and SemiBold as *separate families*
/// ("IBM Plex Sans Medm", "IBM Plex Sans SmBld"), so asking for
/// `.weight(.medium)` on the base family would silently synthesise a weight
/// instead of using the real one. Every weight is therefore addressed by its
/// own PostScript name.
enum SBFont {
    enum UIWeight {
        case regular, medium, semibold

        var postScriptName: String {
            switch self {
            case .regular: "IBMPlexSans"
            case .medium: "IBMPlexSans-Medm"
            case .semibold: "IBMPlexSans-SmBld"
            }
        }
    }

    /// Regular and Bold only: nothing is set in a medium monospace, and
    /// SwiftTerm finds Bold through the family for bold terminal text. The
    /// Medium face was 268 KB of the bundle for no use.
    enum MonoWeight {
        case regular, bold

        var postScriptName: String {
            switch self {
            case .regular: "JetBrainsMono-Regular"
            case .bold: "JetBrainsMono-Bold"
            }
        }
    }

    /// Sizes come straight from the mockup's CSS pixels, so they are fixed
    /// rather than text-style relative.
    static func ui(_ size: CGFloat, _ weight: UIWeight = .regular) -> Font {
        .custom(weight.postScriptName, fixedSize: size)
    }

    static func mono(_ size: CGFloat, _ weight: MonoWeight = .regular) -> Font {
        .custom(weight.postScriptName, fixedSize: size)
    }

    static func nsUI(_ size: CGFloat, _ weight: UIWeight = .regular) -> NSFont {
        NSFont(name: weight.postScriptName, size: size)
            ?? .systemFont(ofSize: size)
    }

    static func nsMono(_ size: CGFloat, _ weight: MonoWeight = .regular) -> NSFont {
        NSFont(name: weight.postScriptName, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Logs the faces that failed to register. Called once at launch so a
    /// missing or misnamed TTF surfaces immediately instead of as silent
    /// fallback text in Helvetica.
    static func verifyBundledFonts() {
        let expected = [UIWeight.regular, .medium, .semibold].map(\.postScriptName)
            + [MonoWeight.regular, .bold].map(\.postScriptName)
        let missing = expected.filter { NSFont(name: $0, size: 12) == nil }
        if !missing.isEmpty {
            print("[Termstead] bundled fonts failed to register: \(missing.joined(separator: ", "))")
        }
    }
}
