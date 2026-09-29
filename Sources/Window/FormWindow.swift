import AppKit
import SwiftUI

/// Presents the session and group forms, each in a window of its own.
///
/// They used to be `.sheet`s, and **a sheet cannot be moved**: AppKit pins it to
/// the parent's top edge for as long as it is up. These are ordinary titled
/// windows instead, added as *child* windows of the main one so they stay above
/// it and follow it around the screen — and run **app-modal**, as a sheet was:
/// while a form is up the window underneath takes no clicks or keys and cannot
/// be dragged, and the form itself can still be moved anywhere.
struct FormWindowPresenter: NSViewRepresentable {
    @Binding var route: AppState.Route?
    var theme: Theme
    var themeStore: ThemeStore
    var sessionStore: SessionStore
    var connectionStore: ConnectionStore

    func makeNSView(context: Context) -> NSView {
        let view = ProbeView()
        // The window can arrive after the first update. Without this a form
        // opened straight from a launch route would come up parentless: placed
        // by default and never adopted as a child window.
        view.onAttach = { [host = context.coordinator] window in
            host.parent = window
            host.resync?()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window { context.coordinator.parent = window }
        sync(context.coordinator)
    }

    func makeCoordinator() -> FormWindowHost { FormWindowHost() }

    private func sync(_ host: FormWindowHost) {
        host.resync = { sync(host) }
        // Closing is routed through the state, never done behind its back: the
        // footer buttons, the close button and Escape all just clear the route,
        // and the next update tears the window down.
        host.onClose = { route = nil }
        guard let route else {
            host.dismiss()
            return
        }
        host.present(route: route, theme: theme, themeStore: themeStore,
                     sessionStore: sessionStore, connectionStore: connectionStore)
    }

    private final class ProbeView: NSView {
        var onAttach: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            onAttach?(window)
        }
    }
}

/// Owns the form window: one at a time.
@MainActor
final class FormWindowHost: NSObject, NSWindowDelegate {
    weak var parent: NSWindow?
    var onClose: (() -> Void)?
    /// Set by every update, so what it runs is never a stale view's copy.
    var resync: (() -> Void)?

    private var window: FormWindow?
    private var shownRoute: String?
    /// Where a form was standing when it gave way to another one, so swapping
    /// forms does not throw the window back into the middle of the screen.
    private var inheritedCorner: NSPoint?

    /// How far below the parent's top edge a form lands, roughly where a sheet
    /// used to sit.
    private static let dropFromTop: CGFloat = 56

    func present(route: AppState.Route, theme: Theme, themeStore: ThemeStore,
                 sessionStore: SessionStore, connectionStore: ConnectionStore) {
        if shownRoute != route.id {
            // A fresh window rather than new content in the old one: swapping the
            // hosted view leaves the window with no first responder, and
            // everything typed into the new form is dropped until a field is
            // clicked. A window opened with the form already in it takes care of
            // that itself.
            open(route: route, themeStore: themeStore,
                 sessionStore: sessionStore, connectionStore: connectionStore)
        }

        guard let window else { return }
        // The titlebar is transparent, so this paints the strip above the form's
        // own header as well as the window behind it.
        window.appearance = theme.appearance
        window.backgroundColor = theme.chrome.nsColor
    }

    func dismiss() {
        inheritedCorner = nil
        close()
    }

    func windowWillClose(_ notification: Notification) {
        if let window { endModal(for: window) }
        window = nil
        shownRoute = nil
        inheritedCorner = nil
        onClose?()
    }

    /// Cancel, Save, Escape. The window is closed here and now rather than when
    /// SwiftUI next applies the cleared route: while the form is modal, the
    /// modal loop has to be stopped from inside it, and the route change alone
    /// would leave the app blocked until something else woke it.
    private func requestClose() {
        inheritedCorner = nil
        close()
        onClose?()
    }

    private func open(route: AppState.Route, themeStore: ThemeStore,
                      sessionStore: SessionStore, connectionStore: ConnectionStore) {
        inheritedCorner = window.map { NSPoint(x: $0.frame.minX, y: $0.frame.maxY) }
        close()

        let content = AnyView(
            FormRoot(route: route, close: { [weak self] in self?.requestClose() })
                .environment(themeStore)
                .environment(sessionStore)
                .environment(connectionStore)
        )
        let controller = NSHostingController(rootView: content)
        let window = FormWindow(contentViewController: controller)
        // The content runs up under the transparent titlebar, so the form's own
        // header starts just below the close button instead of below an empty
        // titlebar strip plus the header's padding — the two had stacked into
        // some 55pt of blank space above the title.
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.title = route.formTitle
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // The form is full of text fields; dragging inside one selects text and
        // must not walk the window across the screen.
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.delegate = self
        window.onCancel = { [weak self] in self?.requestClose() }
        window.setContentSize(controller.view.fittingSize)

        self.window = window
        shownRoute = route.id

        place(window)
        // A child window rather than a free-floating one: it cannot end up lost
        // behind the main window, and it travels with it.
        parent?.addChildWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
        beginModal(for: window)
    }

    /// App-modal like a sheet was; see `AppModal`.
    private func beginModal(for window: FormWindow) {
        AppModal.begin(window) { [weak self, weak window] in
            window != nil && self?.window === window
        }
    }

    private func endModal(for window: NSWindow) {
        AppModal.end(window)
    }

    /// Closes without reporting it: the route is already where it should be.
    private func close() {
        guard let window else { return }
        endModal(for: window)
        window.delegate = nil
        self.window = nil
        shownRoute = nil
        window.close()
    }

    private func place(_ window: NSWindow) {
        guard let parent else { return }
        let host = parent.frame
        var corner = inheritedCorner ?? NSPoint(x: host.midX - window.frame.width / 2,
                                                y: host.maxY - Self.dropFromTop)

        if let visible = (parent.screen ?? NSScreen.main)?.visibleFrame {
            let margin: CGFloat = 12
            corner.x = min(max(corner.x, visible.minX + margin),
                           max(visible.maxX - window.frame.width - margin, visible.minX + margin))
            corner.y = max(min(corner.y, visible.maxY - margin),
                           min(visible.minY + window.frame.height + margin, visible.maxY - margin))
        }
        window.setFrameTopLeftPoint(corner)
    }
}

/// Escape closes the form, as it did while these were sheets. A plain window is
/// only sent `cancelOperation` when a text view is the first responder, so the
/// key is caught here as well.
final class FormWindow: NSWindow {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 53 else {
            super.keyDown(with: event)
            return
        }
        onCancel?()
    }
}

/// The form itself, plus the environment it needs. The theme is read from the
/// store here rather than passed in, so a theme change while a form is open
/// repaints it without the hosted view being rebuilt.
private struct FormRoot: View {
    var route: AppState.Route
    var close: () -> Void

    @Environment(ThemeStore.self) private var themeStore

    var body: some View {
        form
            .environment(\.theme, themeStore.current)
            .environment(\.closeForm, close)
    }

    @ViewBuilder
    private var form: some View {
        switch route {
        case .newSession(let parent):
            SessionSheet(mode: .create(parentGroupID: parent))
        case .sessionSettings(let id):
            SessionSheet(mode: .edit(sessionID: id))
        case .newGroup(let parent):
            GroupSheet(mode: .create(parentGroupID: parent))
        case .groupSettings(let id):
            GroupSheet(mode: .edit(groupID: id))
        case .quickConnect:
            QuickConnectSheet()
        }
    }
}

extension AppState.Route {
    /// Names the window in the Window menu. The form repeats it in its own header,
    /// which is why the titlebar keeps the title hidden.
    var formTitle: String {
        switch self {
        case .newSession: "New session"
        case .sessionSettings: "Session settings"
        case .newGroup: "New group"
        case .groupSettings: "Group settings"
        case .quickConnect: "Quick connect"
        }
    }
}

private struct CloseFormKey: EnvironmentKey {
    static var defaultValue: () -> Void { {} }
}

extension EnvironmentValues {
    /// Closes the window a form is presented in. SwiftUI's `dismiss` is no use
    /// here: hosted in a window of its own there is no presentation for it to
    /// end, so it silently does nothing.
    var closeForm: () -> Void {
        get { self[CloseFormKey.self] }
        set { self[CloseFormKey.self] = newValue }
    }
}
