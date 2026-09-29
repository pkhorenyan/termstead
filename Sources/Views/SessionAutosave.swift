import AppKit
import SwiftUI

/// Writes the session tree back to disk half a second after it stops changing,
/// and once more on quit.
///
/// A view of its own, drawing nothing, so that reading the snapshot — which
/// touches the tree, the pins *and* the collapsed groups — invalidates only this
/// and not the window around it.
struct SessionAutosave: View {
    var storage: SessionStorage
    @Environment(SessionStore.self) private var sessionStore

    var body: some View {
        let snapshot = sessionStore.snapshot
        Color.clear
            .frame(width: 0, height: 0)
            // `task(id:)` cancels the pending save whenever the snapshot changes
            // again, which is all the debouncing this needs.
            .task(id: snapshot) {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                storage.save(snapshot)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                storage.save(sessionStore.snapshot)
            }
    }
}
