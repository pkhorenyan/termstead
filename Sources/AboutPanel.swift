import AppKit

/// The standard About panel, with the program's website and its source
/// under the version — the panel itself has no place for a link.
enum AboutPanel {
    static let website = URL(string: "https://khorenyan.com/termstead/")!
    static let source = URL(string: "https://github.com/pkhorenyan/termstead")!

    @MainActor
    static func show() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    /// Two centred links. The panel is AppKit's own and follows the
    /// system's colours, not the theme's, so the plain text takes the
    /// system's secondary label colour to stay readable in both modes.
    static var credits: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 4
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let text = NSMutableAttributedString()
        func line(_ label: String, _ url: URL, _ shown: String) {
            text.append(NSAttributedString(string: label, attributes: [
                .font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph,
            ]))
            text.append(NSAttributedString(string: shown, attributes: [
                .font: font, .link: url, .paragraphStyle: paragraph,
            ]))
        }
        line("Website: ", website, "khorenyan.com/termstead")
        text.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraph]))
        line("Source: ", source, "github.com/pkhorenyan/termstead")
        return text
    }
}
