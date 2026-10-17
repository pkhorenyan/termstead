import AppKit
import Testing
@testable import Termstead

/// The sidebar can sit on either side of the window; on the right, its inner
/// edge is its leading one, so a drag to the left widens it.
@MainActor
struct SidebarSideTests {
    @Test func dragsWidenTowardTheTerminal() {
        let range = 230.0...434.0
        #expect(SidebarResizeHandle.width(from: 282, dragged: 40, growsLeftward: false, range: range) == 322)
        #expect(SidebarResizeHandle.width(from: 282, dragged: -40, growsLeftward: true, range: range) == 322)
        #expect(SidebarResizeHandle.width(from: 282, dragged: 40, growsLeftward: true, range: range) == 242)
        #expect(SidebarResizeHandle.width(from: 282, dragged: -500, growsLeftward: true, range: range) == 434)
    }

    @Test func itStartsOnTheLeftAndRemembersTheRight() throws {
        let suite = "termstead-sidebar-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(ThemeStore(defaults: defaults).sidebarSide == .left)

        defaults.set("right", forKey: "window.sidebarSide")
        #expect(ThemeStore(defaults: defaults).sidebarSide == .right)
    }

    @Test func cancelInSettingsPutsTheSideBack() throws {
        let suite = "termstead-sidebar-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ThemeStore(defaults: defaults)
        let before = store.snapshot
        store.sidebarSide = .right
        store.restore(before)
        #expect(store.sidebarSide == .left)
    }

    /// ⌃⌘S hides the sidebar from the View menu, and the choice outlives
    /// the launch.
    @Test func controlCommandSHidesTheSidebar() throws {
        let items = (NSApp.mainMenu?.items ?? []).compactMap { $0.submenu }.flatMap { $0.items }
        let item = items.first { $0.title == "Hide Sidebar" || $0.title == "Show Sidebar" }
        #expect(item?.keyEquivalent == "s")
        #expect(item?.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
                    == [.command, .control])

        let suite = "termstead-sidebar-hidden-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(defaults: defaults)
        state.isSidebarHidden = true
        #expect(AppState(defaults: defaults).isSidebarHidden)
        state.isSidebarHidden = false
        #expect(!AppState(defaults: defaults).isSidebarHidden)
    }
}
