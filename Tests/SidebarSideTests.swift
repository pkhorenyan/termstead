import AppKit
import SwiftUI
import Testing
@testable import Termstead

/// The sidebar can sit on either side of the window; on the right, its inner
/// edge is its leading one, so a drag to the left widens it.
@MainActor
struct SidebarSideTests {
    @Test func dragsWidenTowardTheTerminal() {
        let range = Metrics.sidebarWidthRange(windowWidth: 960, workspaceMinimum: 240)
        #expect(SidebarResizeHandle.width(from: 282, dragged: 40, growsLeftward: false, range: range) == 322)
        #expect(SidebarResizeHandle.width(from: 282, dragged: -40, growsLeftward: true, range: range) == 322)
        #expect(SidebarResizeHandle.width(from: 282, dragged: 40, growsLeftward: true, range: range) == 242)
        #expect(SidebarResizeHandle.width(from: 282, dragged: -500, growsLeftward: true, range: range) == 720)
    }

    @Test func sidebarUsesTheWindowWidthAndLeavesRoomForTheWorkspace() {
        let wide = Metrics.sidebarWidthRange(windowWidth: 1280, workspaceMinimum: 240)
        let narrow = Metrics.sidebarWidthRange(windowWidth: Metrics.minWindowSize.width, workspaceMinimum: 240)

        #expect(SidebarResizeHandle.width(from: 282, dragged: 500, growsLeftward: false, range: wide) == 782)
        #expect(SidebarResizeHandle.width(from: 782, dragged: 500, growsLeftward: false, range: narrow) == 720)
        #expect(Metrics.sidebarWidthRange(windowWidth: 0, workspaceMinimum: 240) == 230...230)
        #expect(Metrics.sidebarWidthRange(windowWidth: 960, workspaceMinimum: EmptyStateView.contentWidth).upperBound == 440)
    }

    @Test func bothColumnsStayUsableWhenTheSidebarIsFullyExpanded() {
        let width = Metrics.minWindowSize.width
        let minimum = Metrics.minimumWorkspaceWidth(columns: PaneLayout.sideBySide.columns)
        let sidebar = Metrics.sidebarWidthRange(windowWidth: width, workspaceMinimum: minimum).upperBound
        let available = width - CGFloat(sidebar) - 1
        #expect(available == 480)
        #expect(PaneSplit<EmptyView, EmptyView>.horizontalRange(available: available) == 0.5...0.5)
        #expect(PaneSplit<EmptyView, EmptyView>.horizontalRange(available: 600) == 0.4...0.6)
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

    /// ⌘B hides the sidebar from the View menu, and the choice outlives
    /// the launch.
    @Test func commandBHidesTheSidebar() throws {
        let items = (NSApp.mainMenu?.items ?? []).compactMap { $0.submenu }.flatMap { $0.items }
        let item = items.first { $0.title == "Hide Sidebar" || $0.title == "Show Sidebar" }
        #expect(item?.keyEquivalent == "b")
        #expect(item?.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
                    == .command)

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
