import AppKit
import SwiftUI

/// Label above a form control, at the design's caption size.
struct FormLabel: View {
    @Environment(\.theme) private var theme
    private let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(SBFont.ui(12.5))
            .foregroundStyle(theme.textSecondary.color)
    }
}

struct FormField<Content: View>: View {
    var label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FormLabel(label)
            content
        }
    }
}

/// Text input matching the design's well, with an optional accent focus ring.
struct SBTextField: View {
    @Environment(\.theme) private var theme
    @Binding var text: String
    var placeholder: String
    var font: Font
    /// Draws the accent border the mockup shows on the field being edited.
    var focused: Bool = false
    var isSecure: Bool = false

    var body: some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(font)
        .foregroundStyle(theme.text.color)
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(FieldBackground(theme: theme, focused: focused))
    }
}

/// Quiet panel used for explanatory notes inside a sheet.
struct InsetNote: View {
    @Environment(\.theme) private var theme
    var text: String

    var body: some View {
        Text(text)
            .font(SBFont.ui(12.5))
            .foregroundStyle(theme.textFaint.color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.inset.color)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.border.color, lineWidth: 1))
            )
    }
}

/// Title, subtitle and a rule — shared by every sheet.
struct SheetHeader: View {
    @Environment(\.theme) private var theme
    var title: String
    var subtitle: String
    var horizontalPadding: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(SBFont.ui(18, .semibold))
                .foregroundStyle(theme.text.color)
            Text(subtitle)
                .font(SBFont.ui(13))
                .foregroundStyle(theme.textFaint.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, horizontalPadding)
        // The form window's titlebar sits above this as safe area, so only a
        // small gap is needed; 22 was right for a sheet, which has no titlebar.
        .padding(.top, 4)
        .padding(.bottom, 16)
        .overlay(alignment: .bottom) { Divider1(theme.border) }
    }
}

/// The round swatch row used wherever a group color is chosen.
struct ColorSwatchRow: View {
    @Environment(\.theme) private var theme
    /// `nil` inherits the parent's color, `"none"` is explicitly no color —
    /// which also stops the parent's color reaching anything inside — and
    /// anything else is a palette color.
    @Binding var selection: String?
    var surface: RGB
    /// The parent's color, when it has one. Only then is inheriting a choice
    /// of its own; otherwise it looks and acts exactly like no color.
    var inherited: RGB?
    var diameter: CGFloat = 28

    var body: some View {
        // Spread across the form's width, first swatch at the leading edge
        // and last at the trailing one. Packed at 6pt they left the right
        // third of the row empty, and the row looked shifted left.
        JustifiedRow(minSpacing: 6) {
            if let inherited {
                swatch(isOn: selection == nil, label: "Inherit from parent") {
                    selection = nil
                } content: {
                    Circle()
                        .strokeBorder(theme.textMuted.color, style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
                        .overlay(Circle().fill(inherited.color).padding(8))
                }
            }
            ForEach(GroupColor.palette) { color in
                if color.rgb == nil {
                    swatch(isOn: selection == "none" || (selection == nil && inherited == nil),
                           label: "No color") {
                        selection = "none"
                    } content: {
                        Circle()
                            .strokeBorder(theme.textMuted.color, lineWidth: 2)
                            .overlay(
                                Rectangle()
                                    .fill(theme.textMuted.color)
                                    .frame(width: 2, height: diameter - 6)
                                    .rotationEffect(.degrees(45))
                            )
                    }
                } else {
                    swatch(isOn: selection == color.id, label: color.label) {
                        selection = color.id
                    } content: {
                        Circle().fill(color.rgb?.color ?? .clear)
                    }
                }
            }
            customSwatch
        }
        .padding(.vertical, 3)
        .onDisappear { ColorPickerWindow.close() }
    }

    /// Any color at all, from `ColorPickerWindow`. Before one is picked it
    /// is a wheel of the palette's own hues; after, the color itself.
    private var customSwatch: some View {
        let picked = GroupColor.picked(selection)
        return swatch(isOn: picked != nil, label: "Custom color…") {
            let start = picked ?? GroupColor.rgb(for: selection) ?? inherited ?? theme.accent
            ColorPickerWindow.present(start: start, over: NSApp.keyWindow, theme: theme) {
                selection = GroupColor.customID($0)
            }
        } content: {
            if let picked {
                Circle().fill(picked.color)
            } else {
                // A whole disc: with a hole cut in the middle it read as a
                // ring around a dark dot.
                let hues = GroupColor.palette.compactMap { $0.rgb?.color }
                Circle()
                    .fill(AngularGradient(colors: hues + hues.prefix(1), center: .center))
            }
        }
    }

    private func swatch(isOn: Bool, label: String, action: @escaping () -> Void,
                        @ViewBuilder content: () -> some View) -> some View {
        Button(action: action) {
            content()
                .frame(width: diameter, height: diameter)
                .overlay {
                    if isOn {
                        Circle().strokeBorder(surface.color, lineWidth: 2)
                            .padding(-1)
                            .overlay(Circle().strokeBorder(theme.text.color, lineWidth: 2)
                                .padding(-3))
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Lays its items out in one row across the width it is offered: the first at
/// the leading edge, the last at the trailing edge, the gaps between them
/// equal (and at least `minSpacing`).
struct JustifiedRow: Layout {
    var minSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let natural = sizes.reduce(0) { $0 + $1.width } + minSpacing * CGFloat(max(0, sizes.count - 1))
        let height = sizes.map(\.height).max() ?? 0
        return CGSize(width: max(natural, proposal.width ?? natural), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let content = sizes.reduce(0) { $0 + $1.width }
        let gap = sizes.count > 1
            ? max(minSpacing, (bounds.width - content) / CGFloat(sizes.count - 1))
            : 0
        var x = bounds.minX
        for (subview, size) in zip(subviews, sizes) {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(size))
            x += size.width + gap
        }
    }
}

/// The list of groups a session or group can live in, with "Top level" first
/// when that is allowed.
struct ParentGroupList: View {
    @Environment(\.theme) private var theme
    var options: [ParentOption]
    @Binding var selection: String?

    struct ParentOption: Identifiable, Hashable {
        let id: String?
        let label: String
        let depth: Int
        let colorID: String?
        /// Greyed out because selecting it would move a group inside itself.
        var isDisabled: Bool = false

        var identifier: String { id ?? "__top__" }
    }

    var body: some View {
        VStack(spacing: 1) {
            ForEach(options, id: \.identifier) { option in
                row(option)
            }
        }
        .padding(4)
        .background(FieldBackground(theme: theme, cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Parent group")
    }

    private func row(_ option: ParentOption) -> some View {
        let isOn = option.id == selection
        let color = GroupColor.rgb(for: option.colorID)
        let label = option.isDisabled ? theme.disabled : (isOn ? theme.text : theme.textSecondary)

        return Button {
            selection = option.id
        } label: {
            HStack(spacing: 8) {
                Image(systemName: color == nil ? "folder" : "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle((option.isDisabled ? theme.disabled : (color ?? theme.textMuted)).color)
                Text(option.label)
                    .font(SBFont.ui(13))
                    .foregroundStyle(label.color)
                Spacer(minLength: 0)
            }
            .padding(.leading, 10 + CGFloat(option.depth) * 18)
            .padding(.trailing, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isOn ? theme.selectedStrong.color : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(option.isDisabled)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// The pill of mutually exclusive options the mockup draws for "Authentication".
///
/// Shared rather than inlined because a jump host picks its auth the same way
/// the session does, only smaller — the defaults here are the session's sizes,
/// so that block looks exactly as it did before this was extracted.
struct SegmentedPicker<Option: Identifiable & Hashable>: View {
    @Environment(\.theme) private var theme
    var options: [Option]
    @Binding var selection: Option
    var label: (Option) -> String
    var title: String
    var height: CGFloat = 32
    var fontSize: CGFloat = 13
    var segmentCornerRadius: CGFloat = 7
    var cornerRadius: CGFloat = 10

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options) { option in
                let isOn = option == selection
                Button { selection = option } label: {
                    Text(label(option))
                        .font(SBFont.ui(fontSize, .medium))
                        .foregroundStyle((isOn ? theme.text : theme.textFaint).color)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: height)
                        .background(
                            RoundedRectangle(cornerRadius: segmentCornerRadius, style: .continuous)
                                .fill(isOn ? theme.selectedStrong.color : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(4)
        .background(FieldBackground(theme: theme, cornerRadius: cornerRadius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// Picks a private key. Starts in `~/.ssh` with hidden files shown, since that
/// is where keys live and half of what is there begins with a dot. Returns the
/// path with the home directory abbreviated to `~`, the way it is displayed and
/// the way ssh_config accepts it.
@MainActor
enum KeyFilePicker {
    static func choose(startingAt current: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "Choose"
        panel.message = "Choose a private key"

        let expanded = (current as NSString).expandingTildeInPath
        let folder = (expanded as NSString).deletingLastPathComponent
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue {
            panel.directoryURL = URL(fileURLWithPath: folder, isDirectory: true)
        } else {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".ssh", isDirectory: true)
        }

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return (url.path as NSString).abbreviatingWithTildeInPath
    }
}
