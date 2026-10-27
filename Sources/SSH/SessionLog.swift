import Foundation

/// Turns a terminal's output into the plain lines a log keeps: no colors,
/// no cursor movement, no window titles, and nothing a full-screen program
/// (vim, htop, less) draws on the alternate screen. A progress bar redrawn
/// with a lone carriage return keeps only its last state. Fed in pieces as
/// the output arrives; a sequence or a character split between two pieces
/// comes out whole.
struct LogLineFilter {
    private enum State {
        case text
        case escape
        /// `ESC [`: parameters up to a final byte.
        case control
        /// OSC, DCS and the like: up to BEL or `ESC \`.
        case string
        case stringEscape
        /// `ESC (` and its kin take one more byte.
        case skipOne
    }

    private var state = State.text
    private var line: [UInt8] = []
    private var parameters: [UInt8] = []
    private var carriageReturn = false
    /// A full-screen program is up; its screens are not lines.
    private(set) var onAlternateScreen = false

    /// The lines completed by `bytes`.
    mutating func feed(_ bytes: some Sequence<UInt8>) -> [String] {
        var lines: [String] = []
        for byte in bytes {
            if let completed = take(byte) { lines.append(completed) }
        }
        return lines
    }

    /// What is left of an unfinished line, at the end of the log.
    mutating func flush() -> String? {
        defer { line = [] }
        let text = Self.text(line)
        return text.isEmpty ? nil : text
    }

    private mutating func take(_ byte: UInt8) -> String? {
        switch state {
        case .text:
            return text(byte)
        case .escape:
            switch byte {
            case UInt8(ascii: "["):
                parameters = []
                state = .control
            case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"), UInt8(ascii: "_"):
                state = .string
            case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "*"), UInt8(ascii: "+"),
                 UInt8(ascii: "#"), UInt8(ascii: "%"):
                state = .skipOne
            default:
                state = .text
            }
        case .control:
            if (0x40...0x7e).contains(byte) {
                state = .text
                return controlEnded(final: byte)
            } else {
                parameters.append(byte)
            }
        case .string:
            if byte == 0x07 { state = .text } else if byte == 0x1b { state = .stringEscape }
        case .stringEscape:
            state = byte == UInt8(ascii: "\\") ? .text : .string
        case .skipOne:
            state = .text
        }
        return nil
    }

    private mutating func text(_ byte: UInt8) -> String? {
        if carriageReturn {
            carriageReturn = false
            if byte == 0x0a { return endLine() }
            // Back to the start of the line: what follows writes over it.
            if !onAlternateScreen { line = [] }
        }
        switch byte {
        case 0x1b:
            state = .escape
        case 0x0d:
            carriageReturn = true
        case 0x0a:
            return endLine()
        case 0x08:
            removeLastCharacter()
        case 0x09:
            append(byte)
        case 0..<0x20, 0x7f:
            break
        default:
            append(byte)
        }
        return nil
    }

    private mutating func append(_ byte: UInt8) {
        guard !onAlternateScreen else { return }
        line.append(byte)
    }

    private mutating func endLine() -> String? {
        guard !onAlternateScreen else { return nil }
        defer { line = [] }
        return Self.text(line)
    }

    /// Leading bytes of a UTF-8 character are never `10xxxxxx`.
    private mutating func removeLastCharacter() {
        while let last = line.popLast(), last & 0xc0 == 0x80 {}
    }

    /// `ESC [ ? 1049 h` and its older forms switch to the alternate screen,
    /// `… l` back. Entering it ends the line it was on: the command that
    /// opened it, which the log should still show.
    private mutating func controlEnded(final: UInt8) -> String? {
        guard final == UInt8(ascii: "h") || final == UInt8(ascii: "l"),
              parameters.first == UInt8(ascii: "?") else { return nil }
        let modes = String(decoding: parameters.dropFirst(), as: UTF8.self).split(separator: ";")
        guard modes.contains(where: { ["1049", "1047", "47"].contains($0) }) else { return nil }
        let entering = final == UInt8(ascii: "h")
        let cut = entering && !onAlternateScreen ? Self.text(line) : ""
        onAlternateScreen = entering
        line = []
        return cut.isEmpty ? nil : cut
    }

    private static func text(_ bytes: [UInt8]) -> String {
        var text = String(decoding: bytes, as: UTF8.self)
        while text.last == " " { text.removeLast() }
        return text
    }
}

/// A tab's output, written to a file as plain text with the time on each
/// line. Lines are written on a queue of its own: a burst of output costs
/// the main thread no disk.
final class SessionLog: @unchecked Sendable {
    let url: URL
    /// Touched only on `queue`.
    private var filter = LogLineFilter()
    private var handle: FileHandle?
    private let queue = DispatchQueue(label: "com.pavelkhorenyan.Termstead.log")
    private let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// Makes the folder if need be and starts a new file in it, named after
    /// the tab and the time.
    init(folder: URL, title: String, address: String, now: Date = Date()) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A file of its own, never one already there: two tabs of a session
        // opened within the same second — Duplicate Tab, tabs reopened at
        // launch — would otherwise truncate each other's log and write into
        // one file. Only the user may read it: a log holds what the server
        // printed, which may well be secret.
        let base = "\(Self.fileName(title)) \(Self.fileDate.string(from: now))"
        var candidate = folder.appendingPathComponent(base + ".log")
        var number = 1
        var descriptor = Darwin.open(candidate.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        while descriptor < 0, errno == EEXIST, number < 100 {
            number += 1
            candidate = folder.appendingPathComponent("\(base) (\(number)).log")
            descriptor = Darwin.open(candidate.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        }
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: candidate.path,
                                                           NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)])
        }
        url = candidate
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let started = DateFormatter.localizedString(from: now, dateStyle: .long, timeStyle: .medium)
        write(["Termstead log — \(title) (\(address)) — \(started)", ""])
    }

    func append(_ bytes: [UInt8]) {
        queue.async { [self] in
            let lines = filter.feed(bytes)
            guard !lines.isEmpty else { return }
            let time = stamp.string(from: Date())
            write(lines.map { "\(time)  \($0)" })
        }
    }

    /// A line of Termstead's own, such as the connection closing.
    func note(_ text: String) {
        queue.async { [self] in
            let time = stamp.string(from: Date())
            write(["\(time)  — \(text) —"])
        }
    }

    func close() {
        queue.async { [self] in
            if let rest = filter.flush() { write(["\(stamp.string(from: Date()))  \(rest)"]) }
            try? handle?.close()
            handle = nil
        }
    }

    /// Blocks until everything handed over so far is written, for tests.
    func drain() { queue.sync {} }

    private func write(_ lines: [String]) {
        guard let handle else { return }
        try? handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    private static let fileDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter
    }()

    /// A session name may hold a `/` or a `:`, which a file name cannot.
    static func fileName(_ title: String) -> String {
        let cleaned = title.map { "/:\\".contains($0) ? "-" : $0 }
        let name = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Terminal" : name
    }
}
