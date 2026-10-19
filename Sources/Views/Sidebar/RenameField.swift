import SwiftUI

/// The editable name a sidebar row shows while it is being renamed, as in
/// Finder: Return keeps the new name, Escape keeps the old one, and clicking
/// elsewhere keeps the new one too.
struct RenameField: View {
    @Environment(\.theme) private var theme
    @Binding var text: String
    var font: Font
    var onCommit: () -> Void
    var onCancel: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(theme.text.color)
            .focused($focused)
            .onSubmit(onCommit)
            .onExitCommand(perform: onCancel)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(theme.field.color)
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(theme.accent.color, lineWidth: 1))
            )
            // A click on the list's empty space takes the keyboard nowhere,
            // so the field never lost focus and stayed open until Return.
            // Finder ends the edit on any click outside the name.
            .background(ClickOutside(onClick: onCommit))
            .onAppear { focused = true }
            // Losing focus — a click elsewhere — keeps what was typed. After
            // Escape the row has already left renaming, so this does nothing.
            .onChange(of: focused) { _, isFocused in
                if !isFocused { onCommit() }
            }
            .accessibilityLabel("Name")
    }
}

/// Calls `onClick` for a mouse press anywhere in the app outside the view it
/// backs, while that view is in a window. The press itself goes on as usual.
private struct ClickOutside: NSViewRepresentable {
    var onClick: () -> Void

    func makeNSView(context: Context) -> Watcher { Watcher() }

    func updateNSView(_ view: Watcher, context: Context) {
        view.onClick = onClick
    }

    static func dismantleNSView(_ view: Watcher, coordinator: ()) {
        view.stop()
    }

    final class Watcher: NSView {
        var onClick: () -> Void = {}
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
                [weak self] event in
                guard let self, let window else { return event }
                let inside = event.window === window
                    && bounds.contains(convert(event.locationInWindow, from: nil))
                if !inside {
                    // After the press is handled: a click on another row
                    // selects it first, as it would without an edit open.
                    DispatchQueue.main.async { [weak self] in self?.onClick() }
                }
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        // Clicks go to the field above; this view only watches.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
