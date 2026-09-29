import AppKit
import SwiftUI
import Testing
@testable import Termstead

/// Uses a frame key of its own and removes it afterwards; the app's real
/// window frames live in the same defaults domain.
@MainActor
struct WindowFrameTests {
    private let name = "Test-\(UUID().uuidString)"

    private func makeWindow(theme: Theme) -> (NSWindow, NSHostingView<AnyView>) {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 640, height: 420),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        let host = NSHostingView(rootView: configured(theme))
        window.contentView = host
        window.orderFront(nil)
        return (window, host)
    }

    private func configured(_ theme: Theme) -> AnyView {
        AnyView(Color.clear.background(
            WindowConfigurator(theme: theme, toolbarHeight: 28, minSize: .zero, frameAutosaveName: name)))
    }

    private func settle() async throws {
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func aMovedWindowStaysPutWhenTheViewUpdates() async throws {
        defer { UserDefaults.standard.removeObject(forKey: FrameKeeper.key(name)) }
        let (window, host) = makeWindow(theme: .graphite)
        defer { window.close() }
        try await settle()

        let moved = NSRect(x: 420, y: 260, width: 700, height: 460)
        window.setFrame(moved, display: false)
        try await settle()

        // What picking a theme does: the view is updated with a new theme.
        host.rootView = configured(Theme.all.first { $0.id != Theme.graphite.id }!)
        host.layoutSubtreeIfNeeded()
        try await settle()

        #expect(window.frame == moved)
        #expect(UserDefaults.standard.string(forKey: FrameKeeper.key(name)) == window.frameDescriptor)
    }

    @Test func aSavedFrameIsAppliedWhenTheWindowOpens() async throws {
        defer { UserDefaults.standard.removeObject(forKey: FrameKeeper.key(name)) }
        let (first, _) = makeWindow(theme: .graphite)
        try await settle()
        let saved = NSRect(x: 333, y: 222, width: 720, height: 480)
        first.setFrame(saved, display: false)
        try await settle()
        first.close()

        let (second, _) = makeWindow(theme: .graphite)
        defer { second.close() }
        try await settle()
        #expect(second.frame == saved)
    }
}
