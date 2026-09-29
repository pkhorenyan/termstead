import AppKit
import SwiftUI

/// The terminal font menu: a native pop-up button, each family's name set in
/// its own face.
///
/// It replaced a SwiftUI popover whose list came up empty. The Appearance
/// window runs app-modal, and the popover's SwiftUI content was evidently not
/// laid out in that run-loop mode; an `NSPopUpButton` builds and draws its
/// menu itself, so nothing depends on SwiftUI updating at the time.
struct FontPopUp: NSViewRepresentable {
    var families: [String]
    var selection: String
    var onSelect: (String) -> Void

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.picked(_:))
        button.setAccessibilityLabel("Terminal font")
        (button.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingTail
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.onSelect = onSelect
        Self.configure(button, families: families, selection: selection)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    /// As wide as it is given, not as wide as its longest family name: its
    /// intrinsic width pushed the font panel wider than the one beside it.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 180, height: nsView.intrinsicContentSize.height)
    }

    /// Rebuilds the items only when the list changed, then selects `selection`.
    static func configure(_ button: NSPopUpButton, families: [String], selection: String) {
        let current = button.itemArray.compactMap { $0.representedObject as? String }
        if current != families {
            button.removeAllItems()
            for family in families {
                let item = NSMenuItem(title: family, action: nil, keyEquivalent: "")
                item.representedObject = family
                item.attributedTitle = title(for: family)
                button.menu?.addItem(item)
            }
        }
        if let index = families.firstIndex(of: selection) {
            button.selectItem(at: index)
        }
    }

    private static func title(for family: String) -> NSAttributedString {
        let face = ThemeStore.font(family: family, size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        let text = NSMutableAttributedString(string: family, attributes: [.font: face])
        if family == ThemeStore.bundledFontFamily {
            text.append(NSAttributedString(string: "  Built in", attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        return text
    }

    @MainActor
    final class Coordinator: NSObject {
        var onSelect: (String) -> Void

        init(onSelect: @escaping (String) -> Void) { self.onSelect = onSelect }

        @objc func picked(_ sender: NSPopUpButton) {
            guard let family = sender.selectedItem?.representedObject as? String else { return }
            onSelect(family)
        }
    }
}
