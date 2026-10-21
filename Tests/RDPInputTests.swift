import AppKit
import Carbon.HIToolbox
import Foundation
import IOSurface
import Testing
@testable import Termstead

/// Keys and the mouse for a remote desktop.
struct RDPInputTests {
    private func key(_ keyCode: Int, iso: Bool = false) -> RDPKeyboard.Key? {
        RDPKeyboard.key(forKeyCode: UInt16(keyCode), iso: iso)
    }

    @Test func lettersAndDigitsAreWhereAPCHasThem() {
        #expect(key(kVK_ANSI_A) == RDPKeyboard.Key(0x1E))
        #expect(key(kVK_ANSI_Q) == RDPKeyboard.Key(0x10))
        #expect(key(kVK_ANSI_Z) == RDPKeyboard.Key(0x2C))
        #expect(key(kVK_ANSI_M) == RDPKeyboard.Key(0x32))
        #expect(key(kVK_ANSI_1) == RDPKeyboard.Key(0x02))
        #expect(key(kVK_ANSI_0) == RDPKeyboard.Key(0x0B))
        #expect(key(kVK_Return) == RDPKeyboard.Key(0x1C))
        #expect(key(kVK_Delete) == RDPKeyboard.Key(0x0E))
        #expect(key(kVK_Escape) == RDPKeyboard.Key(0x01))
    }

    @Test func functionKeys() {
        let codes = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10]
        for (index, code) in codes.enumerated() {
            #expect(key(code) == RDPKeyboard.Key(UInt8(0x3B + index)))
        }
        #expect(key(kVK_F11) == RDPKeyboard.Key(0x57))
        #expect(key(kVK_F12) == RDPKeyboard.Key(0x58))
    }

    /// Arrows and the navigation block are the extended (0xE0) keys.
    @Test func navigationKeysAreExtended() {
        #expect(key(kVK_LeftArrow) == RDPKeyboard.Key(0x4B, extended: true))
        #expect(key(kVK_RightArrow) == RDPKeyboard.Key(0x4D, extended: true))
        #expect(key(kVK_UpArrow) == RDPKeyboard.Key(0x48, extended: true))
        #expect(key(kVK_DownArrow) == RDPKeyboard.Key(0x50, extended: true))
        #expect(key(kVK_Home) == RDPKeyboard.Key(0x47, extended: true))
        #expect(key(kVK_ForwardDelete) == RDPKeyboard.Key(0x53, extended: true))
    }

    /// WinPR sent right Control and Fn as the Windows key; Command is the
    /// Mac's own.
    @Test func modifiersOnBothSides() {
        #expect(key(kVK_Control) == RDPKeyboard.Key(0x1D))
        #expect(key(kVK_RightControl) == RDPKeyboard.Key(0x1D, extended: true))
        #expect(key(kVK_Option) == RDPKeyboard.Key(0x38))
        #expect(key(kVK_RightOption) == RDPKeyboard.Key(0x38, extended: true))
        #expect(key(kVK_Shift) == RDPKeyboard.Key(0x2A))
        #expect(key(kVK_RightShift) == RDPKeyboard.Key(0x36))
        #expect(key(kVK_Command) == nil)
        #expect(key(kVK_RightCommand) == nil)
        #expect(key(kVK_Function) == nil)
    }

    /// On ISO keyboards macOS swaps the key left of 1 and the one next to
    /// the left Shift; the PC keys follow where they sit.
    @Test func isoKeysFollowTheirPlace() {
        #expect(key(kVK_ANSI_Grave) == RDPKeyboard.Key(0x29))
        #expect(key(kVK_ISO_Section, iso: true) == RDPKeyboard.Key(0x29))
        #expect(key(kVK_ANSI_Grave, iso: true) == RDPKeyboard.Key(0x56))
    }

    /// The side comes from the device bits: left Shift let go while the
    /// right one is held is still a release of the left.
    @Test func aModifiersSideComesFromItsOwnBit() {
        let rightShiftHeld: UInt = 0x0004 | NSEvent.ModifierFlags.shift.rawValue
        #expect(RDPKeyboard.modifierIsDown(keyCode: UInt16(kVK_Shift), flags: rightShiftHeld) == false)
        #expect(RDPKeyboard.modifierIsDown(keyCode: UInt16(kVK_RightShift), flags: rightShiftHeld) == true)
        #expect(RDPKeyboard.modifierIsDown(keyCode: UInt16(kVK_Command), flags: 0x0008) == nil)
    }

    @Test func layouts() {
        #expect(RDPKeyboard.layoutID(sourceID: "com.apple.keylayout.US", language: "en") == 0x409)
        #expect(RDPKeyboard.layoutID(sourceID: "com.apple.keylayout.Russian", language: "ru") == 0x419)
        #expect(RDPKeyboard.layoutID(sourceID: "com.apple.keylayout.British", language: "en") == 0x809)
        #expect(RDPKeyboard.layoutID(sourceID: "com.apple.keylayout.German", language: "de-DE") == 0x407)
        #expect(RDPKeyboard.layoutID(sourceID: "x", language: "xx") == 0x409)
    }

    // MARK: - Mouse

    /// A 1600×1000 desktop in a 1000×800 view: scaled to 1000×625, centred.
    @Test func pointsLandOnTheDesktopAsShown() {
        let desktop = CGSize(width: 1600, height: 1000)
        let bounds = CGSize(width: 1000, height: 800)
        #expect(RDPPointer.shownRect(of: desktop, in: bounds) == CGRect(x: 0, y: 87.5, width: 1000, height: 625))
        func pixel(_ x: CGFloat, _ y: CGFloat) -> [Int] {
            let found = RDPPointer.pixel(at: CGPoint(x: x, y: y), desktop: desktop, bounds: bounds)
            return [found.x, found.y]
        }
        #expect(pixel(500, 400) == [800, 500])
        // Above the desktop, in the band: the top edge.
        #expect(pixel(0, 10) == [0, 0])
        #expect(pixel(2000, 2000) == [1599, 999])
    }

    @Test func wheelFlagsCarryTheirSign() {
        #expect(RDPPointer.wheelFlags(120, horizontal: false) == 0x0200 | 0x078)
        #expect(RDPPointer.wheelFlags(-120, horizontal: false) == 0x0200 | 0x188)
        #expect(RDPPointer.wheelFlags(400, horizontal: true) == 0x0400 | 0x0FF)
    }

    @Test func aMouseWheelLineIsANotch() {
        var wheel = RDPPointer.Wheel()
        #expect(wheel.steps(for: 1, precise: false) == [120])
        #expect(wheel.steps(for: -3, precise: false) == [-255, -105])
    }

    /// A trackpad's small moves add up instead of being lost one by one.
    @Test func trackpadMovesAddUp() {
        var wheel = RDPPointer.Wheel()
        var total = 0
        for _ in 0..<30 { total += wheel.steps(for: 0.5, precise: true).reduce(0, +) }
        #expect(total == 120)
    }
}

/// Typing into the lab's xrdp: its login screen takes the password through
/// the engine's keys, and the desktop replaces it.
@MainActor
@Suite(.serialized, .enabled(if: TestLabRDP.isUp, "the lab's RDP server is not running (TestLab/lab.sh up)"))
struct RDPTypingTests {
    @Test func thePasswordTypedAtTheLoginScreenLogsIn() async throws {
        let desktop = RDPDesktop()
        var launch = RDPLaunch(session: SessionStore.sample().session("lab-rdp")!, password: "")
        launch.options.sound = false
        desktop.availableSize = { (CGSize(width: 800, height: 600), 1) }
        // The keys typed are US positions, whatever this Mac's layout is now.
        desktop.keyboardLayout = { 0x409 }
        desktop.start(launch) { try await RDPSocket.connect(host: "127.0.0.1", port: 3390) }
        await wait(upTo: 20) { desktop.phase == .showing }
        try #require(desktop.phase == .showing)
        try await Task.sleep(for: .seconds(1))
        let loginScreen = try #require(centre(of: desktop))

        // xrdp's dialog opens on the password field, the user filled in.
        for code in [kVK_ANSI_L, kVK_ANSI_A, kVK_ANSI_B, kVK_Return] {
            let key = try #require(RDPKeyboard.key(forKeyCode: UInt16(code), iso: false))
            desktop.press([key])
        }
        // The dialog goes first, onto xrdp's teal; then Xfce's dark desktop.
        await wait(upTo: 30) { centre(of: desktop).map(isXfceBackground) ?? false }
        let after = try #require(centre(of: desktop))
        #expect(after != loginScreen)
        #expect(isXfceBackground(after))
        desktop.stop()
    }

    private func wait(upTo seconds: Double, until done: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Xfce's default background is a dark blue; xrdp's login screen is
    /// teal and light.
    private func isXfceBackground(_ pixel: [UInt8]) -> Bool {
        pixel.allSatisfy { $0 < 90 }
    }

    /// The colour a little above the middle: the login dialog there, the
    /// desktop's background once logged in.
    private func centre(of desktop: RDPDesktop) -> [UInt8]? {
        guard let surface = desktop.view.layer?.contents as? IOSurface ?? nil else { return nil }
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let pixel = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
            + (surface.height / 2 - 60) * surface.bytesPerRow + surface.width / 2 * 4
        return [pixel[0], pixel[1], pixel[2]]
    }
}

/// The desktop's size against the tab's.
struct RDPSizeTests {
    private func options(sharp: Bool = true, display: RDPOptions.Display = .fitTab) -> RDPOptions {
        var options = RDPOptions()
        options.sharpOnRetina = sharp
        options.display = display
        return options
    }

    @Test func aRetinaTabIsTwiceItsPointsAt200Percent() {
        let fit = RDPDesktop.fit(points: CGSize(width: 1001, height: 700), screenScale: 2, options: options())
        #expect(fit.width == 2002 && fit.height == 1400 && fit.scale == 200)
    }

    @Test func notSharpIsAPixelAPoint() {
        let fit = RDPDesktop.fit(points: CGSize(width: 1001, height: 700), screenScale: 2, options: options(sharp: false))
        // Even, as RDP wants.
        #expect(fit.width == 1000 && fit.height == 700 && fit.scale == 100)
    }

    @Test func aPlainScreenIsAPixelAPointEvenWhenSharp() {
        let fit = RDPDesktop.fit(points: CGSize(width: 900, height: 600), screenScale: 1, options: options())
        #expect(fit.width == 900 && fit.height == 600 && fit.scale == 100)
    }

    @Test func aFixedSizeStaysFixed() {
        let fit = RDPDesktop.fit(points: CGSize(width: 300, height: 200), screenScale: 2,
                                 options: options(display: .fixed(width: 1920, height: 1080)))
        #expect(fit.width == 1920 && fit.height == 1080)
    }

    @Test func aTinyTabIsHeldToWhatRDPTakes() {
        let fit = RDPDesktop.fit(points: CGSize(width: 50, height: 9000), screenScale: 1, options: options())
        #expect(fit.width == 200 && fit.height == 8192)
    }
}

/// Resizing a tab resizes the lab's desktop, through Display Control.
@MainActor
@Suite(.serialized, .enabled(if: TestLabRDP.isUp, "the lab's RDP server is not running (TestLab/lab.sh up)"))
struct RDPResizeTests {
    @Test func theDesktopFollowsTheTab() async throws {
        let desktop = RDPDesktop()
        var launch = RDPLaunch(session: SessionStore.sample().session("lab-rdp")!, password: "lab")
        launch.options.sound = false
        var tab = CGSize(width: 800, height: 600)
        desktop.availableSize = { (tab, 1) }
        desktop.start(launch) { try await RDPSocket.connect(host: "127.0.0.1", port: 3390) }
        await wait(upTo: 20) { desktop.phase == .showing }
        try #require(desktop.size == CGSize(width: 800, height: 600))
        // The display channel comes up a moment after the desktop does.
        try await Task.sleep(for: .seconds(2))

        tab = CGSize(width: 1024, height: 700)
        desktop.tabSizeChanged()
        await wait(upTo: 15) { desktop.size == CGSize(width: 1024, height: 700) }
        #expect(desktop.size == CGSize(width: 1024, height: 700))
        desktop.stop()
    }

    private func wait(upTo seconds: Double, until done: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
