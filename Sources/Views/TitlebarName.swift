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
    var onOpenAppearance: () -> Void

    var body: some View {
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
