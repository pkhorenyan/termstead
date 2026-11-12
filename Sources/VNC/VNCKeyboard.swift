import AppKit

enum VNCKeyboard {
    /// RFB uses X11 keysyms, including Unicode (0x01000000 | scalar).
    static func symbol(keyCode: UInt16, characters: String?) -> UInt32? {
        if let special = special[keyCode] { return special }
        guard let scalar = characters?.unicodeScalars.first, scalar.value >= 0x20,
              scalar.value < 0xf700 || scalar.value > 0xf8ff else { return nil }
        return scalar.value <= 0xff ? scalar.value : 0x0100_0000 | scalar.value
    }
    static let modifiers: [UInt16: UInt32] = [
        56: 0xffe1, 60: 0xffe2, 59: 0xffe3, 62: 0xffe4,
        58: 0xffe9, 61: 0xffea
    ]
    private static let special: [UInt16: UInt32] = [
        36: 0xff0d, 76: 0xff8d, 48: 0xff09, 51: 0xff08, 53: 0xff1b,
        114: 0xff63, 115: 0xff50, 116: 0xff55, 117: 0xffff, 119: 0xff57,
        121: 0xff56, 123: 0xff51, 124: 0xff53, 125: 0xff54, 126: 0xff52,
        122: 0xffbe, 120: 0xffbf, 99: 0xffc0, 118: 0xffc1,
        96: 0xffc2, 97: 0xffc3, 98: 0xffc4, 100: 0xffc5,
        101: 0xffc6, 109: 0xffc7, 103: 0xffc8, 111: 0xffc9,
        105: 0xffca, 107: 0xffcb, 113: 0xffcc, 106: 0xffcd,
        64: 0xffce, 79: 0xffcf, 80: 0xffd0, 90: 0xffd1
    ]
}
