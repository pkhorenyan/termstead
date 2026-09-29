import AppKit
import SwiftTerm
import Testing
@testable import Termstead

@MainActor
struct BellTests {
    private func terminal(_ mode: ThemeStore.BellMode) -> (SSHTerminalView, () -> Int) {
        let view = SSHTerminalView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.bellMode = mode
        var rings = 0
        view.playBell = { rings += 1 }
        return (view, { rings })
    }

    @Test func soundRings() {
        let (view, rings) = terminal(.sound)
        view.bell(source: view.getTerminal())
        #expect(rings() == 1)
    }

    @Test func offStaysSilent() {
        let (view, rings) = terminal(.off)
        view.bell(source: view.getTerminal())
        #expect(rings() == 0)
        #expect(view.bellFlashLayer == nil)
    }

    @Test func aBurstRingsOnce() async throws {
        let (view, rings) = terminal(.sound)
        for _ in 0..<20 { view.bell(source: view.getTerminal()) }
        #expect(rings() == 1)
        try await Task.sleep(for: .milliseconds(Int(SSHTerminalView.bellGap * 1000) + 30))
        view.bell(source: view.getTerminal())
        #expect(rings() == 2)
    }

    @Test func flashFlashesInsteadOfBeeping() {
        let (view, rings) = terminal(.flash)
        view.bell(source: view.getTerminal())
        #expect(rings() == 0)
        #expect(view.bellFlashLayer?.animation(forKey: "bell") != nil)
    }
}
