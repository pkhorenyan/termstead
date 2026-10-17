import SwiftUI

/// One theme in the picker: a miniature of the main window painted in that
/// theme's own colors, with its name and light/dark kind underneath.
struct ThemePreviewCard: View {
    var candidate: Theme
    var isSelected: Bool
    /// The currently applied theme, which paints the card's own frame.
    var chromeTheme: Theme
    var onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 8) {
                miniature
                HStack {
                    Text(candidate.name)
                        .font(SBFont.ui(13, .medium))
                        .foregroundStyle(chromeTheme.text.color)
                    Spacer(minLength: 0)
                    Text(candidate.kind.label)
                        .font(SBFont.ui(11.5))
                        .foregroundStyle(chromeTheme.textFaint.color)
                }
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 6)
            .padding(.top, 6)
            .padding(.bottom, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(chromeTheme.inset.color)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? chromeTheme.accent.color : .clear, lineWidth: 2)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel("\(candidate.name), \(candidate.kind.label)")
    }

    private var miniature: some View {
        VStack(spacing: 0) {
            // Title strip with its three dots.
            HStack(spacing: 3) {
                Circle().fill(Color(red: 1, green: 0.373, blue: 0.341)).frame(width: 4, height: 4)
                Circle().fill(Color(red: 0.996, green: 0.737, blue: 0.180)).frame(width: 4, height: 4)
                Circle().fill(Color(red: 0.157, green: 0.784, blue: 0.251)).frame(width: 4, height: 4)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 12)
            .background(candidate.sidebar.color)
            .overlay(alignment: .bottom) { Divider1(candidate.border) }

            HStack(spacing: 0) {
                // Sidebar, reduced to three bars — one of them the accent.
                VStack(alignment: .leading, spacing: 4) {
                    bar(width: 0.8, color: candidate.disabled)
                    bar(width: 0.6, color: candidate.accent)
                    bar(width: 0.7, color: candidate.disabled)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 6)
                .frame(width: 0.3 * 216)
                .background(candidate.sidebar.color)
                .overlay(alignment: .trailing) { Divider1(candidate.border, vertical: true) }

                // Terminal snippet.
                VStack(alignment: .leading, spacing: 3) {
                    miniLine([("deploy@web", candidate.ansiGreen), (":", candidate.text),
                              ("~", candidate.ansiBlue), ("$ ls", candidate.text)])
                    miniLine([("config  src", candidate.ansiBlue), ("  app.yml", candidate.text)])
                    HStack(spacing: 0) {
                        miniLine([("deploy@web", candidate.ansiGreen), (":~$ ", candidate.text)])
                        Rectangle().fill(candidate.text.color).frame(width: 4, height: 8)
                    }
                    Spacer(minLength: 0)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(candidate.terminal.color)
            }
        }
        .frame(height: 84)
        .background(candidate.window.color)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(candidate.border.color, lineWidth: 1)
        )
    }

    private func bar(width: CGFloat, color: RGB) -> some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: 2)
                .fill(color.color)
                .frame(width: proxy.size.width * width, height: 4)
        }
        .frame(height: 4)
    }

    private func miniLine(_ runs: [(String, RGB)]) -> some View {
        runs.reduce(Text("")) { accumulated, run in
            accumulated + Text(run.0).foregroundColor(run.1.color)
        }
        .font(SBFont.mono(8))
        .lineLimit(1)
        .frame(height: 10, alignment: .leading)
    }
}
