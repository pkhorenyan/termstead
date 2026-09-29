import SwiftUI

@main
struct TermsteadApp: App {
    @State private var themeStore = ThemeStore()
    @State private var storage: SessionStorage
    @State private var sessionStore: SessionStore
    @State private var appState = AppState()
    @State private var connectionStore = ConnectionStore()
    @State private var updater = AppUpdater()
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    static let appearanceWindowID = "appearance"

    init() {
        // No AppKit window restoration. Window frames are kept by `FrameKeeper`,
        // and restored state did harm: a saved state with no windows in it
        // brought the app up with no window at all, and a restored Settings
        // window came back modal before anything else could be used.
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
        SBFont.verifyBundledFonts()
        let storage = SessionStorage.forThisLaunch()
        _storage = State(initialValue: storage)
        _sessionStore = State(initialValue: storage.makeStore())
    }

    var body: some Scene {
        WindowGroup("Termstead") {
            MainView()
                .background(SessionAutosave(storage: storage))
                .onAppear {
                    appDelegate.connectionStore = connectionStore
                    appDelegate.themeStore = themeStore
                }
                .environment(themeStore)
                .environment(sessionStore)
                .environment(storage)
                .environment(connectionStore)
                .environment(appState)
                .environment(\.theme, themeStore.current)
                .frame(minWidth: Metrics.minWindowSize.width,
                       minHeight: Metrics.minWindowSize.height)
        }
        .defaultSize(width: Metrics.defaultWindowSize.width,
                     height: Metrics.defaultWindowSize.height)
        .windowStyle(.hiddenTitleBar)
        .commands { commands }

        // A plain Window rather than a Settings scene: the Settings window
        // keeps its own opaque titlebar, and this screen draws its own chrome.
        // Titled Settings: it holds the terminal's behaviour as well as the
        // look. The id keeps its old name so saved frames still apply.
        Window("Settings", id: Self.appearanceWindowID) {
            AppearanceView()
                .environment(themeStore)
                .environment(appState)
                .environment(\.theme, themeStore.current)
        }
        .windowStyle(.hiddenTitleBar)
        // Sized by its content (which scrolls), so it cannot be dragged taller
        // than the settings need or shorter than the footer.
        .windowResizability(.contentSize)
    }

    /// A form or Appearance is app-modal, but whether a SwiftUI menu command honours that is
    /// not documented, so everything that would reach past the form is
    /// switched off while one is up.
    private var formIsOpen: Bool { appState.isModalOpen }

    @CommandsBuilder
    private var commands: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.isActive || formIsOpen)
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { openWindow(id: Self.appearanceWindowID) }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(formIsOpen)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Session…") { appState.route = .newSession(parentGroupID: nil) }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(formIsOpen)
            Button("New Group…") { appState.route = .newGroup(parentGroupID: nil) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(formIsOpen)
            Divider()
            Button("Import from ~/.ssh/config") {
                Task { await appState.importSSHConfig(into: sessionStore) }
            }
            .disabled(formIsOpen || appState.isImporting)
        }
        // Replaces the stock Find submenu, which would drive SwiftTerm's own,
        // unthemed find bar. Next goes up, into older output, as in iTerm2.
        CommandGroup(replacing: .textEditing) {
            Button("Find…") { appState.openFind() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(connectionStore.active == nil || formIsOpen)
            Button("Find Next") { appState.find(in: connectionStore.active?.terminalView, upward: true) }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(connectionStore.active == nil || appState.findQuery.isEmpty || formIsOpen)
            Button("Find Previous") { appState.find(in: connectionStore.active?.terminalView, upward: false) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(connectionStore.active == nil || appState.findQuery.isEmpty || formIsOpen)
        }
        // The active tab only, as in Terminal and iTerm2; the size every tab
        // starts at is in Settings. ⌘= reaches "Bigger" through
        // `AppDelegate.plusForEquals`.
        CommandGroup(after: .toolbar) {
            Button("Bigger") { zoom(by: 1) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!canZoom(by: 1))
            Button("Smaller") { zoom(by: -1) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!canZoom(by: -1))
            Button("Default Font Size") { connectionStore.active?.fontSize = nil }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(connectionStore.active?.fontSize == nil || formIsOpen)
            Divider()
        }
        // No help book, so no "Termstead Help": the stock item only says help
        // isn't available. The Help menu keeps macOS's own menu search.
        CommandGroup(replacing: .help) {}
        CommandMenu("Session") {
            // No bare Return shortcut: the terminal needs that key.
            Button("Connect") { connectSelected() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(sessionStore.selectedID == nil || formIsOpen)
            Button("Session Settings…") {
                if let id = sessionStore.selectedID { appState.route = .sessionSettings(id: id) }
            }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(sessionStore.selectedID == nil || formIsOpen)
            Divider()
            Button("Quick Connect…") {
                // The first-launch screen has the field inline; otherwise the form.
                if connectionStore.connections.isEmpty {
                    appState.focusQuickConnect()
                } else {
                    appState.route = .quickConnect
                }
            }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(formIsOpen)
            Button("New Tab…") { appState.route = .quickConnect }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(formIsOpen)
            Button("Close Tab") {
                if let id = connectionStore.active?.id {
                    appState.requestClose(id, in: connectionStore,
                                          confirm: themeStore.confirmClosingConnection)
                }
            }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(connectionStore.active == nil || formIsOpen)
        }
        if DevelopmentLaunch.isActive {
            CommandMenu("Debug") {
                Button("Load Sample Data") { sessionStore.loadSample() }
                    .disabled(formIsOpen)
                // The Docker lab in TestLab/: real servers to connect to.
                Button("Add Test Lab Sessions") { sessionStore.addTestLab() }
                    .disabled(formIsOpen)
                Button("Clear All Sessions") { sessionStore.clearAll() }
                    .disabled(formIsOpen)
            }
        }
    }

    private func connectSelected() {
        guard let id = sessionStore.selectedID else { return }
        connectionStore.connect(sessionID: id, in: sessionStore)
    }

    private func zoom(by delta: Int) {
        guard let connection = connectionStore.active else { return }
        connection.fontSize = themeStore.zoomedSize(from: connection.fontSize, by: delta)
    }

    /// False at either end of the range, so the menu shows there is no further to go.
    private func canZoom(by delta: Int) -> Bool {
        guard let connection = connectionStore.active, !formIsOpen else { return false }
        let size = connection.fontSize ?? themeStore.terminalFontSize
        return (themeStore.zoomedSize(from: connection.fontSize, by: delta) ?? themeStore.terminalFontSize) != size
    }
}

/// Fixed geometry lifted from the mockup.
enum Metrics {
    /// The standard macOS titlebar. The mockup drew a 50pt bar carrying the
    /// quick-connect field and two buttons; the field is gone, the gear is a
    /// titlebar accessory, and what is left belongs in a titlebar of the usual
    /// height. `TrafficLightCentering` stops nudging the window buttons here.
    static let toolbarHeight: CGFloat = 28
    /// Including the 34pt tab rail on its left edge (`SidebarTabRail`).
    static let sidebarWidth: CGFloat = 282
    /// The narrowest still fits the SFTP toolbar's seven buttons.
    static let sidebarWidthRange: ClosedRange<Double> = 230...434
    static let tabBarHeight: CGFloat = 38
    static let statusBarHeight: CGFloat = 26
    static let defaultWindowSize = CGSize(width: 1280, height: 800)
    // Wide enough that the toolbar still fits with the sidebar dragged out to
    // its maximum: gutter + quick connect at its narrowest + every button.
    static let minWindowSize = CGSize(width: 960, height: 560)
}

/// Asks before quitting ends live ssh sessions. AppKit's quit path, since
/// SwiftUI has no hook of its own that can cancel termination.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var connectionStore: ConnectionStore?
    weak var themeStore: ThemeStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            Self.plusForEquals(event) ?? event
        }
    }

    /// ⌘= as ⌘+. "Bigger" is ⌘+, which takes Shift on most layouts, and AppKit
    /// matches a menu's key equivalent by character, so ⌘= alone — the key
    /// people press to zoom — matched nothing. Rewritten, it reaches the menu
    /// item, which still decides whether it is enabled.
    nonisolated static func plusForEquals(_ event: NSEvent) -> NSEvent? {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
              event.charactersIgnoringModifiers == "=" else { return nil }
        return NSEvent.keyEvent(with: .keyDown, location: event.locationInWindow,
                                modifierFlags: event.modifierFlags.union(.shift),
                                timestamp: event.timestamp, windowNumber: event.windowNumber,
                                context: nil, characters: "+", charactersIgnoringModifiers: "+",
                                isARepeat: event.isARepeat, keyCode: event.keyCode)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let connectionStore, let themeStore, themeStore.confirmClosingConnection else {
            return .terminateNow
        }
        let live = connectionStore.liveCount
        guard live > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit Termstead?"
        alert.informativeText = live == 1
            ? "A connection is still open. Quitting ends its ssh session."
            : "\(live) connections are still open. Quitting ends their ssh sessions."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}
