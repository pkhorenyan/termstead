import SwiftUI

struct AppearanceView: View {
    @Environment(ThemeStore.self) private var themeStore
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var appState

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    @Environment(\.dismiss) private var dismiss
    /// Read each time the window opens, so a font installed meanwhile shows up.
    /// Filled in `onAppear`, not here: a `@State` initial value is evaluated
    /// every time the view is re-created — each theme click — and the full
    /// scan builds an `NSFont` for every fixed-pitch face installed.
    @State private var fontFamilies: [String] = [ThemeStore.bundledFontFamily, ThemeStore.systemFontFamily]
    /// What was in effect when the window opened. Changes preview live across
    /// the app; Cancel — or closing the window — puts this back.
    @State private var original: ThemeStore.Snapshot?
    @State private var didSave = false

    /// A fixed height with the settings scrolling under it: with every row
    /// shown at once the window grew past 1,100pt and put Save off the bottom
    /// of a laptop screen. The footer stays pinned.
    ///
    /// 880 is the Appearance tab's own height (measured: it ended 16pt below
    /// an 860pt window, so it scrolled for the sake of a sliver) with a little
    /// room. With its titlebar the window is 912pt, still inside a 13" Air's
    /// ~919pt of usable height.
    static let windowHeight: CGFloat = 880

    enum SettingsTab: String, CaseIterable, Identifiable {
        case appearance, terminal
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var symbol: String { self == .appearance ? "paintpalette" : "terminal" }
    }

    /// The tab last looked at, remembered for next time.
    @AppStorage("settings.tab") private var tab: SettingsTab = .appearance

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            ScrollView {
                content
                    .background(ThinScroller(isDark: theme.isDark, alwaysVisible: true))
            }
            footer
        }
        .frame(width: 760, height: Self.windowHeight)
        .background(theme.chrome.color)
        // Closes off the titlebar, as in the main window: the background
        // bleeds up under it, so a rule is what marks where it ends.
        .overlay(alignment: .top) { Divider1(theme.border) }
        // Same treatment as the main window: a standard titlebar naming
        // itself through an accessory view, with the window appearance
        // matching the theme so the traffic lights stay legible on the
        // light themes. A 48pt bar of our own pushed the window buttons
        // down and made the titlebar look oversized.
        .background(
            WindowConfigurator(theme: theme,
                               toolbarHeight: Metrics.toolbarHeight,
                               minSize: CGSize(width: 760, height: Self.windowHeight),
                               titlebarTitle: "Settings",
                               frameAutosaveName: "AppearanceWindow")
        )
        // App-modal, like the session and group forms: while it is open
        // the main window takes no input and cannot be moved.
        .background(ModalWhileOpen { appState.isAppearanceOpen = $0 })
        .onAppear {
            original = themeStore.snapshot
            didSave = false
            fontFamilies = ThemeStore.monospacedFamilies()
        }
        .onDisappear {
            // The close button is Cancel too.
            if !didSave, let original { themeStore.restore(original) }
        }
    }

    /// Icon-over-label tabs, as in macOS's own settings windows.
    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases) { candidate in
                let isOn = candidate == tab
                Button { tab = candidate } label: {
                    VStack(spacing: 3) {
                        Image(systemName: candidate.symbol)
                            .font(.system(size: 17, weight: .regular))
                            .frame(height: 20)
                        Text(candidate.label)
                            .font(SBFont.ui(11.5, isOn ? .semibold : .regular))
                    }
                    .foregroundStyle((isOn ? theme.accent : theme.textSecondary).color)
                    .frame(width: 92, height: 50)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isOn ? theme.selected.color : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(candidate.label)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) { Divider1(theme.border) }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            Button("Cancel") {
                if let original { themeStore.restore(original) }
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .buttonStyle(SecondaryButtonStyle(theme: theme, height: 36,
                                              horizontalPadding: 16, fontSize: 13.5))
            Button("Save") {
                didSave = true
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(PrimaryButtonStyle(theme: theme, height: 36,
                                            horizontalPadding: 18, fontSize: 13.5))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .overlay(alignment: .top) { Divider1(theme.border) }
    }

    private var content: some View {
        Group {
            switch tab {
            case .appearance: appearanceTab
            case .terminal: terminalTab
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 24)
    }

    /// What the terminal looks like: theme, text, and a live preview.
    private var appearanceTab: some View {
        @Bindable var themeStore = themeStore

        return VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Theme")
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(Theme.all) { candidate in
                        ThemePreviewCard(
                            candidate: candidate,
                            isSelected: candidate.id == themeStore.selectedID,
                            chromeTheme: theme
                        ) {
                            themeStore.select(candidate)
                        }
                    }
                }
            }

            settingsGroup {
                settingsRow("Follow macOS light / dark mode", caption: themeStore.systemNote) {
                    settingSwitch($themeStore.followSystem, label: "Follow macOS light / dark mode")
                }
            }

            section("Text") { textGroup }

            VStack(alignment: .leading, spacing: 8) {
                Text("Preview · \(themeStore.selected.name)")
                    .font(SBFont.ui(12))
                    .foregroundStyle(theme.textFaint.color)
                // Three lines: enough to show the theme's colours, the font
                // and the cursor, without the tab outgrowing the window.
                preview
                    .frame(height: 96)
            }
        }
    }

    /// How the terminal behaves.
    private var terminalTab: some View {
        @Bindable var themeStore = themeStore
        let rightClick = Binding<RightClick>(
            get: { themeStore.rightClickPastes ? .paste : .menu },
            set: { themeStore.rightClickPastes = $0 == .paste }
        )

        let scrollback = Binding<ScrollbackChoice>(
            get: { ScrollbackChoice(lines: themeStore.scrollbackLines) },
            set: { themeStore.scrollbackLines = $0.lines }
        )

        return VStack(alignment: .leading, spacing: 20) {
            // Here rather than on Appearance, which is already as tall as the
            // window and would have to scroll for one more row.
            section("Window") {
                settingsGroup {
                    settingsRow("Sidebar",
                                caption: "Sessions and SFTP on the \(themeStore.sidebarSide.rawValue) of the window.") {
                        segmented(ThemeStore.SidebarSide.allCases, selection: $themeStore.sidebarSide,
                                  label: \.label, title: "Sidebar side")
                            .frame(width: 160)
                    }
                    divider
                    settingsRow("Open SFTP after login",
                                caption: "The sidebar turns to the server's files once a new connection is in.") {
                        settingSwitch($themeStore.showFilesAfterLogin, label: "Open SFTP after login")
                    }
                }
            }
            section("History") {
                settingsGroup {
                    settingsRow("Scrollback", caption: "Lines each tab keeps above the screen.") {
                        segmented(ThemeStore.scrollbackChoices.map(ScrollbackChoice.init), selection: scrollback,
                                  label: \.label, title: "Scrollback lines")
                            .frame(width: 250)
                    }
                }
            }
            section("Mouse & Clipboard") {
                settingsGroup {
                    settingsRow("Right click",
                                caption: themeStore.rightClickPastes
                                    ? "Pastes — ⌃-click still opens the menu."
                                    : "Opens Copy, Paste and Select All.") {
                        segmented(RightClick.allCases, selection: rightClick, label: \.label, title: "Right click")
                            .frame(width: 180)
                    }
                    divider
                    settingsRow("Copy text when selected") {
                        settingSwitch($themeStore.copyOnSelect, label: "Copy text when selected")
                    }
                    divider
                    settingsRow("Ask before pasting several lines",
                                caption: "Each pasted line may otherwise run as a command.") {
                        settingSwitch($themeStore.confirmMultilinePaste, label: "Ask before pasting several lines")
                    }
                }
            }

            section("Highlighting") {
                settingsGroup {
                    settingsRow("Highlight keywords",
                                caption: highlightCaption) {
                        segmented(KeywordHighlighter.Mode.allCases, selection: $themeStore.highlighting,
                                  label: \.label, title: "Keyword highlighting")
                            .frame(width: 260)
                    }
                }
            }

            section("Keyboard") {
                settingsGroup {
                    settingsRow("Option key as Meta",
                                caption: themeStore.optionAsMeta
                                    ? "⌥ sends Alt shortcuts to the shell, Emacs or mc."
                                    : "⌥ types characters such as @, € and #.") {
                        settingSwitch($themeStore.optionAsMeta, label: "Option key as Meta")
                    }
                }
            }

            section("Alerts") {
                settingsGroup {
                    settingsRow("Bell", caption: "When a program rings — say, Tab with nothing to complete.") {
                        segmented(ThemeStore.BellMode.allCases, selection: $themeStore.bell,
                                  label: \.label, title: "Terminal bell")
                            .frame(width: 210)
                    }
                    divider
                    settingsRow("Ask before closing a live connection",
                                caption: "Closing its tab or quitting Termstead ends the ssh session.") {
                        settingSwitch($themeStore.confirmClosingConnection,
                                      label: "Ask before closing a live connection")
                    }
                }
            }
        }
    }

    private var panel: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(theme.inset.color)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.border.color, lineWidth: 1))
    }

    private var highlightCaption: String {
        switch themeStore.highlighting {
        case .off: "Output is shown as the server sends it."
        case .standard: "Errors, warnings, success, IP addresses and URLs — where the server sent no colour."
        case .network: "The standard set plus interface names, up/down and MAC addresses."
        }
    }

    private func section(_ title: String, @ViewBuilder _ body: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(title)
            body()
        }
    }

    /// The terminal's text, one row per setting: the name on the left, its
    /// control on the right — the way System Settings lays them out, so every
    /// control lines up on the same edge at the same height.
    private var textGroup: some View {
        @Bindable var themeStore = themeStore

        return settingsGroup {
            settingsRow("Font") {
                HStack(spacing: 8) {
                    FontPopUp(families: fontFamilies,
                              selection: themeStore.terminalFontFamily,
                              onSelect: { themeStore.terminalFontFamily = $0 })
                        .frame(width: 190)
                    stepperButton("−") { themeStore.nudgeFontSize(by: -1) }
                        .accessibilityLabel("Smaller font")
                    Text("\(themeStore.terminalFontSize)")
                        .font(SBFont.mono(13))
                        .foregroundStyle(theme.text.color)
                        .frame(width: 22)
                        .accessibilityLabel("Font size \(themeStore.terminalFontSize)")
                    stepperButton("+") { themeStore.nudgeFontSize(by: 1) }
                        .accessibilityLabel("Larger font")
                }
            }
            divider
            settingsRow("Cursor") {
                segmented(ThemeStore.CursorShape.allCases, selection: $themeStore.cursorShape,
                          label: \.label, title: "Cursor shape")
                    .frame(width: 250)
            }
            divider
            settingsRow("Blinking cursor") {
                settingSwitch($themeStore.cursorBlinks, label: "Blinking cursor")
            }
        }
    }

    private struct ScrollbackChoice: Identifiable, Hashable {
        var lines: Int
        var id: Int { lines }
        var label: String { lines >= 1_000 ? "\(lines / 1_000)K" : "\(lines)" }
    }

    private enum RightClick: String, CaseIterable, Identifiable {
        case menu, paste
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    // MARK: - Row building blocks

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(SBFont.ui(13, .semibold))
            .foregroundStyle(theme.text.color)
    }

    private func settingsGroup(@ViewBuilder _ rows: () -> some View) -> some View {
        VStack(spacing: 0) { rows() }
            .frame(maxWidth: .infinity)
            .background(panel)
    }

    /// Title (and an optional caption) on the left, the control on the right.
    private func settingsRow(_ title: String, caption: String? = nil,
                             @ViewBuilder control: () -> some View) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(SBFont.ui(13))
                    .foregroundStyle(theme.text.color)
                if let caption {
                    Text(caption)
                        .font(SBFont.ui(12))
                        .foregroundStyle(theme.textFaint.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            control()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
    }

    private var divider: some View {
        Divider1(theme.border).padding(.leading, 14)
    }

    private func settingSwitch(_ isOn: Binding<Bool>, label: String) -> some View {
        Toggle("", isOn: isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(theme.accent.color)
            .accessibilityLabel(label)
    }

    private func segmented<Option: Identifiable & Hashable>(
        _ options: [Option], selection: Binding<Option>, label: @escaping (Option) -> String, title: String
    ) -> some View {
        SegmentedPicker(options: options, selection: selection, label: label, title: title,
                        height: 28, fontSize: 12.5, segmentCornerRadius: 6, cornerRadius: 8)
    }

    private func stepperButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 16))
                .foregroundStyle(theme.text.color)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.elevated.color)
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(theme.border.color, lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
    }

    /// Live sample of the picked theme at the chosen font size.
    private var preview: some View {
        let sample = themeStore.selected
        let size = CGFloat(themeStore.terminalFontSize)

        return VStack(alignment: .leading, spacing: 0) {
            line([("deploy@prod-web-01", sample.ansiGreen), (":", sample.ansiText),
                  ("/var/www/app", sample.ansiBlue), ("$ ls", sample.ansiText)], size: size)
            line([("config  logs  public  src", sample.ansiBlue),
                  ("  docker-compose.yml  README.md", sample.ansiText)], size: size)
            HStack(spacing: 0) {
                line([("deploy@prod-web-01", sample.ansiGreen), (":", sample.ansiText),
                      ("/var/www/app", sample.ansiBlue), ("$ ", sample.ansiText)], size: size)
                previewCursor(color: sample.accent, size: size)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(sample.terminal.color)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(sample.border.color, lineWidth: 1))
        )
    }

    /// The cursor as the terminal will draw it, in the chosen shape.
    private func previewCursor(color: RGB, size: CGFloat) -> some View {
        let cell = CGSize(width: size * 0.6, height: size * 1.1)
        return ZStack(alignment: .bottomLeading) {
            Color.clear.frame(width: cell.width, height: cell.height)
            switch themeStore.cursorShape {
            case .block: Rectangle().fill(color.color).frame(width: cell.width, height: cell.height)
            case .underline: Rectangle().fill(color.color).frame(width: cell.width, height: 2)
            case .bar: Rectangle().fill(color.color).frame(width: 2, height: cell.height)
            }
        }
    }

    private func line(_ runs: [(String, RGB)], size: CGFloat) -> some View {
        runs.reduce(Text("")) { accumulated, run in
            accumulated + Text(run.0).foregroundColor(run.1.color)
        }
        // The chosen family, so the preview shows what the terminal will.
        .font(Font(themeStore.terminalFont as CTFont))
        .frame(height: size * 1.55, alignment: .leading)
    }
}
