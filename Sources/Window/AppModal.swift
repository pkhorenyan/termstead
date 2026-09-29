import AppKit
import SwiftUI

/// Runs a window app-modal, like `NSAlert`: until it closes, the app's other
/// windows take no clicks, no keys — and cannot be dragged either.
///
/// `runModal` alone refuses clicks elsewhere, but whether a titlebar drag on
/// another window gets through is up to AppKit and has changed between macOS
/// releases, so every other visible window is made immovable for the duration
/// and restored afterwards.
@MainActor
enum AppModal {
    private static var frozen: [NSWindow] = []

    /// Started from a run-loop block, never a dispatch block, and never inside
    /// a SwiftUI update. `runModal` is a nested run loop: begun inside a
    /// main-queue block it keeps that serial queue busy for as long as the
    /// window is up, and the terminals' output and every SwiftUI update arrive
    /// through the main queue. Only the default mode is used, so a second modal
    /// window cannot start until the first one's loop has returned.
    ///
    /// - Parameter stillWanted: checked when the block runs; the window may have
    ///   been closed or replaced in the meantime.
    static func begin(_ window: NSWindow, stillWanted: @escaping @MainActor () -> Bool = { true }) {
        RunLoop.main.perform(inModes: [.default]) { [weak window] in
            MainActor.assumeIsolated {
                guard let window, window.isVisible, NSApp.modalWindow == nil, stillWanted() else { return }
                freezeOthers(except: window)
                NSApp.runModal(for: window)
                thaw()
            }
        }
    }

    static func end(_ window: NSWindow) {
        guard NSApp.modalWindow === window else { return }
        NSApp.stopModal()
        // `stopModal` takes effect once the current event is handled. When the
        // close was not itself an event — a state change — nothing would come
        // along to end the loop, so one is posted.
        if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                         timestamp: 0, windowNumber: 0, context: nil,
                                         subtype: 0, data1: 0, data2: 0) {
            NSApp.postEvent(wake, atStart: true)
        }
    }

    private static func freezeOthers(except window: NSWindow) {
        frozen = NSApp.windows.filter { $0 !== window && $0.isVisible && $0.isMovable }
        for other in frozen { other.isMovable = false }
    }

    private static func thaw() {
        for window in frozen { window.isMovable = true }
        frozen = []
    }
}

/// Makes the window it is placed in app-modal while it is open. For windows
/// SwiftUI creates itself, such as the Appearance `Window` scene.
struct ModalWhileOpen: NSViewRepresentable {
    /// Told when the window starts and stops being modal, so menu commands
    /// that would reach past it can be switched off.
    var onChange: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> NSView {
        let view = Probe()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? Probe)?.onChange = onChange
    }

    private final class Probe: NSView {
        var onChange: (Bool) -> Void = { _ in }
        private var observer: (any NSObjectProtocol)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, observer == nil else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let window else { return }
                    AppModal.end(window)
                    self?.stopObserving()
                    self?.onChange(false)
                }
            }
            onChange(true)
            AppModal.begin(window) { [weak window] in window?.isVisible == true }
        }

        private func stopObserving() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
    }
}
