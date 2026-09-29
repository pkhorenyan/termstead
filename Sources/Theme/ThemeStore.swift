import AppKit
import SwiftUI

/// Holds the appearance preferences and resolves them into the one `Theme`
/// every view reads. Persisted in `UserDefaults`.
@MainActor
@Observable
final class ThemeStore {
    private enum Key {
        static let theme = "appearance.theme"
        static let followSystem = "appearance.followSystem"
        static let fontSize = "appearance.terminalFontSize"
        static let fontFamily = "appearance.terminalFontFamily"
        static let copyOnSelect = "terminal.copyOnSelect"
        static let cursorShape = "terminal.cursorShape"
        static let cursorBlinks = "terminal.cursorBlinks"
        static let rightClickPastes = "terminal.rightClickPastes"
        static let confirmMultilinePaste = "terminal.confirmMultilinePaste"
        static let bell = "terminal.bell"
        static let optionAsMeta = "terminal.optionAsMeta"
        static let confirmClosingConnection = "terminal.confirmClosingConnection"
        static let highlighting = "terminal.highlighting"
        static let scrollback = "terminal.scrollback"
        static let sidebarSide = "window.sidebarSide"
        static let showFilesAfterLogin = "files.showAfterLogin"
    }

    /// Which edge of the window the sidebar (Sessions and SFTP) sits on.
    enum SidebarSide: String, CaseIterable, Identifiable, Sendable {
        case left, right
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    /// What the terminal bell (BEL) does — a shell rings it for a Tab with
    /// nothing to complete, or a Backspace at the start of the line.
    enum BellMode: String, CaseIterable, Identifiable, Sendable {
        case sound, flash, off
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    enum CursorShape: String, CaseIterable, Identifiable, Sendable {
        case block, underline, bar
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    /// Bundled with the app, so it is always there — and what a family that
    /// has since been uninstalled falls back to.
    static let bundledFontFamily = "JetBrains Mono"
    /// macOS's own monospaced face. It has no public family name — the system
    /// lists it under a hidden dotted one — so it is chosen by this token.
    static let systemFontFamily = "SF Mono"

    static let fontSizeRange = 10...20
    /// ⌘+ / ⌘− go further than the Settings stepper: zooming one tab is for
    /// the moment — a shared screen, a dense log — not the everyday size.
    static let zoomRange = 8...36

    /// The theme the user picked on the Appearance screen. When `followSystem`
    /// is on this is still what a dark system resolves to.
    var selectedID: String {
        didSet { UserDefaults.standard.set(selectedID, forKey: Key.theme) }
    }

    var followSystem: Bool {
        didSet { UserDefaults.standard.set(followSystem, forKey: Key.followSystem) }
    }

    var terminalFontSize: Int {
        didSet { UserDefaults.standard.set(terminalFontSize, forKey: Key.fontSize) }
    }

    /// The terminal's font family, by the name the font menu shows.
    var terminalFontFamily: String {
        didSet { UserDefaults.standard.set(terminalFontFamily, forKey: Key.fontFamily) }
    }

    /// Selecting text in a terminal copies it, as in most terminal apps. On
    /// unless turned off.
    var copyOnSelect: Bool {
        didSet { UserDefaults.standard.set(copyOnSelect, forKey: Key.copyOnSelect) }
    }

    var cursorShape: CursorShape {
        didSet { UserDefaults.standard.set(cursorShape.rawValue, forKey: Key.cursorShape) }
    }

    var cursorBlinks: Bool {
        didSet { UserDefaults.standard.set(cursorBlinks, forKey: Key.cursorBlinks) }
    }

    /// Right-click pastes, as in MobaXterm and PuTTY, instead of opening the
    /// menu; ⌃-click still opens it.
    var rightClickPastes: Bool {
        didSet { UserDefaults.standard.set(rightClickPastes, forKey: Key.rightClickPastes) }
    }

    /// A paste of several lines asks first: each line would otherwise reach the
    /// shell as a command the moment it lands.
    var confirmMultilinePaste: Bool {
        didSet { UserDefaults.standard.set(confirmMultilinePaste, forKey: Key.confirmMultilinePaste) }
    }

    var bell: BellMode {
        didSet { UserDefaults.standard.set(bell.rawValue, forKey: Key.bell) }
    }

    /// ⌥ sends Meta (Esc-prefixed) for Alt shortcuts in the shell, Emacs or mc.
    /// Off, ⌥ types the characters macOS puts on it — `@`, `€`, `ё`, `#`.
    var optionAsMeta: Bool {
        didSet { UserDefaults.standard.set(optionAsMeta, forKey: Key.optionAsMeta) }
    }

    /// Keyword highlighting of what the server sends, MobaXterm style.
    var highlighting: KeywordHighlighter.Mode {
        didSet { UserDefaults.standard.set(highlighting.rawValue, forKey: Key.highlighting) }
    }

    /// Lines of history each tab keeps above the screen. SwiftTerm's own
    /// default is 500, which a single `journalctl` or build log overruns.
    var scrollbackLines: Int {
        didSet { UserDefaults.standard.set(scrollbackLines, forKey: Key.scrollback) }
    }
    static let scrollbackChoices = [1_000, 10_000, 50_000, 100_000]

    var sidebarSide: SidebarSide {
        didSet { UserDefaults.standard.set(sidebarSide.rawValue, forKey: Key.sidebarSide) }
    }

    /// The sidebar turns to SFTP once a new connection has logged in, as
    /// MobaXterm's does. On unless turned off.
    var showFilesAfterLogin: Bool {
        didSet { UserDefaults.standard.set(showFilesAfterLogin, forKey: Key.showFilesAfterLogin) }
    }

    /// Closing a tab, or quitting, with a live ssh session asks first.
    var confirmClosingConnection: Bool {
        didSet { UserDefaults.standard.set(confirmClosingConnection, forKey: Key.confirmClosingConnection) }
    }

    /// Mirrors `NSApp.effectiveAppearance`; kept as stored state so that views
    /// re-render when the user flips macOS between light and dark.
    private(set) var systemIsDark: Bool

    /// Written once in `init` and read once in `deinit`, which is nonisolated.
    @ObservationIgnored
    nonisolated(unsafe) private var appearanceObservation: (any NSObjectProtocol)?

    /// A new user gets Graphite, dark, whatever macOS is set to: following the
    /// system is a choice in Settings, not the default.
    init(defaults: UserDefaults = .standard) {
        selectedID = defaults.string(forKey: Key.theme) ?? Theme.graphite.id
        followSystem = Self.bool(defaults, Key.followSystem, default: false)
        let storedSize = defaults.integer(forKey: Key.fontSize)
        terminalFontSize = Self.fontSizeRange.contains(storedSize) ? storedSize : 13
        let storedFamily = defaults.string(forKey: Key.fontFamily) ?? Self.bundledFontFamily
        terminalFontFamily = Self.font(family: storedFamily, size: 13) == nil
            ? Self.bundledFontFamily : storedFamily
        copyOnSelect = Self.bool(defaults, Key.copyOnSelect, default: true)
        cursorShape = defaults.string(forKey: Key.cursorShape).flatMap(CursorShape.init) ?? .block
        cursorBlinks = Self.bool(defaults, Key.cursorBlinks, default: true)
        rightClickPastes = Self.bool(defaults, Key.rightClickPastes, default: false)
        confirmMultilinePaste = Self.bool(defaults, Key.confirmMultilinePaste, default: true)
        bell = defaults.string(forKey: Key.bell).flatMap(BellMode.init) ?? .sound
        optionAsMeta = Self.bool(defaults, Key.optionAsMeta, default: true)
        confirmClosingConnection = Self.bool(defaults, Key.confirmClosingConnection, default: true)
        highlighting = defaults.string(forKey: Key.highlighting).flatMap(KeywordHighlighter.Mode.init) ?? .standard
        let storedScrollback = defaults.integer(forKey: Key.scrollback)
        scrollbackLines = Self.scrollbackChoices.contains(storedScrollback) ? storedScrollback : 10_000
        sidebarSide = defaults.string(forKey: Key.sidebarSide).flatMap(SidebarSide.init) ?? .left
        showFilesAfterLogin = Self.bool(defaults, Key.showFilesAfterLogin, default: true)
        systemIsDark = Self.readSystemIsDark()

        appearanceObservation = DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.systemIsDark = Self.readSystemIsDark()
            }
        }
    }

    deinit {
        if let appearanceObservation {
            DistributedNotificationCenter.default.removeObserver(appearanceObservation)
        }
    }

    /// Asks macOS, not AppKit. The app overrides `NSApp.appearance` so that its
    /// sheets and popovers follow the theme, which means `effectiveAppearance`
    /// would only hand back the theme it was just told about — and "follow the
    /// system" would latch on whatever it started as.
    private static func readSystemIsDark() -> Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?
            .lowercased().hasPrefix("dark") ?? false
    }

    /// The theme the user selected, regardless of the system.
    var selected: Theme { .named(selectedID) }

    /// What the app actually paints with.
    var current: Theme {
        guard followSystem else { return selected }
        if systemIsDark {
            // A light pick can't stand in for dark mode; fall back to the default.
            return selected.isDark ? selected : .graphite
        }
        return selected.kind == .light ? selected : .systemLight
    }

    /// The sentence under the "Follow macOS light / dark mode" checkbox.
    var systemNote: String {
        let picked = selected
        if followSystem {
            let dark = picked.isDark ? picked.name : Theme.graphite.name
            return "Uses \(Theme.systemLight.name) when macOS is light and \(dark) when it is dark."
        }
        return "Always uses \(picked.name), whatever macOS is set to."
    }

    func select(_ theme: Theme) { selectedID = theme.id }

    func nudgeFontSize(by delta: Int) {
        terminalFontSize = min(Self.fontSizeRange.upperBound,
                               max(Self.fontSizeRange.lowerBound, terminalFontSize + delta))
    }

    /// A tab's size after ⌘+ / ⌘−, from its own size (`nil`: the Settings
    /// one). Landing back on the Settings size gives `nil`, so the tab follows
    /// Settings again rather than holding a copy of it.
    func zoomedSize(from size: Int?, by delta: Int) -> Int? {
        let zoomed = min(Self.zoomRange.upperBound,
                         max(Self.zoomRange.lowerBound, (size ?? terminalFontSize) + delta))
        return zoomed == terminalFontSize ? nil : zoomed
    }

    /// Row height the transcript uses. The mockup pairs a 13pt glyph with a
    /// 20pt line box; that ratio is kept as the size changes.
    var terminalLineHeight: CGFloat {
        (CGFloat(terminalFontSize) * 20 / 13).rounded()
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue: Theme = .graphite
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

extension ThemeStore {
    /// A stored switch, or `fallback` when it was never set. `bool(forKey:)`
    /// rather than `as? Bool`: a launch argument such as `-appearance.followSystem NO`
    /// arrives as the string "NO", which `as? Bool` does not read.
    static func bool(_ defaults: UserDefaults, _ key: String, default fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }
}

extension ThemeStore {
    /// The terminal's font at the chosen size, as AppKit draws it.
    var terminalFont: NSFont { terminalFont(size: nil) }

    /// The terminal's font at a tab's own size; `nil` is the chosen one.
    func terminalFont(size: Int?) -> NSFont {
        let points = CGFloat(size ?? terminalFontSize)
        return Self.font(family: terminalFontFamily, size: points)
            ?? Self.font(family: Self.bundledFontFamily, size: points)
            ?? .monospacedSystemFont(ofSize: points, weight: .regular)
    }

    /// `nil` when the family is not installed (any more).
    static func font(family: String, size: CGFloat) -> NSFont? {
        switch family {
        case bundledFontFamily:
            // By PostScript name: asking for the family by name can pick up a
            // system-installed copy of a different version.
            return NSFont(name: SBFont.MonoWeight.regular.postScriptName, size: size)
        case systemFontFamily:
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        default:
            let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
            return font?.familyName == family ? font : nil
        }
    }

    /// Every monospaced family the terminal can use: the bundled one, the
    /// system's, then whatever fixed-pitch families are installed, by name.
    /// Proportional fonts are left out on purpose — a terminal lays text out on
    /// a grid of equal cells, and anything else overlaps or leaves gaps.
    static func monospacedFamilies() -> [String] {
        let installed = Set(
            (NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? [])
                .compactMap { NSFont(name: $0, size: 12) }
                .filter(canSetText)
                .compactMap(\.familyName)
                .filter { !$0.hasPrefix(".") && $0 != bundledFontFamily && $0 != systemFontFamily }
        )
        return [bundledFontFamily, systemFontFamily]
            + installed.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Icon fonts are fixed-pitch too — Nerd Fonts ships a "Symbols" one with
    /// no letters at all — and a terminal set in one has nothing to write with.
    private static func canSetText(_ font: NSFont) -> Bool {
        let needed = CharacterSet(charactersIn: "AZaz09$~/")
        return needed.isSubset(of: font.coveredCharacterSet)
    }
}

extension ThemeStore {
    /// Everything the Appearance window can change, so Cancel can put it back.
    struct Snapshot: Equatable {
        var selectedID: String
        var followSystem: Bool
        var terminalFontSize: Int
        var terminalFontFamily: String
        var copyOnSelect: Bool
        var cursorShape: CursorShape
        var cursorBlinks: Bool
        var rightClickPastes: Bool
        var confirmMultilinePaste: Bool
        var bell: BellMode
        var optionAsMeta: Bool
        var confirmClosingConnection: Bool
        var highlighting: KeywordHighlighter.Mode
        var scrollbackLines: Int
        var sidebarSide: SidebarSide
        var showFilesAfterLogin: Bool
    }

    var snapshot: Snapshot {
        Snapshot(selectedID: selectedID, followSystem: followSystem,
                 terminalFontSize: terminalFontSize, terminalFontFamily: terminalFontFamily,
                 copyOnSelect: copyOnSelect, cursorShape: cursorShape, cursorBlinks: cursorBlinks,
                 rightClickPastes: rightClickPastes, confirmMultilinePaste: confirmMultilinePaste,
                 bell: bell, optionAsMeta: optionAsMeta,
                 confirmClosingConnection: confirmClosingConnection, highlighting: highlighting,
                 scrollbackLines: scrollbackLines, sidebarSide: sidebarSide,
                 showFilesAfterLogin: showFilesAfterLogin)
    }

    func restore(_ snapshot: Snapshot) {
        selectedID = snapshot.selectedID
        followSystem = snapshot.followSystem
        terminalFontSize = snapshot.terminalFontSize
        terminalFontFamily = snapshot.terminalFontFamily
        copyOnSelect = snapshot.copyOnSelect
        cursorShape = snapshot.cursorShape
        cursorBlinks = snapshot.cursorBlinks
        rightClickPastes = snapshot.rightClickPastes
        confirmMultilinePaste = snapshot.confirmMultilinePaste
        bell = snapshot.bell
        optionAsMeta = snapshot.optionAsMeta
        confirmClosingConnection = snapshot.confirmClosingConnection
        highlighting = snapshot.highlighting
        scrollbackLines = snapshot.scrollbackLines
        sidebarSide = snapshot.sidebarSide
        showFilesAfterLogin = snapshot.showFilesAfterLogin
    }
}
