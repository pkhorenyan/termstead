import AppKit
import SwiftUI
import Foundation
import Testing
@testable import Termstead

struct CustomColorTests {
    /// The picker's square and strip work in HSB; a color survives the trip.
    @Test func hsbRoundTrips() {
        for hex in ["#E07BD8", "#5FD4A8", "#0B1D51", "#FF8800", "#123456"] {
            let rgb = RGB(hex: hex)!
            #expect(HSBColor(rgb).rgb.hex == hex)
        }
        let red = HSBColor(RGB(0xFF0000))
        #expect(abs(red.hue) < 0.001 || abs(red.hue - 1) < 0.001)
        #expect(abs(red.saturation - 1) < 0.001 && abs(red.brightness - 1) < 0.001)
    }

    @Test func hexRoundTrips() throws {
        let color = try #require(RGB(hex: "#1A2B3C"))
        #expect(color.hex == "#1A2B3C")
        #expect(RGB(hex: "1a2b3c")?.hex == "#1A2B3C")
        #expect(RGB(hex: "#12345") == nil)
        #expect(RGB(hex: "#GGGGGG") == nil)
        #expect(RGB(0xFFFFFF).contrast(with: RGB(0x000000)) > 20.9)
    }

    @Test func customIDsResolveLikePaletteIDs() {
        #expect(GroupColor.isCustom("#FF8800"))
        #expect(!GroupColor.isCustom("red"))
        #expect(GroupColor.picked("#FF8800") == RGB(0xFF8800))
        #expect(GroupColor.swatch(for: "#FF8800") != nil)
        #expect(GroupColor.swatch(for: "#nothex") == nil)
        #expect(GroupColor.swatch(for: "red")?.label == "Red")
    }

    /// Whatever is picked, names drawn in it stay readable, to the palette's
    /// own bar: 4.5:1 on every dark sidebar, and on every light sidebar and
    /// light selected row.
    @Test func anyPickedColorReadsOnEveryTheme() {
        let dark = Theme.all.filter(\.isDark)
        let light = Theme.all.filter { !$0.isDark }
        var generator = SystemRandomNumberGenerator()
        let samples = [RGB(0x000000), RGB(0xFFFFFF), RGB(0x0B1D51), RGB(0xFFF59D), RGB(0x808080)]
            + (0..<200).map { _ in RGB(UInt32.random(in: 0...0xFFFFFF, using: &generator)) }
        for picked in samples {
            let id = GroupColor.customID(picked)
            let onDark = GroupColor.rgb(for: id, on: dark[0])!
            let onLight = GroupColor.rgb(for: id, on: light[0])!
            for theme in dark {
                #expect(onDark.contrast(with: theme.sidebar) >= 4.5, "\(id) on \(theme.id)")
            }
            for theme in light {
                #expect(onLight.contrast(with: theme.sidebar) >= 4.5, "\(id) on \(theme.id)")
                #expect(onLight.contrast(with: theme.selected) >= 4.5, "\(id) on \(theme.id) selected")
            }
        }
        // A color that already reads is left as picked.
        let mint = RGB(0x5FD4A8)
        #expect(GroupColor.rgb(for: GroupColor.customID(mint), on: dark[0])?.hex == mint.hex)
    }
}

@MainActor
struct SessionColorTests {
    private func store(sessionColor: String?, groupColor: String?) -> SessionStore {
        let session = Session(id: "box", user: "u", host: "h", port: 22, icon: .server, colorID: sessionColor)
        let inner = SessionGroup(id: "inner", name: "Inner", colorID: groupColor, children: [.session("box")])
        let top = SessionGroup(id: "top", name: "Top", colorID: nil, children: [.group(inner)])
        return SessionStore(tree: [top], sessions: ["box": session], selectedID: nil, pinnedIDs: [])
    }

    private func rowColor(_ store: SessionStore) -> String? {
        for row in store.flattened.rows {
            if case .session(let data) = row, data.id == "box" { return data.colorID }
        }
        return "missing"
    }

    @Test func aSessionTakesItsGroupsColorByDefault() {
        let store = store(sessionColor: nil, groupColor: "red")
        #expect(rowColor(store) == "red")
        #expect(store.colorID(forSession: "box") == "red")
    }

    /// A colored group decides for every session in it: a color of the
    /// session's own — or "No color" — does not show there.
    @Test func aColoredGroupWinsOverTheSessionsOwn() {
        let store = store(sessionColor: "blue", groupColor: "red")
        #expect(rowColor(store) == "red")
        #expect(store.sessionIndex.colorID["box"] == "red")
        #expect(store.session("box")?.colorID == "blue", "kept for when it moves out")
        #expect(self.store(sessionColor: "none", groupColor: "red").colorID(forSession: "box") == "red")

        // Folded away, as the Pinned strip reads it.
        store.collapsedGroupIDs = ["inner"]
        #expect(store.flattened.index.colorID["box"] == "red")
    }

    /// A group set to "No color" colors nothing, so a session in it may.
    @Test func aSessionInANoColorGroupCanHaveOne() {
        let store = store(sessionColor: "blue", groupColor: "none")
        #expect(rowColor(store) == "blue")
        #expect(self.store(sessionColor: nil, groupColor: "none").color(forSession: "box") == nil)
    }

    /// Outside any colored group — even straight under a top-level folder,
    /// which never has a color itself.
    @Test func aSessionInAnUncoloredGroupCanHaveOne() {
        let store = store(sessionColor: "#FF8800", groupColor: nil)
        #expect(rowColor(store) == "#FF8800")
        #expect(store.color(forSession: "box") != nil)

        let session = Session(id: "solo", user: "u", host: "h", port: 22, icon: .server, colorID: "violet")
        let flat = SessionStore(tree: [SessionGroup(id: "top", name: "Top", colorID: nil, children: [.session("solo")])],
                                sessions: ["solo": session], selectedID: nil, pinnedIDs: [])
        #expect(flat.colorID(forSession: "solo") == "violet")
    }

    @Test func colorsAreSavedAndOldFilesStillRead() throws {
        let session = Session(id: "box", user: "u", host: "h", port: 22, icon: .server, colorID: "#123456")
        let decoded = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(session))
        #expect(decoded.colorID == "#123456")

        // Written before sessions had a color.
        let old = #"{"id":"old","user":"u","host":"h","port":22,"icon":"server","auth":"key","keyPath":"~/.ssh/id_ed25519","jumps":[]}"#
        let legacy = try JSONDecoder().decode(Session.self, from: Data(old.utf8))
        #expect(legacy.colorID == nil)
    }

    /// Renders the picker off screen and saves it, so its look can be checked
    /// without opening it by hand. The path is printed.
    @Test func thePickerRenders() throws {
        var picked: RGB?
        let view = ColorPickerView(start: RGB(0xE07BD8), onOK: { picked = $0 }, onCancel: {})
            .environment(\.theme, .graphite)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("color-picker.png")
        try png.write(to: url)
        print("PICKER_PNG \(url.path)")
        #expect(picked == nil, "nothing is picked until OK")
    }
}
