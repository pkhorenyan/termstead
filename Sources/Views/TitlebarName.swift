import SwiftUI

/// A window's name, shown inside the real titlebar as a leading accessory view.
///
/// It used to be a 50pt bar of our own drawn under the titlebar. At the
/// standard 28pt that bar stops painting altogether — SwiftUI drops a row whose
/// height matches the top safe-area inset it was told to ignore — and a taller
/// one is not a titlebar. An `NSTitlebarAccessoryViewController` is the native
/// way to put something next to the window buttons, and it keeps the titlebar
/// at its normal height.
struct TitlebarName: View {
    var theme: Theme
    var title: String

    var body: some View {
        Text(title)
            .font(SBFont.ui(13, .semibold))
            .foregroundStyle(theme.text.color)
            .kerning(0.13)
            // Held to the leading edge: the accessory is wider than the name,
            // and centred in it the name sat ~40pt from the window buttons.
            .frame(maxWidth: .infinity, maxHeight: Metrics.toolbarHeight, alignment: .leading)
    }
}

/// The gear at the trailing end of the titlebar, which opens Appearance.
///
/// It replaces the "Theme" button that used to sit in the toolbar. There is no
/// toolbar left to put it in, and a titlebar is the conventional home for a
/// single settings affordance.
struct TitlebarActions: View {
    var theme: Theme
    /// The pane layout buttons, beside the gear. Absent in a window without panes.
    var layout: PaneLayout?
    var onLayout: (PaneLayout) -> Void = { _ in }
    /// Broadcast input: on, and whether the layout allows it (split only).
    var broadcasting = false
    var canBroadcast = false
    var onBroadcast: () -> Void = {}
    var onOpenAppearance: () -> Void

    /// Wide enough for the broadcast and layout buttons and the gear.
    static func width(withLayouts: Bool) -> CGFloat {
        withLayouts ? 38 + CGFloat(PaneLayout.allCases.count + 1) * 26 + 18 : 38
    }

    var body: some View {
        HStack(spacing: 0) {
            if let layout {
                broadcastButton
                    .padding(.trailing, 8)
                HStack(spacing: 0) {
                    ForEach(PaneLayout.allCases, id: \.self) { candidate in
                        layoutButton(candidate, isOn: candidate == layout)
                    }
                }
                .padding(.trailing, 10)
            }
            gear
        }
    }

    /// Yellow while on: typing goes to several servers at once.
    private var broadcastButton: some View {
        Button(action: onBroadcast) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle((broadcasting ? theme.ansiYellow : canBroadcast ? theme.textMuted : theme.textFaint).color)
                .frame(width: 24, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(broadcasting ? theme.ansiYellow.color.opacity(0.18) : Color.clear)
                )
                .frame(width: 26, height: Metrics.toolbarHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canBroadcast)
        .help(canBroadcast ? (broadcasting ? "Stop broadcasting input (⌥⌘I)"
                                           : "Broadcast input to every visible pane (⌥⌘I)")
                           : "Split the window to broadcast input to several panes")
        .accessibilityLabel("Broadcast input")
        .accessibilityAddTraits(broadcasting ? .isSelected : [])
    }

    private func layoutButton(_ candidate: PaneLayout, isOn: Bool) -> some View {
        Button { onLayout(candidate) } label: {
            Image(systemName: candidate.symbol)
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle((isOn ? theme.text : theme.textMuted).color)
                .frame(width: 24, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isOn ? theme.selected.color : Color.clear)
                )
                .frame(width: 26, height: Metrics.toolbarHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(candidate.help)
        .accessibilityLabel(candidate.title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var gear: some View {
        Button(action: onOpenAppearance) {
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.textSecondary.color)
                .frame(width: 30, height: Metrics.toolbarHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, 8)
        .accessibilityLabel("Appearance")
    }
}

extension PaneLayout {
    var symbol: String {
        switch self {
        case .single: "rectangle"
        case .sideBySide: "rectangle.split.2x1"
        case .stacked: "rectangle.split.1x2"
        case .grid: "rectangle.split.2x2"
        }
    }

    /// The View menu's names.
    var title: String {
        switch self {
        case .single: "Single Pane"
        case .sideBySide: "Split Vertically"
        case .stacked: "Split Horizontally"
        case .grid: "Four Panes"
        }
    }

    var help: String {
        switch self {
        case .single: "One pane"
        case .sideBySide: "Two panes side by side (⌘D)"
        case .stacked: "Two panes, one above the other (⇧⌘D)"
        case .grid: "Four panes"
        }
    }
}
