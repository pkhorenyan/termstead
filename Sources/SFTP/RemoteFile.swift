import Foundation

/// One entry of a remote directory, as `sftp`'s `ls -la` describes it.
struct RemoteFile: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case directory, file
        /// `ls` does not say where a link points; the browser finds out by
        /// trying to enter it.
        case symlink
    }

    var name: String
    /// The absolute remote path.
    var path: String
    var kind: Kind
    var size: Int64
    var modified: Date?
    /// `rwxr-xr-x`, without the type letter.
    var permissions: String
    var owner: String
    var group: String

    var id: String { path }
    var isHidden: Bool { name.hasPrefix(".") }
}

enum RemotePath {
    static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    static func parent(of path: String) -> String {
        guard path != "/" else { return "/" }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let slash = trimmed.lastIndex(of: "/") else { return "/" }
        let parent = String(trimmed[..<slash])
        return parent.isEmpty ? "/" : parent
    }

    static func name(of path: String) -> String {
        let trimmed = path.hasSuffix("/") && path != "/" ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }
}

/// Reads `sftp`'s `ls -la` output.
///
/// The lines look like `ls -l`, except that the link count is often `?`:
///
///     drwxr-xr-x    ? deploy   wheel        224 Sep 29 08:21 sub dir
///     -rw-r--r--    1 deploy   wheel    1048576 Mar  2  2024 old.tar
///
/// Eight fields, then the name — which may contain spaces, so it is the rest
/// of the line after the eighth field rather than a ninth field.
enum SFTPListing {
    static func parse(_ output: String, in directory: String, now: Date = Date()) -> [RemoteFile] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            parseLine(String(line), in: directory, now: now)
        }
    }

    static func parseLine(_ line: String, in directory: String, now: Date = Date()) -> RemoteFile? {
        // `sftp -b` echoes each command it runs as `sftp> …`.
        guard let first = line.first, "dl-cbps".contains(first) else { return nil }
        var fields: [Substring] = []
        var rest = Substring(line)
        for _ in 0..<8 {
            rest = rest.drop { $0 == " " }
            guard let end = rest.firstIndex(of: " ") else { return nil }
            fields.append(rest[..<end])
            rest = rest[end...]
        }
        // Exactly one space separates the date from the name; any more belong to it.
        guard rest.first == " " else { return nil }
        let name = unescape(String(rest.dropFirst()))
        guard !name.isEmpty, name != ".", name != "..", fields[0].count >= 10 else { return nil }

        let type = fields[0].first
        let kind: RemoteFile.Kind = type == "d" ? .directory : type == "l" ? .symlink : .file
        return RemoteFile(name: name,
                          path: RemotePath.join(directory, name),
                          kind: kind,
                          size: Int64(fields[4]) ?? 0,
                          modified: date(month: fields[5], day: fields[6], timeOrYear: fields[7], now: now),
                          permissions: String(fields[0].dropFirst()),
                          owner: String(fields[2]),
                          group: String(fields[3]))
    }

    /// sftp prints names through `strvis`: outside a UTF-8 locale every byte
    /// beyond ASCII is `\ooo`, and a backslash is always `\\`. The client sets
    /// a UTF-8 locale, so this is the fallback — and it keeps a name with a
    /// backslash in it intact.
    static func unescape(_ name: String) -> String {
        guard name.contains("\\") else { return name }
        var bytes: [UInt8] = []
        let utf8 = Array(name.utf8)
        var index = 0
        while index < utf8.count {
            let byte = utf8[index]
            if byte == UInt8(ascii: "\\"), index + 1 < utf8.count {
                let next = utf8[index + 1]
                if next == UInt8(ascii: "\\") {
                    bytes.append(next)
                    index += 2
                    continue
                }
                if index + 3 < utf8.count,
                   let value = UInt8(String(decoding: utf8[(index + 1)...(index + 3)], as: UTF8.self), radix: 8) {
                    bytes.append(value)
                    index += 4
                    continue
                }
            }
            bytes.append(byte)
            index += 1
        }
        return String(bytes: bytes, encoding: .utf8) ?? name
    }

    /// `Sep 29 08:21` for the last six months, `Mar  2  2024` for older.
    private static func date(month: Substring, day: Substring, timeOrYear: Substring, now: Date) -> Date? {
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        guard let monthIndex = months.firstIndex(of: month.lowercased()), let day = Int(day) else { return nil }
        let calendar = Calendar.current
        var parts = DateComponents(month: monthIndex + 1, day: day)
        if timeOrYear.contains(":") {
            let clock = timeOrYear.split(separator: ":").compactMap { Int($0) }
            guard clock.count == 2 else { return nil }
            parts.hour = clock[0]
            parts.minute = clock[1]
            parts.year = calendar.component(.year, from: now)
            // Without a year it is within the last six months: a date ahead
            // of today belongs to last year.
            if let candidate = calendar.date(from: parts), candidate > now.addingTimeInterval(86_400) {
                parts.year! -= 1
            }
        } else {
            guard let year = Int(timeOrYear) else { return nil }
            parts.year = year
        }
        return calendar.date(from: parts)
    }
}
