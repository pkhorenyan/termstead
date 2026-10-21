import AppKit
import Carbon.HIToolbox

/// Keys for a remote desktop: a Mac key is sent as the PC key in the same
/// place, by its scan code, as mstsc does. The server then applies its own
/// layout, so the remote session's language decides what a key types.
enum RDPKeyboard {
    /// A PC key's Set 1 scan code; `extended` for those sent after 0xE0.
    struct Key: Hashable, Sendable {
        var code: UInt8
        var extended = false

        init(_ code: UInt8, extended: Bool = false) {
            self.code = code
            self.extended = extended
        }
    }

    /// The PC key for a Mac key code, or `nil` for one with none: Command
    /// (the Mac's own shortcuts), Fn, volume keys.
    ///
    /// On an ISO keyboard macOS reports the key left of 1 and the one next
    /// to the left Shift the other way round from where they sit, so those
    /// two change places there.
    static func key(forKeyCode keyCode: UInt16, iso: Bool = isISO) -> Key? {
        if iso, keyCode == UInt16(kVK_ISO_Section) { return Key(0x29) }
        if iso, keyCode == UInt16(kVK_ANSI_Grave) { return Key(0x56) }
        return table[keyCode]
    }

    static var isISO: Bool { KBGetLayoutType(Int16(LMGetKbdType())) == kKeyboardISO }

    static let leftControl = Key(0x1D)
    static let leftAlt = Key(0x38)
    static let leftWindows = Key(0x5B, extended: true)
    static let delete = Key(0x53, extended: true)

    /// From WinPR's Apple table (FreeRDP's own), with what it gets wrong on
    /// a Mac put right: it sent right Control and Fn as the Windows key.
    private static let table: [UInt16: Key] = [
        0x00: Key(0x1E),  // KEY_A
        0x01: Key(0x1F),  // KEY_S
        0x02: Key(0x20),  // KEY_D
        0x03: Key(0x21),  // KEY_F
        0x04: Key(0x23),  // KEY_H
        0x05: Key(0x22),  // KEY_G
        0x06: Key(0x2C),  // KEY_Z
        0x07: Key(0x2D),  // KEY_X
        0x08: Key(0x2E),  // KEY_C
        0x09: Key(0x2F),  // KEY_V
        0x0A: Key(0x56),  // OEM_102
        0x0B: Key(0x30),  // KEY_B
        0x0C: Key(0x10),  // KEY_Q
        0x0D: Key(0x11),  // KEY_W
        0x0E: Key(0x12),  // KEY_E
        0x0F: Key(0x13),  // KEY_R
        0x10: Key(0x15),  // KEY_Y
        0x11: Key(0x14),  // KEY_T
        0x12: Key(0x02),  // KEY_1
        0x13: Key(0x03),  // KEY_2
        0x14: Key(0x04),  // KEY_3
        0x15: Key(0x05),  // KEY_4
        0x16: Key(0x07),  // KEY_6
        0x17: Key(0x06),  // KEY_5
        0x18: Key(0x0D),  // OEM_PLUS
        0x19: Key(0x0A),  // KEY_9
        0x1A: Key(0x08),  // KEY_7
        0x1B: Key(0x0C),  // OEM_MINUS
        0x1C: Key(0x09),  // KEY_8
        0x1D: Key(0x0B),  // KEY_0
        0x1E: Key(0x1B),  // OEM_6
        0x1F: Key(0x18),  // KEY_O
        0x20: Key(0x16),  // KEY_U
        0x21: Key(0x1A),  // OEM_4
        0x22: Key(0x17),  // KEY_I
        0x23: Key(0x19),  // KEY_P
        0x24: Key(0x1C),  // RETURN
        0x25: Key(0x26),  // KEY_L
        0x26: Key(0x24),  // KEY_J
        0x27: Key(0x28),  // OEM_7
        0x28: Key(0x25),  // KEY_K
        0x29: Key(0x27),  // OEM_1
        0x2A: Key(0x2B),  // OEM_5
        0x2B: Key(0x33),  // OEM_COMMA
        0x2C: Key(0x35),  // OEM_2
        0x2D: Key(0x31),  // KEY_N
        0x2E: Key(0x32),  // KEY_M
        0x2F: Key(0x34),  // OEM_PERIOD
        0x30: Key(0x0F),  // TAB
        0x31: Key(0x39),  // SPACE
        0x32: Key(0x29),  // OEM_3
        0x33: Key(0x0E),  // BACK
        0x35: Key(0x01),  // ESCAPE
        0x38: Key(0x2A),  // LSHIFT
        0x39: Key(0x3A),  // CAPITAL
        0x3A: Key(0x38),  // LMENU
        0x3B: Key(0x1D),  // LCONTROL
        0x3C: Key(0x36),  // RSHIFT
        0x3D: Key(0x38, extended: true),  // right Option
        0x3E: Key(0x1D, extended: true),  // right Control
        0x40: Key(0x68),  // F17
        0x41: Key(0x53),  // DECIMAL
        0x43: Key(0x37),  // MULTIPLY
        0x45: Key(0x4E),  // ADD
        0x47: Key(0x45),  // NUMLOCK
        0x4B: Key(0x35, extended: true),  // keypad /
        0x4C: Key(0x1C, extended: true),  // keypad Enter
        0x4E: Key(0x4A),  // SUBTRACT
        0x4F: Key(0x69),  // F18
        0x50: Key(0x6A),  // F19
        0x52: Key(0x52),  // NUMPAD0
        0x53: Key(0x4F),  // NUMPAD1
        0x54: Key(0x50),  // NUMPAD2
        0x55: Key(0x51),  // NUMPAD3
        0x56: Key(0x4B),  // NUMPAD4
        0x57: Key(0x4C),  // NUMPAD5
        0x58: Key(0x4D),  // NUMPAD6
        0x59: Key(0x47),  // NUMPAD7
        0x5A: Key(0x6B),  // F20
        0x5B: Key(0x48),  // NUMPAD8
        0x5C: Key(0x49),  // NUMPAD9
        0x5F: Key(0x53),  // DECIMAL
        0x60: Key(0x3F),  // F5
        0x61: Key(0x40),  // F6
        0x62: Key(0x41),  // F7
        0x63: Key(0x3D),  // F3
        0x64: Key(0x42),  // F8
        0x65: Key(0x43),  // F9
        0x67: Key(0x57),  // F11
        0x69: Key(0x37, extended: true),  // F13 → Print Screen
        0x6A: Key(0x67),  // F16
        0x6B: Key(0x65),  // F14
        0x6D: Key(0x44),  // F10
        0x6E: Key(0x5D, extended: true),  // APPS (context menu)
        0x6F: Key(0x58),  // F12
        0x71: Key(0x46, extended: true),  // F15 → Pause
        0x72: Key(0x52, extended: true),  // Help → Insert
        0x73: Key(0x47, extended: true),  // Home
        0x74: Key(0x49, extended: true),  // Page Up
        0x75: Key(0x53, extended: true),  // Forward Delete
        0x76: Key(0x3E),  // F4
        0x77: Key(0x4F, extended: true),  // End
        0x78: Key(0x3C),  // F2
        0x79: Key(0x51, extended: true),  // Page Down
        0x7A: Key(0x3B),  // F1
        0x7B: Key(0x4B, extended: true),  // Left
        0x7C: Key(0x4D, extended: true),  // Right
        0x7D: Key(0x50, extended: true),  // Down
        0x7E: Key(0x48, extended: true),  // Up
    ]

    // MARK: - Modifiers

    /// A modifier's own side, from the device-dependent bits of an event's
    /// flags (IOKit's NX_DEVICE*KEYMASK): left and right Shift are one flag
    /// otherwise, and a release of one would read as both.
    private static let sideMasks: [UInt16: UInt] = [
        UInt16(kVK_Shift): 0x0002, UInt16(kVK_RightShift): 0x0004,
        UInt16(kVK_Control): 0x0001, UInt16(kVK_RightControl): 0x2000,
        UInt16(kVK_Option): 0x0020, UInt16(kVK_RightOption): 0x0040,
    ]

    /// For a `flagsChanged` event: whether the modifier that changed is now
    /// down. `nil` for one not sent at all (Command, Fn) and for Caps Lock,
    /// which toggles.
    static func modifierIsDown(keyCode: UInt16, flags: UInt) -> Bool? {
        sideMasks[keyCode].map { flags & $0 != 0 }
    }

    /// The layout a session starts with: US English, always. Keys go by
    /// position and the server's own layout decides what they type, so the
    /// language is switched there (Win+Space). Sending the Mac's current
    /// layout, as mstsc does, broke xrdp: with Russian it typed no letters
    /// at all, only the keys that are not letters.
    static let sessionLayoutID = 0x409
}
