import AppKit
import SwiftUI
import Testing
@testable import Termstead

@MainActor @Suite(.serialized)
struct VNCFormTests {
    @Test func savedVNCOptionsSurviveEditingInBothAppearances() async throws {
        for theme in [Theme.graphite, .daylight] {
            let store = SessionStore.sample()
            var session = try #require(store.session("lab-vnc"))
            session.vnc.viewOnly = true
            session.vnc.clipboard = false
            store.applySessionEdits(originalID: session.id, updated: session,
                                    parentID: store.currentGroupID(ofSession: session.id))
            var didSave = false
            let hosting = NSHostingView(rootView: SessionSheet(mode: .edit(sessionID: session.id))
                .environment(store).environment(ConnectionStore()).environment(SnippetStore(url: nil))
                .environment(\.theme, theme).environment(\.closeForm, { didSave = true }))
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 820, height: 648),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(250))
            hosting.layoutSubtreeIfNeeded()
            #expect(hosting.fittingSize == CGSize(width: 820, height: 648))
            let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to:
                FileManager.default.temporaryDirectory.appendingPathComponent("termstead-vnc-form-\(theme.id).png"))
            let location = hosting.convert(NSPoint(x: 606, y: hosting.isFlipped ? 610 : 38), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                window.sendEvent(event)
            }
            try await Task.sleep(for: .milliseconds(150))
            let saved = try #require(store.session(session.id))
            #expect(didSave)
            #expect(saved.kind == .vnc && saved.auth == .password)
            #expect(saved.vnc == session.vnc)
            #expect(saved.port == 5901)
        }
    }
}
