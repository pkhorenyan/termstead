import SwiftUI

/// The sidebar's tabs as a strip down its outer edge — the window's left, or
/// its right when the sidebar is moved there — labels running bottom to top,
/// the way MobaXterm lays out Sessions and Sftp.
struct SidebarTabRail: View {
    @Environment(\.theme) private var theme
    @Binding var selection: AppState.SidebarTab
    var side: ThemeStore.SidebarSide = .left

    static let width: CGFloat = 34

    var body: some View {
        VStack(spacing: 2) {
            ForEach(AppState.SidebarTab.allCases) { tab in
                tabButton(tab)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 10)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(theme.chrome.color)
        .overlay(alignment: side == .left ? .trailing : .leading) { Divider1(theme.border, vertical: true) }
    }

    private func tabButton(_ tab: AppState.SidebarTab) -> some View {
        let isOn = tab == selection
        return Button { selection = tab } label: {
            VerticalLabel {
                HStack(spacing: 7) {
                    // Rotated with the text, so it reads upright once the
                    // whole label is turned.
                    Image(systemName: tab.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .rotationEffect(.degrees(90))
                    Text(tab.label)
                        .font(SBFont.ui(13, isOn ? .semibold : .regular))
                }
                .padding(.horizontal, 16)
                .foregroundStyle((isOn ? theme.text : theme.textMuted).color)
            }
            .frame(width: Self.width)
            .background(
                // The selected tab takes the panel's colour and reaches the
                // divider, so it reads as attached to what it shows.
                selectedShape
                    .fill(isOn ? theme.sidebar.color : Color.clear)
                    .padding(side == .left ? .leading : .trailing, 3)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab.label)
        .accessibilityLabel(tab.label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

extension SidebarTabRail {
    /// Rounded on the window's side, square where it meets the panel.
    fileprivate var selectedShape: UnevenRoundedRectangle {
        side == .left
            ? UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 6, style: .continuous)
            : UnevenRoundedRectangle(bottomTrailingRadius: 6, topTrailingRadius: 6, style: .continuous)
    }
}

/// Lays its content out turned a quarter-turn anticlockwise: the space it asks
/// for is the content's with width and height swapped, which `rotationEffect`
/// alone does not do — it only turns the drawing.
private struct VerticalLabel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        QuarterTurn { content.fixedSize().rotationEffect(.degrees(-90)) }
    }
}

private struct QuarterTurn: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let size = subviews.first?.sizeThatFits(.unspecified) else { return .zero }
        return CGSize(width: size.height, height: size.width)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
                              proposal: .unspecified)
    }
}
