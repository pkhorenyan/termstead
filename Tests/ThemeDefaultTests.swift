import Foundation
import Testing
@testable import Termstead

/// Someone who has never opened Settings sees the dark Graphite theme, even on
/// a Mac set to light mode.
@MainActor
struct ThemeDefaultTests {
    @Test func aNewUserGetsGraphiteWhateverMacOSIsSetTo() throws {
        let suite = "termstead-theme-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ThemeStore(defaults: defaults)
        #expect(!store.followSystem)
        #expect(store.current.id == Theme.graphite.id)
        #expect(store.current.isDark)
    }

    @Test func followingMacOSIsKeptForThoseWhoChoseIt() throws {
        let suite = "termstead-theme-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "appearance.followSystem")

        #expect(ThemeStore(defaults: defaults).followSystem)
    }

    /// On for a new user; `-files.showAfterLogin NO` (the screenshot kit's)
    /// arrives as a string and still turns it off.
    @Test func sftpOpensAfterLoginUnlessTurnedOff() throws {
        let suite = "termstead-theme-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(ThemeStore(defaults: defaults).showFilesAfterLogin)
        defaults.set("NO", forKey: "files.showAfterLogin")
        #expect(!ThemeStore(defaults: defaults).showFilesAfterLogin)
    }
}
