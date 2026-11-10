import AppKit
import SwiftUI
import Testing
@testable import Termstead

@MainActor
@Suite(.serialized)
struct SessionTransferFormTests {
    @Test func formsRenderInBothAppearances() async throws {
        for (name, mode, theme) in [
            ("export-light", SessionTransferSheet.Mode.export(groupID: nil), Theme.daylight),
            ("import-dark", .importFile, .graphite)
        ] {
            let window = FormWindow(contentRect: NSRect(x: 100, y: 100, width: 580, height: 620),
                                    styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            let hosting = NSHostingView(rootView: SessionTransferSheet(mode: mode)
                .environment(SessionStore.sample()).environment(\.theme, theme))
            window.contentView = hosting
            window.orderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(120))
            hosting.layoutSubtreeIfNeeded()
            #expect(hosting.fittingSize.width == 580)
            #expect(hosting.fittingSize.height == 620)
            #expect(!window.isWorking)
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("termstead-\(name).png")
            try png.write(to: url)
            print("TRANSFER_FORM_PNG \(url.path)")
        }
    }

    @Test func transferExtensionAndBusyWindowGuardAreAvailable() {
        #expect(SessionTransferSheet.fileType.preferredFilenameExtension == "termstead")
        let host = FormWindowHost()
        let window = FormWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.isWorking = true
        #expect(!host.windowShouldClose(window))
        window.isWorking = false
        #expect(host.windowShouldClose(window))
    }
}
