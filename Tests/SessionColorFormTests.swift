import AppKit
import SwiftUI
import Testing
@testable import Termstead

/// The session form's Color row as a user meets it. Clicks are events sent to
/// this test's own window — nothing touches the real pointer — at the swatch
/// found by color in the window's own rendering.
@MainActor
struct SessionColorFormTests {
    private func snapshot(_ view: NSView) -> NSBitmapImageRep {
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private func click(at point: NSPoint, in view: NSView) {
        guard let window = view.window else { return }
        // `point` is measured from the top; the window's base is at the bottom.
        let inView = view.isFlipped ? point : NSPoint(x: point.x, y: view.bounds.height - point.y)
        let location = view.convert(inView, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil,
                                              eventNumber: 0, clickCount: 1, pressure: 1) {
                window.sendEvent(event)
            }
        }
    }

    /// Colors come back shifted by the snapshot's color space, so a swatch is
    /// found as the bluest spot in a region, not by its exact value.
    private func bluest(in view: NSView, minY: CGFloat, maxY: CGFloat, maxX: CGFloat) -> (NSPoint, Double) {
        let rep = snapshot(view)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        var best = (NSPoint.zero, -1.0)
        for py in stride(from: Int(minY * scale), to: Int(maxY * scale), by: 2) {
            for px in stride(from: 0, to: Int(maxX * scale), by: 2) {
                guard let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { continue }
                let score = Double(c.blueComponent - c.redComponent)
                if score > best.1 { best = (NSPoint(x: CGFloat(px) / scale, y: CGFloat(py) / scale), score) }
            }
        }
        return best
    }

    /// The form for session "box" in a Web group of the given color.
    private func openForm(groupColor: String?, sessionColor: String? = nil)
        async throws -> (SessionStore, NSHostingView<some View>, NSWindow) {
        let session = Session(id: "box", user: "u", host: "h", port: 22, icon: .server, colorID: sessionColor)
        let web = SessionGroup(id: "web", name: "Web", colorID: groupColor, children: [.session("box")])
        let top = SessionGroup(id: "prod", name: "Production", colorID: nil, children: [.group(web)])
        let store = SessionStore(tree: [top], sessions: ["box": session], selectedID: nil, pinnedIDs: [])

        let form = SessionSheet(mode: .edit(sessionID: "box"))
            .environment(store)
            .environment(ConnectionStore())
            .environment(\.theme, .graphite)
        let hosting = NSHostingView(rootView: form)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 820, height: 680),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<15 { try await Task.sleep(for: .milliseconds(30)) }
        return (store, hosting, window)
    }

    private func save(_ hosting: NSView) async throws {
        // Save, bottom right, left of "Save & reconnect".
        click(at: NSPoint(x: hosting.bounds.width - 214, y: hosting.bounds.height - 38), in: hosting)
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(30)) }
    }

    /// Outside colored groups a session picks its own color.
    @Test func aSessionOutsideColoredGroupsTakesItsOwnColor() async throws {
        let (store, hosting, window) = try await openForm(groupColor: nil)
        defer { window.close() }

        let row = bluest(in: hosting, minY: 500, maxY: 560, maxX: 320)
        let iconBefore = bluest(in: hosting, minY: 380, maxY: 470, maxX: 400).1
        #expect(row.1 > 0.3, "no blue swatch in the Color row")

        click(at: row.0, in: hosting)
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(30)) }
        let iconAfter = bluest(in: hosting, minY: 380, maxY: 470, maxX: 400).1
        #expect(iconAfter > iconBefore + 0.2, "picking Blue did not recolor the icon tile")

        try await save(hosting)
        #expect(store.session("box")?.colorID == "blue")
        #expect(store.colorID(forSession: "box") == "blue")
    }

    /// In a colored group there is nothing to pick: the row holds no
    /// swatches, and saving leaves the session's own color as it was.
    @Test func aSessionInAColoredGroupHasNoColorToPick() async throws {
        let (store, hosting, window) = try await openForm(groupColor: "red", sessionColor: "#E07BD8")
        defer { window.close() }

        let row = bluest(in: hosting, minY: 480, maxY: 580, maxX: 780)
        #expect(row.1 < 0.15, "a blue swatch is on offer inside a red group (\(row.1))")

        try await save(hosting)
        #expect(store.session("box")?.colorID == "#E07BD8")
        #expect(store.colorID(forSession: "box") == "red")
    }
}
