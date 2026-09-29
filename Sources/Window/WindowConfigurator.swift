import AppKit
import SwiftUI

/// Reaches the hosting `NSWindow` and dresses it to match the mockup: no system
/// title, content running under the titlebar, and the theme's own background.
///
/// The appearance is set explicitly because the traffic lights take their look
/// from `effectiveAppearance`; without it they would stay dark on the light
/// themes. It is set on `NSApp` as well as on the window — see `apply(to:)`.
struct WindowConfigurator: NSViewRepresentable {
    var theme: Theme
    var toolbarHeight: CGFloat
    var minSize: CGSize
    /// Drawn in the titlebar beside the window buttons. Every window in the app
    /// names itself this way rather than drawing a bar of its own.
    var titlebarTitle: String?
    /// Remembers where the window was and how big, across launches.
    var frameAutosaveName: String?
    /// Set by the main window: adds the gear at the trailing end.
    var onOpenAppearance: (() -> Void)?

    func makeNSView(context: Context) -> NSView {
        let view = ProbeView()
        view.onAttach = { window in
            attach(context.coordinator, to: window)
            apply(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        attach(context.coordinator, to: window)
        apply(to: window)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        let trafficLights = TrafficLightCentering()
        let frame = FrameKeeper()
    }

    private func attach(_ coordinator: Coordinator, to window: NSWindow) {
        coordinator.trafficLights.attach(to: window, toolbarHeight: toolbarHeight)
        if let frameAutosaveName { coordinator.frame.attach(to: window, name: frameAutosaveName) }
    }

    private func apply(to window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Only the titlebar moves the window. Dragging the background moved it
        // too, so a drag that started on a quiet part of the sidebar or the
        // status bar carried the whole window away.
        window.isMovableByWindowBackground = false
        window.appearance = theme.appearance
        if let titlebarTitle { installTitle(on: window, text: titlebarTitle) }
        if let onOpenAppearance { installActions(on: window, action: onOpenAppearance) }

        // Sheets, popovers and the Appearance window are each their own
        // `NSWindow` and do not inherit this one's appearance: they fall back to
        // whatever macOS is set to. Anything AppKit draws inside them — a field
        // editor's text and insertion point, selection highlights, placeholder
        // text — then comes out of the *system* palette, which is how a dark
        // theme on a light Mac ended up with black text on a dark field.
        if NSApp.appearance?.name != theme.appearance?.name {
            NSApp.appearance = theme.appearance
        }
        // Barely visible in practice: the content runs under the transparent
        // titlebar from y = 0, so this shows only during a live resize.
        window.backgroundColor = theme.window.nsColor
        window.minSize = minSize
    }

    /// Puts the window's name into the real titlebar, next to the window buttons.
    /// Re-running this only re-themes the view already installed.
    private func installTitle(on window: NSWindow, text: String) {
        let identifier = NSUserInterfaceItemIdentifier("sb.titlebar.name")
        let content = TitlebarName(theme: theme, title: text)

        if let existing = window.titlebarAccessoryViewControllers
            .first(where: { $0.identifier == identifier }) {
            (existing.view as? NSHostingView<TitlebarName>)?.rootView = content
            return
        }

        let controller = NSTitlebarAccessoryViewController()
        controller.identifier = identifier
        controller.layoutAttribute = .leading
        let host = TitlebarDragHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 110, height: toolbarHeight)
        controller.view = host
        window.addTitlebarAccessoryViewController(controller)
    }

    /// The gear at the trailing end of the titlebar. Same shape as
    /// `installAppName`: re-running it only re-themes what is already there.
    private func installActions(on window: NSWindow, action: @escaping () -> Void) {
        let identifier = NSUserInterfaceItemIdentifier("sb.titlebar.actions")
        let content = TitlebarActions(theme: theme, onOpenAppearance: action)

        if let existing = window.titlebarAccessoryViewControllers
            .first(where: { $0.identifier == identifier }) {
            (existing.view as? NSHostingView<TitlebarActions>)?.rootView = content
            return
        }

        let controller = NSTitlebarAccessoryViewController()
        controller.identifier = identifier
        controller.layoutAttribute = .trailing
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 38, height: toolbarHeight)
        controller.view = host
        window.addTitlebarAccessoryViewController(controller)
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

/// Keeps the window buttons vertically centred in the app's own toolbar.
///
/// The buttons live in a 28pt titlebar, but the design centres them in a 50pt
/// bar. AppKit re-lays them out on essentially every titlebar change, so the
/// offset is re-applied from `NSWindow.didUpdateNotification` rather than set
/// once. Each pass is three frame reads and, once settled, no writes.
@MainActor
final class TrafficLightCentering: NSObject {
    private weak var window: NSWindow?
    private var toolbarHeight: CGFloat = 0
    private var observer: (any NSObjectProtocol)?

    /// Standard titlebar height; the buttons sit centred inside it.
    private static let systemTitlebarHeight: CGFloat = 28

    func attach(to window: NSWindow, toolbarHeight: CGFloat) {
        guard self.window !== window || self.toolbarHeight != toolbarHeight else {
            reposition()
            return
        }
        self.window = window
        self.toolbarHeight = toolbarHeight

        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
        reposition()
    }

    private func reposition() {
        guard let window,
              !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton),
              let titlebar = close.superview
        else { return }

        // In a flipped titlebar view the origin is measured from the top, so the
        // buttons move down; otherwise they move down by decreasing y.
        let drop = (toolbarHeight - Self.systemTitlebarHeight) / 2
        guard drop > 0.5 else { return }

        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind) else { continue }
            let centered = (Self.systemTitlebarHeight - button.frame.height) / 2
            let target = titlebar.isFlipped ? centered + drop : centered - drop
            guard abs(button.frame.origin.y - target) > 0.5 else { continue }
            button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: target))
        }
    }

    // No deinit teardown: the observation is registered against this window
    // and torn down with it, and `NotificationCenter` holds the token, not us.
}

/// The window's name sits in the titlebar, and the titlebar is where the window
/// is dragged from. A hosting view does not let a drag through on its own, so
/// grabbing the window by its name would do nothing.
final class TitlebarDragHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
}

/// Brings a window back where it was, at the size it had, across launches.
///
/// SwiftUI only does that through system state restoration, which is off
/// whenever "Close windows when quitting an application" is on — the macOS
/// default. AppKit's `frameAutosaveName` is no help either: SwiftUI names the
/// windows of its own scenes and puts its name back, so a check for "already
/// set up" never held, the saved frame was re-applied on every update, and the
/// Appearance window jumped back each time a theme was picked. So the frame is
/// applied exactly once per window, and saved here on every move and resize.
@MainActor
final class FrameKeeper {
    private weak var window: NSWindow?
    private var observers: [any NSObjectProtocol] = []

    static func key(_ name: String) -> String { "window.frame.\(name)" }

    func attach(to window: NSWindow, name: String) {
        guard self.window !== window else { return }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        self.window = window

        let key = Self.key(name)
        // The previous build saved through AppKit's autosave, under its key.
        let saved = UserDefaults.standard.string(forKey: key)
            ?? UserDefaults.standard.string(forKey: "NSWindow Frame \(name)")
        if let saved {
            Self.restore(saved, to: window)
            // Once more after the first layout: the hosting view sizes the
            // window to its content when it first lays out, which kept the
            // restored position but threw away the restored size.
            RunLoop.main.perform { [weak window] in
                MainActor.assumeIsolated { if let window { Self.restore(saved, to: window) } }
            }
        }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak window] _ in
                MainActor.assumeIsolated {
                    guard let window else { return }
                    UserDefaults.standard.set(window.frameDescriptor, forKey: key)
                }
            })
        }
    }

    /// A window the user can resize gets its size back; one sized by its
    /// content keeps its content's size and only moves back to where it was —
    /// a size saved from an earlier layout would stretch it around content
    /// that no longer fills it.
    static func restore(_ saved: String, to window: NSWindow) {
        guard !window.styleMask.contains(.resizable) else {
            window.setFrame(from: saved)
            return
        }
        let current = window.frame
        window.setFrame(from: saved)
        let top = window.frame.maxY
        window.setFrame(NSRect(x: window.frame.minX, y: top - current.height,
                               width: current.width, height: current.height), display: false)
    }

    // No deinit teardown: once the window is gone the observers hold it only
    // weakly and do nothing.
}
