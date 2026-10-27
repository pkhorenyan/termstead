import Foundation
import Testing
@testable import Termstead

/// A tab's output as the log keeps it: plain lines.
struct SessionLogTests {
    private func lines(_ pieces: String...) -> [String] {
        var filter = LogLineFilter()
        var out: [String] = []
        for piece in pieces { out += filter.feed(Array(piece.utf8)) }
        if let rest = filter.flush() { out.append(rest) }
        return out
    }

    @Test func colorsAndTitlesAreDropped() {
        #expect(lines("\u{1b}]0;user@host: ~\u{07}\u{1b}[01;32muser@host\u{1b}[00m:~$ ls\r\n",
                      "\u{1b}[0m\u{1b}[01;34mdocs\u{1b}[0m  notes.txt\r\n")
                == ["user@host:~$ ls", "docs  notes.txt"])
    }

    /// A progress bar is redrawn with a lone carriage return: its last state.
    @Test func aProgressBarKeepsItsLastState() {
        #expect(lines("10%\r", "50%\r", "100% done\r\n") == ["100% done"])
    }

    /// Typed and rubbed out, as readline echoes it.
    @Test func backspaceRemovesACharacter() {
        #expect(lines("lsx\u{08} \u{08}\r\n") == ["ls"])
        #expect(lines("кот\u{08}\r\n") == ["ко"])
    }

    @Test func piecesSplitAnywhereComeOutWhole() {
        let text = "\u{1b}[31mпривет\u{1b}[0m\r\nok\r\n"
        let bytes = Array(text.utf8)
        for cut in 1..<bytes.count {
            var filter = LogLineFilter()
            let out = filter.feed(bytes[..<cut]) + filter.feed(bytes[cut...])
            #expect(out == ["привет", "ok"], "cut at \(cut)")
        }
    }

    /// vim's screens are not lines; the command that opened it is.
    @Test func aFullScreenProgramIsLeftOut() {
        #expect(lines("$ vim notes\r\n\u{1b}[?1049h\u{1b}[H\u{1b}[2Jsome screen\r\n~\r\n",
                      "\u{1b}[?1049l$ echo back\r\n")
                == ["$ vim notes", "$ echo back"])
        // The command line cut by the switch itself, before its own newline.
        #expect(lines("$ htop\u{1b}[?1049hscreen\r\n\u{1b}[?1049l$ \r\n") == ["$ htop", "$"])
    }

    @Test func aFileIsWrittenWithTimes() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sb-logs-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = try SessionLog(folder: folder, title: "web/01: prod", address: "deploy@web")
        #expect(log.url.lastPathComponent.hasPrefix("web-01- prod "))
        log.append(Array("hello\r\nwor".utf8))
        log.append(Array("ld\r\n".utf8))
        log.note("Connection closed")
        log.close()
        log.drain()
        let text = try String(contentsOf: log.url, encoding: .utf8)
        let body = text.split(separator: "\n").map(String.init)
        #expect(body.first?.hasPrefix("Termstead log — web/01: prod (deploy@web)") == true)
        #expect(body.dropFirst().contains { $0.range(of: #"^\d\d:\d\d:\d\d  hello$"#, options: .regularExpression) != nil })
        #expect(body.contains { $0.hasSuffix("  world") })
        #expect(body.last?.hasSuffix("— Connection closed —") == true)
    }

    /// Two tabs of one session started in the same second each get a file.
    @Test func twoLogsAtOnceDoNotShareAFile() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sb-logs-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date()
        let first = try SessionLog(folder: folder, title: "web", address: "a", now: now)
        let second = try SessionLog(folder: folder, title: "web", address: "a", now: now)
        #expect(first.url != second.url)
        #expect(second.url.lastPathComponent.hasSuffix(" (2).log"))
        first.append(Array("ONE\r\n".utf8))
        second.append(Array("TWO\r\n".utf8))
        first.close(); second.close()
        first.drain(); second.drain()
        let one = try String(contentsOf: first.url, encoding: .utf8)
        #expect(one.contains("ONE") && !one.contains("TWO"))
        let mode = try FileManager.default.attributesOfItem(atPath: first.url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func aSessionWithoutTheKeyDoesNotLog() throws {
        let json = #"{"id":"a","user":"u","host":"h","port":22,"icon":"server","auth":"key","keyPath":"","jumps":[]}"#
        let session = try JSONDecoder().decode(Session.self, from: Data(json.utf8))
        #expect(!session.logs)
        var on = session
        on.logs = true
        let again = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(on))
        #expect(again.logs)
    }
}
