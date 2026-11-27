import AppKit
import SwiftUI

/// The terminal area, divided as `ConnectionStore.layout` says: one pane, two
/// side by side or stacked, or four. Each pane is a tab strip over the tab in
/// front — everything the single pane always had.
struct PaneLayoutView: View {
    @Environment(ConnectionStore.self) private var connectionStore
    /// Where the dividers sit, as a share of the width and of the height.
    /// Four panes share both, so their dividers cross.
    @AppStorage("panes.columns") private var columns = 0.5
    @AppStorage("panes.rows") private var rows = 0.5

    var body: some View {
        if connectionStore.presentsDesktop {
            PaneView(pane: connectionStore.focusedPane, hidesTabs: true)
        } else {
            switch connectionStore.layout {
            case .single:
                PaneView(pane: 0)
            case .sideBySide:
                PaneSplit(axis: .horizontal, fraction: $columns) { PaneView(pane: 0) } second: { PaneView(pane: 1) }
            case .stacked:
                PaneSplit(axis: .vertical, fraction: $rows) { PaneView(pane: 0) } second: { PaneView(pane: 1) }
            case .grid:
                PaneSplit(axis: .vertical, fraction: $rows) {
                    PaneSplit(axis: .horizontal, fraction: $columns) { PaneView(pane: 0) } second: { PaneView(pane: 1) }
                } second: {
                    PaneSplit(axis: .horizontal, fraction: $columns) { PaneView(pane: 2) } second: { PaneView(pane: 3) }
                }
            }
        }
    }
}

/// Two panes and the divider between them, which can be dragged.
struct PaneSplit<First: View, Second: View>: View {
    enum Axis { case horizontal, vertical }

    @Environment(\.theme) private var theme
    /// `.horizontal` puts the panes side by side.
    var axis: Axis
    @Binding var fraction: Double
    @ViewBuilder var first: First
    @ViewBuilder var second: Second

    /// Neither pane gets narrower than this share.
    static var range: ClosedRange<Double> { 0.2...0.8 }

    static func horizontalRange(available: CGFloat) -> ClosedRange<Double> {
        guard available > 0 else { return 0.5...0.5 }
        let lower = min(0.5, max(range.lowerBound, Double(Metrics.minimumPaneWidth / available)))
        return lower...(1 - lower)
    }

    var body: some View {
        GeometryReader { geometry in
            let total = axis == .horizontal ? geometry.size.width : geometry.size.height
            let available = max(0, total - 1)
            let range = axis == .horizontal ? Self.horizontalRange(available: available) : Self.range
            let firstSize = available * min(max(fraction, range.lowerBound), range.upperBound)
            if axis == .horizontal {
                HStack(spacing: 0) {
                    first.frame(width: firstSize)
                    Divider1(theme.border, vertical: true)
                    second.frame(width: available - firstSize)
                }
                .overlay(alignment: .leading) {
                    handle(total: total, range: range)
                        .frame(width: PaneSplitHandle.grab)
                        .offset(x: firstSize + 0.5 - PaneSplitHandle.grab / 2)
                }
            } else {
                VStack(spacing: 0) {
                    first.frame(height: firstSize)
                    Divider1(theme.border)
                    second.frame(maxHeight: .infinity)
                }
                .overlay(alignment: .top) {
                    handle(total: total, range: range)
                        .frame(height: PaneSplitHandle.grab)
                        .offset(y: firstSize + 0.5 - PaneSplitHandle.grab / 2)
                }
            }
        }
    }

    @ViewBuilder
    private func handle(total: CGFloat, range: ClosedRange<Double>) -> some View {
        let handle = PaneSplitHandle(fraction: $fraction, total: total, vertical: axis == .vertical,
                                     range: range)
        if #available(macOS 15.0, *) {
            handle.pointerStyle(axis == .horizontal ? .columnResize : .rowResize)
        } else {
            handle
        }
    }
}

/// The grab strip on a divider. AppKit for the sidebar handle's reasons (see
/// `SidebarResizeHandle`): a drag here must never move the window, and on
/// macOS 14 the cursor comes from a tracking area.
struct PaneSplitHandle: NSViewRepresentable {
    @Binding var fraction: Double
    var total: CGFloat
    var vertical: Bool
    var range: ClosedRange<Double>

    static let grab: CGFloat = 6

    func makeNSView(context: Context) -> HandleView { HandleView() }

    func updateNSView(_ view: HandleView, context: Context) {
        view.vertical = vertical
        view.total = total
        view.current = fraction
        view.onChange = { fraction = min(max($0, range.lowerBound), range.upperBound) }
    }

    final class HandleView: NSView {
        var vertical = false
        var total: CGFloat = 1
        var current = 0.5
        var onChange: (Double) -> Void = { _ in }
        private var origin: Double?
        private var start: NSPoint = .zero

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                           owner: self))
        }

        override func cursorUpdate(with event: NSEvent) {
            (vertical ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).set()
        }

        override func mouseDown(with event: NSEvent) {
            // Double-click evens the panes out, as macOS split views do.
            if event.clickCount == 2 {
                onChange(0.5)
                return
            }
            origin = current
            start = event.locationInWindow
        }

        override func mouseDragged(with event: NSEvent) {
            guard let origin, total > 0 else { return }
            // Measured in the window: this view slides along with the divider.
            // Window y grows upwards, the top pane downwards.
            let moved = vertical ? start.y - event.locationInWindow.y : event.locationInWindow.x - start.x
            onChange(origin + Double(moved / total))
        }

        override func mouseUp(with event: NSEvent) {
            origin = nil
        }
    }
}

/// One pane: its tab strip over its tab in front, or a pointer to opening one.
struct PaneView: View {
    @Environment(\.theme) private var theme
    @Environment(ThemeStore.self) private var themeStore
    @Environment(ConnectionStore.self) private var connectionStore
    @Environment(AppState.self) private var appState

    var pane: Int
    var hidesTabs = false

    private var isFocused: Bool { connectionStore.focusedPane == pane }
    private var isSplit: Bool { connectionStore.layout.paneCount > 1 }
    /// Split, and typing does not reach it: drawn back, the way iTerm2 dims
    /// its inactive split panes. A quieter tab line and a hollow cursor alone
    /// did not tell the panes apart. An accent frame round the focused pane
    /// did, but glared, and its top edge was clipped by the window's.
    private var isDimmed: Bool { isSplit && !connectionStore.typingReaches(pane: pane) }

    /// How far a dimmed pane's content is pulled towards its background.
    static let dimming = 0.4
    /// The focused pane's line under its tabs: there, but quiet.
    static let focusLineOpacity = 0.6

    var body: some View {
        VStack(spacing: 0) {
            if !hidesTabs {
                TabBarView(pane: pane)
                    .frame(height: Metrics.tabBarHeight)
                    .background(theme.sidebar.color)
                    .overlay(alignment: .bottom) {
                        if connectionStore.receivesBroadcast(pane: pane) {
                            // Every pane typing will reach, focused or not: the
                            // warning colour, as this is easy to forget is on.
                            Rectangle()
                                .fill(theme.ansiYellow.color.opacity(0.85))
                                .frame(height: 2)
                        } else if isSplit && isFocused {
                            Rectangle()
                                .fill(theme.accent.color.opacity(Self.focusLineOpacity))
                                .frame(height: 2)
                        } else {
                            Divider1(theme.border)
                        }
                    }
            }
            paneContent
                .overlay {
                    if isDimmed {
                        theme.terminal.color.opacity(Self.dimming).allowsHitTesting(false)
                    }
                }
        }
    }

    @ViewBuilder
    private var paneContent: some View {

            if let connection = connectionStore.active(in: pane), let desktop = connection.desktop {
                RDPPane(connection: connection, desktop: desktop, theme: theme,
                        font: themeStore.terminalFont(size: connection.fontSize),
                        takesFocus: isFocused,
                        onFocus: { connectionStore.focus(pane: pane) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay { RDPQuestionView(desktop: desktop) }
            } else if let connection = connectionStore.active(in: pane), let desktop = connection.vnc {
                VNCPane(connection: connection, desktop: desktop, theme: theme,
                        font: themeStore.terminalFont(size: connection.fontSize), takesFocus: isFocused,
                        onFocus: { connectionStore.focus(pane: pane) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay { VNCQuestionView(desktop: desktop) }
            } else if let connection = connectionStore.active(in: pane),
                      connection.kind == .sftp, connection.isLoggedIn {
                sftpContent(connection)
            } else if let connection = connectionStore.active(in: pane) {
                TerminalPane(connection: connection, theme: theme,
                             font: themeStore.terminalFont(size: connection.fontSize),
                             copyOnSelect: themeStore.copyOnSelect,
                             cursorShape: themeStore.cursorShape,
                             cursorBlinks: themeStore.cursorBlinks,
                             rightClickPastes: themeStore.rightClickPastes,
                             scrollWithArrowKeys: themeStore.scrollWithArrowKeys,
                             confirmMultilinePaste: themeStore.confirmMultilinePaste,
                             bell: themeStore.bell,
                             optionAsMeta: themeStore.optionAsMeta,
                             highlighting: themeStore.highlighting,
                             scrollbackLines: themeStore.scrollbackLines,
                             onStopConfirmingPaste: { themeStore.confirmMultilinePaste = false },
                             takesFocus: isFocused,
                             onFocus: { connectionStore.focus(pane: pane) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .topTrailing) {
                        if appState.isFindOpen && isFocused {
                            // Clear of the scroll bar on the right.
                            FindBar(theme: theme, terminal: connection.terminalView)
                                .padding(.top, 8)
                                .padding(.trailing, 20)
                        }
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if connection.kind == .sftp {
                            sftpTransferFooter(connection.fileBrowser)
                        }
                    }
            } else {
                EmptyPaneView(pane: pane)
            }
    }

    private func sftpContent(_ connection: Connection) -> some View {
        let remote = connection.fileBrowser
        let local = appState.localFiles
        return FileBrowserView(browser: remote, title: connection.title,
                               transfer: .init(title: "Download to Local Folder", symbol: "arrow.left",
                                               available: local.path != nil) { files in
            connectionStore.focus(pane: pane)
            appState.showLocalFiles()
            remote.download(files, into: local)
        }, onFocus: { connectionStore.focus(pane: pane) }, defaultListStyle: .detailed)
            .id(connection.id)
            .padding(12)
            .background(theme.sidebar.color)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { connectionStore.focus(pane: pane) })
    }

    @ViewBuilder
    private func sftpTransferFooter(_ browser: FileBrowser) -> some View {
        if !browser.activities.isEmpty {
            VStack(spacing: 0) {
                Divider1(theme.border)
                FileActivityStrip(browser: browser, theme: theme)
                    .padding(12)
                    .background(theme.sidebar.color)
            }
        }
    }
}

/// A pane with no tabs: what to do to fill it. A click anywhere in it gives
/// it the focus, so the next session opened goes here.
struct EmptyPaneView: View {
    @Environment(\.theme) private var theme
    @Environment(ConnectionStore.self) private var connectionStore
    @Environment(AppState.self) private var appState

    var pane: Int

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(theme.textFaint.color)
            Text("Double-click a session to open it here")
                .font(SBFont.ui(12.5))
                .foregroundStyle(theme.textMuted.color)
            Button("Quick Connect…") {
                connectionStore.focus(pane: pane)
                appState.route = .quickConnect
            }
            .buttonStyle(SecondaryButtonStyle(theme: theme, height: 28, fontSize: 12.5, filled: true))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.terminal.color)
        .contentShape(Rectangle())
        .onTapGesture { connectionStore.focus(pane: pane) }
    }
}
