import AppKit
import SwiftUI
import Testing
@testable import Termstead

/// Renders the new-session form as a first launch shows it — no groups, no
/// sessions — and saves it, so its look can be checked. The path is printed.
@MainActor
struct CleanFormRenderTests {
    @Test func newSessionFormOnAnEmptyTree() throws {
        let sessions = SessionStore(tree: [], sessions: [:], selectedID: nil, pinnedIDs: [])
        let view = SessionSheet(mode: .create(parentGroupID: nil))
            .environment(sessions)
            .environment(ConnectionStore())
            .environment(\.theme, .graphite)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clean-session-form.png")
        try png.write(to: url)
        print("CLEAN_FORM_PNG \(url.path)")
    }

    /// The first session saved on an empty tree lands in a new "Sessions"
    /// group, and the next one joins it. Typed and saved through the form in
    /// this test's own window; nothing touches the real keyboard or pointer.
    @Test func theFirstSessionGoesIntoANewSessionsGroup() async throws {
        let store = SessionStore(tree: [], sessions: [:], selectedID: nil, pinnedIDs: [])
        let hosting = NSHostingView(rootView: SessionSheet(mode: .create(parentGroupID: nil))
            .environment(store)
            .environment(ConnectionStore())
            .environment(\.theme, .graphite))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 820, height: 680),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        for _ in 0..<15 { try await Task.sleep(for: .milliseconds(30)) }

        // Name and Host, each clicked into (points from the top-left; the
        // key view loop does not reach SwiftUI's fields), then Save, bottom
        // right, left of "Save & connect".
        func click(_ x: CGFloat, _ y: CGFloat) throws {
            let inView = hosting.isFlipped ? NSPoint(x: x, y: y) : NSPoint(x: x, y: hosting.bounds.height - y)
            let location = hosting.convert(inView, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(try #require(NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
            }
        }
        for (y, text) in [(CGFloat(120), "first-box"), (194, "10.0.0.9")] {
            try click(150, y)
            try await Task.sleep(for: .milliseconds(60))
            let editor = try #require(window.firstResponder as? NSTextView, "no field has the keyboard")
            editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            try await Task.sleep(for: .milliseconds(60))
        }
        try click(hosting.bounds.width - 214, hosting.bounds.height - 38)
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(30)) }

        #expect(store.tree.map(\.name) == [SessionStore.firstGroupName])
        #expect(store.tree.first?.children == [.session("first-box")])
        #expect(store.session("first-box")?.host == "10.0.0.9")

        // The next one, with no group chosen, joins it rather than making another.
        store.createSession(Session(id: "second-box", user: "u", host: "h", port: 22, icon: .server),
                            parentID: nil)
        #expect(store.tree.count == 1)
        #expect(store.tree.first?.children == [.session("first-box"), .session("second-box")])
    }
}
