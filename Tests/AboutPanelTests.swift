import AppKit
import Testing
@testable import Termstead

@MainActor
struct AboutPanelTests {
    /// The About panel names the website and the source, as links.
    @Test func theCreditsLinkTheWebsiteAndTheSource() {
        let credits = AboutPanel.credits
        var links: [URL] = []
        credits.enumerateAttribute(.link, in: NSRange(location: 0, length: credits.length)) { value, _, _ in
            if let url = value as? URL { links.append(url) }
        }
        #expect(links == [AboutPanel.website, AboutPanel.source])
        #expect(credits.string.contains("khorenyan.com/termstead"))
    }

    /// The app menu opens with About, then Check for Updates.
    @Test func theAppMenuStartsWithAbout() throws {
        let appMenu = try #require(NSApp.mainMenu?.items.first?.submenu)
        let titles = appMenu.items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(titles.first == "About Termstead")
        #expect(titles.contains("Check for Updates…"))
        #expect(titles.filter { $0.hasPrefix("About") }.count == 1)
    }
}
