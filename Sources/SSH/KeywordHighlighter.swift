import Foundation
import SwiftTerm

/// Client-side keyword highlighting, as MobaXterm offers: words such as
/// "error" or "warning", addresses and URLs coloured in whatever the server
/// sends, without the server knowing.
///
/// It recolours cells already in the terminal buffer rather than rewriting the
/// byte stream, which would risk splitting escape sequences. Only text the
/// server left in the default colour is touched — anything it coloured itself
/// keeps its colour — and full-screen programs on the alternate screen (vim,
/// htop, mc) are left alone entirely.
enum KeywordHighlighter {
    enum Mode: String, CaseIterable, Identifiable, Sendable {
        case off, standard, network
        var id: String { rawValue }
        var label: String {
            switch self {
            case .off: "Off"
            case .standard: "Standard"
            case .network: "+ Network"
            }
        }
    }

    /// One pattern and the ANSI palette colour it gets, so matches follow the
    /// theme like everything else the terminal draws.
    struct Rule: @unchecked Sendable {
        let regex: NSRegularExpression
        let color: UInt8
    }

    // ANSI palette indices.
    static let red: UInt8 = 1, green: UInt8 = 2, yellow: UInt8 = 3, blue: UInt8 = 4, magenta: UInt8 = 5, cyan: UInt8 = 6

    private static func rule(_ pattern: String, _ color: UInt8) -> Rule {
        // The patterns are constants; a typo is a programming error.
        Rule(regex: try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive]), color: color)
    }

    static let standard: [Rule] = [
        rule(#"\b(?:https?|ssh|sftp|ftp)://[^\s"'<>]+"#, blue),
        rule(#"\b(?:\d{1,3}\.){3}\d{1,3}(?:/\d{1,2})?(?::\d{1,5})?\b"#, cyan),
        rule(#"\b(?:errors?|fail(?:ed|ure|s)?|fatal|denied|refused|unreachable|critical|panic|exception|timed out|timeout|invalid|not found)\b"#, red),
        rule(#"\b(?:warn(?:ing|ings)?|deprecated|retry(?:ing)?)\b"#, yellow),
        rule(#"\b(?:ok|success(?:ful(?:ly)?)?|succeeded|passed|done|active|running|enabled|connected)\b"#, green),
    ]

    /// Network gear output, Cisco and the like, on top of the standard set.
    static let network: [Rule] = standard + [
        rule(#"\b(?:GigabitEthernet|FastEthernet|TenGigabitEthernet|TenGigE|Ethernet|Eth|Gi|Fa|Te|Vlan|Loopback|Port-channel|Tunnel|Serial)\d+(?:[/.:]\d+)*\b"#, magenta),
        rule(#"\badministratively down\b|\b(?:down|err-disabled|notconnect)\b"#, red),
        rule(#"\b(?:up|connected|forwarding)\b"#, green),
        rule(#"\b(?:[0-9a-f]{4}\.){2}[0-9a-f]{4}\b|\b(?:[0-9a-f]{2}:){5}[0-9a-f]{2}\b"#, cyan),
    ]

    static func rules(for mode: Mode) -> [Rule] {
        switch mode {
        case .off: []
        case .standard: standard
        case .network: network
        }
    }

    /// Colour runs for one line of text, as character ranges. Earlier rules
    /// win where matches overlap, so a URL containing "error" stays one URL.
    static func runs(in text: String, rules: [Rule]) -> [(range: Range<Int>, color: UInt8)] {
        runs(in: text as NSString, rules: rules)
    }

    static func runs(in ns: NSString, rules: [Rule]) -> [(range: Range<Int>, color: UInt8)] {
        // Bridged once: handing each regex the Swift string made every rule
        // convert it to UTF-16 again.
        let text = ns as String
        let whole = NSRange(location: 0, length: ns.length)
        var taken = IndexSet()
        var out: [(range: Range<Int>, color: UInt8)] = []
        for rule in rules {
            for match in rule.regex.matches(in: text, range: whole) {
                let range = match.range.location..<(match.range.location + match.range.length)
                guard !range.isEmpty, !taken.intersects(integersIn: range) else { continue }
                taken.insert(integersIn: range)
                out.append((range, rule.color))
            }
        }
        return out.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }
}

/// Applies the rules to what a terminal shows.
@MainActor
final class HighlightPainter {
    /// SwiftTerm keeps `Attribute`'s initialiser internal, so a coloured
    /// attribute is obtained the way the terminal itself makes one: by feeding
    /// an SGR sequence to a private, never-displayed terminal and reading the
    /// cell back. Cached per colour and original attribute.
    private let scratch = Terminal(delegate: ScratchDelegate(), options: TerminalOptions(cols: 10, rows: 2))
    private var cache: [Key: Attribute] = [:]

    private struct Key: Hashable {
        let color: UInt8
        let original: Attribute
    }

    /// What a row held when it was last scanned, and which cells it
    /// coloured. SwiftTerm's rows are objects that move up the screen as it
    /// scrolls, so while output streams most rows are ones already scanned:
    /// the same text, its colours still in place. Those skip the regexes.
    /// Keyed by the row object, and only for the rows on screen.
    private struct Scanned {
        let text: [UInt16]
        let colored: [Int]
    }
    private var scanned: [ObjectIdentifier: Scanned] = [:]
    /// Reused for every row, so a pass does not allocate per cell.
    private var units: [UInt16] = []
    private var cellOf: [Int] = []

    func forget() { scanned = [:] }

    /// Recolours matches in the visible rows. Returns the rows it changed, so
    /// only those are redrawn.
    @discardableResult
    func paint(_ terminal: Terminal, rules: [KeywordHighlighter.Rule]) -> ClosedRange<Int>? {
        guard !rules.isEmpty, !terminal.isCurrentBufferAlternate else { return nil }
        var changed: ClosedRange<Int>?
        var seen: [ObjectIdentifier: Scanned] = [:]
        seen.reserveCapacity(terminal.rows)
        for row in 0..<terminal.rows {
            guard let line = terminal.getLine(row: row) else { continue }
            let id = ObjectIdentifier(line)
            readText(of: line)

            // Unchanged since it was scanned, and nothing reset our colours
            // (a program rewriting the same text in the default colour would).
            if let previous = scanned[id], previous.text == units,
               previous.colored.allSatisfy({ $0 < line.count && line[$0].attribute.fg != .defaultColor }) {
                seen[id] = previous
                continue
            }

            var colored: [Int] = []
            if units.contains(where: Self.isWordUnit) {
                let ns = NSString(characters: units, length: units.count)
                for run in KeywordHighlighter.runs(in: ns, rules: rules) {
                    for offset in run.range where offset < cellOf.count {
                        let column = cellOf[offset]
                        var cell = line[column]
                        guard cell.attribute.fg == .defaultColor else {
                            colored.append(column)
                            continue
                        }
                        cell.attribute = attribute(color: run.color, like: cell.attribute)
                        line[column] = cell
                        colored.append(column)
                        changed = changed.map { min($0.lowerBound, row)...max($0.upperBound, row) } ?? row...row
                    }
                }
            }
            seen[id] = Scanned(text: units, colored: colored)
        }
        // Rows scrolled off, or rewritten, are forgotten.
        scanned = seen
        return changed
    }

    /// The row as UTF-16 into `units`, and the cell each unit came from into
    /// `cellOf`. Stops at the last non-blank cell; a wide character's second
    /// cell has no text of its own; an empty cell reads as a space so word
    /// boundaries hold.
    private func readText(of line: BufferLine) {
        units.removeAll(keepingCapacity: true)
        cellOf.removeAll(keepingCapacity: true)
        let length = min(line.getTrimmedLength(), line.count)
        for column in 0..<length {
            let cell = line[column]
            if cell.width == 0 { continue }
            let character = cell.getCharacter()
            if character == "\u{0}" {
                units.append(0x20)
                cellOf.append(column)
                continue
            }
            for unit in character.utf16 {
                units.append(unit)
                cellOf.append(column)
            }
        }
    }

    /// Something a rule could match: a letter or digit. Anything beyond
    /// ASCII counts, rather than being classified per unit.
    private static func isWordUnit(_ unit: UInt16) -> Bool {
        (unit >= 0x30 && unit <= 0x39) || (unit >= 0x41 && unit <= 0x5A)
            || (unit >= 0x61 && unit <= 0x7A) || unit >= 0x80
    }

    func attribute(color: UInt8, like original: Attribute) -> Attribute {
        let key = Key(color: color, original: original)
        if let cached = cache[key] { return cached }
        var codes = ["0"]
        let style = original.style
        if style.contains(.bold) { codes.append("1") }
        if style.contains(.dim) { codes.append("2") }
        if style.contains(.italic) { codes.append("3") }
        if style.contains(.underline) { codes.append("4") }
        if style.contains(.blink) { codes.append("5") }
        if style.contains(.inverse) { codes.append("7") }
        if style.contains(.invisible) { codes.append("8") }
        if style.contains(.crossedOut) { codes.append("9") }
        codes.append(color < 8 ? "\(30 + Int(color))" : "\(90 + Int(color) - 8)")
        switch original.bg {
        case .ansi256(let code):
            codes.append(code < 8 ? "\(40 + Int(code))" : code < 16 ? "\(100 + Int(code) - 8)" : "48;5;\(code)")
        case .trueColor(let r, let g, let b):
            codes.append("48;2;\(r);\(g);\(b)")
        case .defaultColor, .defaultInvertedColor:
            break
        }
        scratch.feed(text: "\u{1b}[0m\u{1b}[H\u{1b}[\(codes.joined(separator: ";"))mX")
        let made = scratch.getLine(row: 0)?[0].attribute ?? original
        cache[key] = made
        return made
    }

    private final class ScratchDelegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }
}
