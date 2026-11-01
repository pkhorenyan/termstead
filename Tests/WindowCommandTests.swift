import Foundation
import Testing
@testable import Termstead

/// `CSI … t` comes from whatever the server prints, so none of it may stop
/// the app: a Release build trapped on `CSI 8 ; rows ; cols t`, every tab
/// with it.
@MainActor
struct WindowCommandTests {
    @Test func aProgramAskingToResizeTheWindowIsIgnored() {
        let connection = Connection(sessionID: nil, title: "t", address: "a", keyDescription: "k")
        let view = connection.terminalView
        let terminal = view.getTerminal()
        let size = (terminal.cols, terminal.rows)

        view.feed(text: "\u{1b}[8;30;100t")
        for sequence in ["1", "2", "3;10;10", "4;300;400", "5", "6", "7", "9;0", "9;1", "9;2", "9;3",
                         "10;0", "10;1", "10;2", "14", "14;2", "15", "16", "18", "19", "20", "21",
                         "22;0", "22;1", "22;2", "23;0", "23;1", "23;2", "24"] {
            view.feed(text: "\u{1b}[\(sequence)t")
        }

        // The tab's size is the pane's, whatever a program would like.
        #expect((terminal.cols, terminal.rows) == size)
    }

    /// A settings query (DECRQSS) whose bytes are not ASCII: the line that
    /// logs an unknown request force-unwrapped them.
    @Test func aSettingsQueryOfGarbageIsRefused() {
        let connection = Connection(sessionID: nil, title: "t", address: "a", keyDescription: "k")
        let bytes: [UInt8] = [0x1b, 0x50, 0x24, 0x71, 0xff, 0x1b, 0x5c]
        connection.terminalView.feed(byteArray: bytes[...])
    }
}
