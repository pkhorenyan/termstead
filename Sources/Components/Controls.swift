import SwiftUI

/// Filled accent button — "Connect", "Trust & connect", "Create group".
struct PrimaryButtonStyle: ButtonStyle {
    var theme: Theme
    var height: CGFloat = 32
    var horizontalPadding: CGFloat = 14
    var fontSize: CGFloat = 13

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SBFont.ui(fontSize, .semibold))
            .foregroundStyle(theme.onAccent.color)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? theme.accentHover.color : theme.accent.color)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Outlined button — "New session", "Cancel", "Choose…".
struct SecondaryButtonStyle: ButtonStyle {
    var theme: Theme
    var height: CGFloat = 32
    var horizontalPadding: CGFloat = 12
    var fontSize: CGFloat = 13
    var filled: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SBFont.ui(fontSize))
            .foregroundStyle(theme.text.color)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? theme.selected.color
                          : (filled ? theme.elevated.color : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(theme.border.color, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Dashed "add" affordance — "+ Session", "+ Group", "Add jump host".
struct DashedButtonStyle: ButtonStyle {
    var theme: Theme
    var height: CGFloat = 34
    var fontSize: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SBFont.ui(fontSize))
            .foregroundStyle(theme.textSecondary.color)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? theme.selected.color : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(theme.borderStronger.color,
                                  style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Square icon-only button used throughout the sidebar and jump-host rows.
struct IconButtonStyle: ButtonStyle {
    var theme: Theme
    var size: CGSize = CGSize(width: 22, height: 22)
    var cornerRadius: CGFloat = 6
    var bordered: Bool = false
    var borderColor: RGB?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: size.width, height: size.height)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(configuration.isPressed ? theme.selected.color : Color.clear)
            )
            .overlay {
                if bordered {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder((borderColor ?? theme.borderStronger).color, lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Recessed well shared by every text field in the design.
struct FieldBackground: View {
    var theme: Theme
    var cornerRadius: CGFloat = 8
    var focused: Bool = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(theme.field.color)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(focused ? theme.accent.color : theme.border.color, lineWidth: 1)
            )
    }
}

/// The bordered ⌘K / ⌘N chips.
struct KeyCap: View {
    var theme: Theme
    var label: String
    var fontSize: CGFloat = 11

    var body: some View {
        Text(label)
            .font(SBFont.mono(fontSize))
            .foregroundStyle(theme.textMuted.color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(theme.border.color, lineWidth: 1)
            )
    }
}

/// Small status dot: connected (accent) or disconnected (red).
struct StatusDot: View {
    var color: Color
    var size: CGFloat = 7

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}
