import Foundation

/// Telnet's side channel (RFC 854 and the options a terminal needs), kept
/// apart from the socket so it can be tested: what the server sends is split
/// into the text to show and the answers to its questions, and what is typed
/// is turned into what goes on the wire. Compiled into `termstead-telnet` and
/// into the app, for the tests.
struct TelnetProtocol {
    enum Byte {
        static let se: UInt8 = 240, sb: UInt8 = 250
        static let will: UInt8 = 251, wont: UInt8 = 252, doIt: UInt8 = 253, dont: UInt8 = 254
        static let iac: UInt8 = 255
    }

    enum Option {
        static let echo: UInt8 = 1, suppressGoAhead: UInt8 = 3
        static let terminalType: UInt8 = 24, windowSize: UInt8 = 31
    }

    /// The terminal type a server is told: what SwiftTerm emulates.
    var terminalType = "XTERM-256COLOR"
    /// The window, for NAWS; set before a server asks, and on each resize.
    var columns: UInt16 = 80
    var rows: UInt16 = 24

    /// The server echoes what is typed (it said WILL ECHO), so the terminal
    /// must not. Until then the line is edited and echoed here, as Telnet's
    /// default.
    private(set) var serverEchoes = false
    private(set) var sendsWindowSize = false
    /// Options the server asked us to do and we do, and those it does.
    private var ours: Set<UInt8> = []
    private var theirs: Set<UInt8> = []

    private enum State { case data, command, option(UInt8), subnegotiation, subnegotiationCommand }
    private var state = State.data
    private var subnegotiation: [UInt8] = []
    /// A Return typed as CR LF arrives in two pieces at times; the LF is
    /// the same Return and is not sent again.
    private var lastTypedCR = false

    /// Splits what the server sent into the text to show and the answers
    /// to send back.
    mutating func receive(_ bytes: some Sequence<UInt8>) -> (text: [UInt8], reply: [UInt8]) {
        var text: [UInt8] = []
        var reply: [UInt8] = []
        for byte in bytes {
            switch state {
            case .data:
                if byte == Byte.iac { state = .command } else { text.append(byte) }
            case .command:
                switch byte {
                case Byte.iac:
                    text.append(Byte.iac)
                    state = .data
                case Byte.will, Byte.wont, Byte.doIt, Byte.dont:
                    state = .option(byte)
                case Byte.sb:
                    subnegotiation = []
                    state = .subnegotiation
                default:
                    // NOP, Go Ahead, Are You There and the like: nothing to show.
                    state = .data
                }
            case .option(let verb):
                reply += negotiate(verb, byte)
                state = .data
            case .subnegotiation:
                if byte == Byte.iac { state = .subnegotiationCommand } else { subnegotiation.append(byte) }
            case .subnegotiationCommand:
                if byte == Byte.se {
                    reply += subnegotiated(subnegotiation)
                    state = .data
                } else {
                    // IAC IAC inside: a literal 255.
                    if byte == Byte.iac { subnegotiation.append(byte) }
                    state = .subnegotiation
                }
            }
        }
        return (text, reply)
    }

    /// Answers each question once, so two sides that both insist do not
    /// loop (RFC 1143's point).
    private mutating func negotiate(_ verb: UInt8, _ option: UInt8) -> [UInt8] {
        switch verb {
        case Byte.will:
            let wanted = option == Option.echo || option == Option.suppressGoAhead
            if wanted {
                guard theirs.insert(option).inserted else { return [] }
                if option == Option.echo { serverEchoes = true }
                return [Byte.iac, Byte.doIt, option]
            }
            return [Byte.iac, Byte.dont, option]
        case Byte.wont:
            guard theirs.remove(option) != nil else { return [] }
            if option == Option.echo { serverEchoes = false }
            return [Byte.iac, Byte.dont, option]
        case Byte.doIt:
            let offered = [Option.terminalType, Option.windowSize, Option.suppressGoAhead].contains(option)
            guard offered else { return [Byte.iac, Byte.wont, option] }
            guard ours.insert(option).inserted else { return [] }
            var answer = [Byte.iac, Byte.will, option]
            if option == Option.windowSize {
                sendsWindowSize = true
                answer += windowSize()
            }
            return answer
        default: // DONT
            guard ours.remove(option) != nil else { return [] }
            if option == Option.windowSize { sendsWindowSize = false }
            return [Byte.iac, Byte.wont, option]
        }
    }

    /// TTYPE SEND is the only one asked of us.
    private func subnegotiated(_ bytes: [UInt8]) -> [UInt8] {
        guard bytes == [Option.terminalType, 1], ours.contains(Option.terminalType) else { return [] }
        return [Byte.iac, Byte.sb, Option.terminalType, 0] + Array(terminalType.utf8) + [Byte.iac, Byte.se]
    }

    /// NAWS: the window's columns and rows; `[]` until the server asked.
    func windowSize() -> [UInt8] {
        guard sendsWindowSize || ours.contains(Option.windowSize) else { return [] }
        var payload: [UInt8] = []
        for value in [columns, rows] {
            for byte in [UInt8(value >> 8), UInt8(value & 0xff)] {
                payload.append(byte)
                if byte == Byte.iac { payload.append(byte) }
            }
        }
        return [Byte.iac, Byte.sb, Option.windowSize] + payload + [Byte.iac, Byte.se]
    }

    /// What is typed, for the wire: 255 doubled, and Return — CR, LF, or
    /// both — as Telnet's CR LF, as PuTTY sends it.
    mutating func encode(_ typed: some Sequence<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        for byte in typed {
            defer { lastTypedCR = byte == 0x0d }
            switch byte {
            case 0x0d:
                out += [0x0d, 0x0a]
            case 0x0a:
                if !lastTypedCR { out += [0x0d, 0x0a] }
            case Byte.iac:
                out += [Byte.iac, Byte.iac]
            default:
                out.append(byte)
            }
        }
        return out
    }
}
