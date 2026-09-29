import SwiftUI

struct MainView: View {
    @Environment(\.theme) private var theme
    @Environment(\.openWindow) private var openWindow
    @Environment(ThemeStore.self) private var themeStore
    @Environment(SessionStore.self) private var sessionStore
    @Environment(AppState.self) private var appState
    @Environment(SessionStorage.self) private var storage
    @Environment(ConnectionStore.self) private var connectionStore

    /// Sidebar width is user-set and remembered between launches.
    @AppStorage("sidebar.width") private var sidebarWidth: Double = Double(Metrics.sidebarWidth)

    /// The sidebar, on whichever side Settings puts it. Its divider and the
    /// grab strip that resizes it sit on the edge facing the terminal.
    private var sidebar: some View {
        let side = themeStore.sidebarSide
        let inner: Alignment = side == .left ? .trailing : .leading
        return SidebarView(side: side)
            .frame(width: CGFloat(sidebarWidth))
            .background(theme.sidebar.color)
            .overlay(alignment: inner) { Divider1(theme.border, vertical: true) }
            .overlay(alignment: inner) {
                SidebarResizeHandle(width: $sidebarWidth,
                                    range: Metrics.sidebarWidthRange,
                                    defaultWidth: Double(Metrics.sidebarWidth),
                                    growsLeftward: side == .right)
                    .frame(width: SidebarResizeHandle.grabWidth)
                    .resizeCursor()
            }
    }

    /// The welcome screen whenever no tab is open — saved hosts or not. Its
    /// quick-connect field is useful either way, and an empty tab strip over a
    /// blank terminal said nothing.
    @ViewBuilder
    private var mainColumn: some View {
        if connectionStore.connections.isEmpty {
            EmptyStateView()
        } else {
            terminalColumn
        }
    }

    var body: some View {
        @Bindable var appState = appState

        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if themeStore.sidebarSide == .left {
                    sidebar
                    mainColumn
                } else {
                    mainColumn
                    sidebar
                }
            }
            .frame(maxHeight: .infinity)
            // Keeps every background in this row out of the titlebar. SwiftUI
            // backgrounds bleed up into the safe area, so the strip used to be
            // painted by whatever happened to be at the top of each column:
            // the sidebar's tone on the left, and on the right the tab bar's —
            // or, with no tabs, the terminal's near-black from the first-launch
            // screen, which split the titlebar in two. Clipped, the strip is
            // painted by the root background alone, one tone in every state.
            .clipped()
            // Closes off the titlebar. An overlay rather than a row in the
            // `VStack`: overlays are not offered the safe area, so this lands
            // exactly on the titlebar's lower edge.
            .overlay(alignment: .top) { Divider1(theme.border) }

            StatusBarView()
                .frame(height: Metrics.statusBarHeight)
                .background(theme.chrome.color)
                .overlay(alignment: .top) { Divider1(theme.border) }
        }
        // The safe-area inset is kept: the titlebar is a real one, and the
        // content belongs below it. This is the only background that reaches
        // the titlebar strip (see `.clipped()` above), so it sets the strip's
        // tone — the sidebar's, which the strip has always shown beside it.
        .background(theme.sidebar.color)
        .background(
            WindowConfigurator(theme: theme,
                               toolbarHeight: Metrics.toolbarHeight,
                               minSize: Metrics.minWindowSize,
                               titlebarTitle: "Termstead",
                               frameAutosaveName: "MainWindow",
                               onOpenAppearance: {
                                   openWindow(id: TermsteadApp.appearanceWindowID)
                               })
        )
        .alert(appState.importReport?.title ?? "",
               isPresented: Binding(get: { appState.importReport != nil },
                                    set: { if !$0 { appState.importReport = nil } })) {
            Button("OK", role: .cancel) { appState.importReport = nil }
        } message: {
            Text(appState.importReport?.detail ?? "")
        }
        .alert(closeTitle,
               isPresented: Binding(get: { appState.pendingClose != nil },
                                    set: { if !$0 { appState.pendingClose = nil } })) {
            Button("Close", role: .destructive) {
                if let id = appState.pendingClose { connectionStore.close(id) }
                appState.pendingClose = nil
            }
            Button("Cancel", role: .cancel) { appState.pendingClose = nil }
        } message: {
            Text("Its ssh session ends, and anything running in it that is not under tmux or nohup stops.")
        }
        .alert("Saved sessions could not be read",
               isPresented: Binding(get: { storage.loadProblem != nil },
                                    set: { if !$0 { storage.loadProblem = nil } })) {
            Button("OK") {}
        } message: {
            Text(storage.loadProblem ?? "")
        }
        .onAppear {
            connectionStore.onLogin = { [appState, themeStore, connectionStore] connection in
                guard themeStore.showFilesAfterLogin else { return }
                Task { await appState.showFiles(afterLoginOf: connection, in: connectionStore) }
            }
            if appState.applyLaunchRoute() == "appearance" {
                openWindow(id: TermsteadApp.appearanceWindowID)
            }
            // Development hooks, like `-sb-route`: `-sb-connect a,b,c` opens
            // those sessions' tabs in order, the first one in front, and
            // `-sb-sidebar files` shows the Files tab, so both can be looked
            // at without clicking.
            let defaults = UserDefaults.standard
            if let names = defaults.string(forKey: "sb-connect") {
                let ids = names.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                for id in ids { connectionStore.connect(sessionID: id, in: sessionStore) }
                if let first = ids.first,
                   let tab = connectionStore.connections.first(where: { $0.sessionID == first }) {
                    connectionStore.activeID = tab.id
                }
            }
            if defaults.string(forKey: "sb-sidebar") == "files" { appState.sidebarTab = .files }
            // `-sb-color-picker YES` opens the custom color dialog over the window.
            if defaults.bool(forKey: "sb-color-picker") {
                DispatchQueue.main.async {
                    ColorPickerWindow.present(start: RGB(0xE07BD8), over: NSApp.windows.first { $0.isVisible },
                                              theme: theme) { _ in }
                }
            }
        }
        // Not `.sheet`: a sheet is pinned to the parent window and cannot be
        // moved. The forms are windows of their own — see `FormWindowPresenter`.
        .background(
            FormWindowPresenter(route: $appState.route,
                                theme: theme,
                                themeStore: themeStore,
                                sessionStore: sessionStore,
                                connectionStore: connectionStore)
        )
    }

    private var closeTitle: String {
        let title = connectionStore.connections.first { $0.id == appState.pendingClose }?.title
        return title.map { "Close the connection to \($0)?" } ?? "Close the connection?"
    }

    private var terminalColumn: some View {
        VStack(spacing: 0) {
            TabBarView()
                .frame(height: Metrics.tabBarHeight)
                .background(theme.sidebar.color)
                .overlay(alignment: .bottom) { Divider1(theme.border) }

            if let connection = connectionStore.active {
                TerminalPane(connection: connection, theme: theme,
                             font: themeStore.terminalFont(size: connection.fontSize),
                             copyOnSelect: themeStore.copyOnSelect,
                             cursorShape: themeStore.cursorShape,
                             cursorBlinks: themeStore.cursorBlinks,
                             rightClickPastes: themeStore.rightClickPastes,
                             confirmMultilinePaste: themeStore.confirmMultilinePaste,
                             bell: themeStore.bell,
                             optionAsMeta: themeStore.optionAsMeta,
                             highlighting: themeStore.highlighting,
                             scrollbackLines: themeStore.scrollbackLines,
                             onStopConfirmingPaste: { themeStore.confirmMultilinePaste = false })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .topTrailing) {
                        if appState.isFindOpen {
                            // Clear of the scroll bar on the right.
                            FindBar(theme: theme, terminal: connection.terminalView)
                                .padding(.top, 8)
                                .padding(.trailing, 20)
                        }
                    }
                    .onChange(of: connection.id) { appState.activeTerminalChanged() }
            }
        }
    }
}

/// A one-pixel separator that stays one pixel on Retina.
struct Divider1: View {
    private let color: RGB
    private let vertical: Bool

    init(_ color: RGB, vertical: Bool = false) {
        self.color = color
        self.vertical = vertical
    }

    var body: some View {
        Rectangle()
            .fill(color.color)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}
