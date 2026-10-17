import AppKit
import SwiftUI
import Testing
@testable import Termstead

/// The accent ring on a form field goes where the keyboard goes. It was a
/// flag the form set on its first field, so after Tab the ring stayed there
/// while the typing went to the next one.
@MainActor
struct FieldFocusRingTests {
    @Test func theRingFollowsTab() async throws {
        let theme = Theme.graphite
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = NSHostingView(rootView: Fields().environment(\.theme, theme))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await pause()

        // A test app is never active, so the window does not choose a first
        // field the way a form window does; give it the first one.
        let fields = textFields(in: try #require(window.contentView))
            .sorted { $0.convert($0.bounds, to: nil).minY > $1.convert($1.bounds, to: nil).minY }
        #expect(fields.count == 2)
        window.makeFirstResponder(try #require(fields.first))
        try await pause()
        #expect(try ringColor(of: 0, in: window) == theme.accent)
        #expect(try ringColor(of: 1, in: window) == theme.border)

        let tab = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                timestamp: 0, windowNumber: window.windowNumber,
                                                context: nil, characters: "\t",
                                                charactersIgnoringModifiers: "\t",
                                                isARepeat: false, keyCode: 48))
        window.sendEvent(tab)
        try await pause()
        #expect(try ringColor(of: 0, in: window) == theme.border, "the ring stayed on the first field")
        #expect(try ringColor(of: 1, in: window) == theme.accent, "the ring did not reach the second field")
    }

    private struct Fields: View {
        @State private var first = ""
        @State private var second = ""
        var body: some View {
            VStack(spacing: 20) {
                SBTextField(text: $first, placeholder: "first", font: .system(size: 13))
                SBTextField(text: $second, placeholder: "second", font: .system(size: 13))
            }
            .padding(14)
            .frame(width: 300, height: 120)
            .background(Theme.graphite.window.color)
        }
    }

    private func textFields(in view: NSView) -> [NSTextField] {
        ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap { textFields(in: $0) }
    }

    private func pause() async throws {
        for _ in 0..<6 { try await Task.sleep(for: .milliseconds(25)) }
    }

    /// The color of a field's border at the middle of its top edge. Fields
    /// are 36pt tall from the 14pt padding, 20pt apart.
    private func ringColor(of field: Int, in window: NSWindow) throws -> RGB {
        let view = try #require(window.contentView)
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = Double(rep.pixelsHigh) / Double(view.bounds.height)
        let top = 14 + Double(field) * 56
        let color = try #require(rep.colorAt(x: Int(150 * scale), y: Int((top + 0.5) * scale))?
            .usingColorSpace(.sRGB))
        let rgb = RGB(r: Double(color.redComponent), g: Double(color.greenComponent), b: Double(color.blueComponent))
        // Snapped to whichever of the two it is nearest.
        let theme = Theme.graphite
        let toAccent = abs(rgb.r - theme.accent.r) + abs(rgb.g - theme.accent.g) + abs(rgb.b - theme.accent.b)
        let toBorder = abs(rgb.r - theme.border.r) + abs(rgb.g - theme.border.g) + abs(rgb.b - theme.border.b)
        return toAccent < toBorder ? theme.accent : theme.border
    }
}
