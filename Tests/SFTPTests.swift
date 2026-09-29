import Foundation
import Testing
@testable import Termstead

struct SFTPListingTests {
    /// What `sftp -b` prints for `cd`, `pwd` and `ls -la`, as captured from macOS's sftp.
    private let output = """
    sftp> cd "/srv/data"
    sftp> pwd
    Remote working directory: /srv/data
    sftp> ls -la
    drwxr-xr-x    ? deploy   wheel         224 Sep 29 08:21 .
    drwxr-xr-x    ? deploy   wheel         416 Sep 29 08:21 ..
    -rw-r--r--    ? deploy   wheel           3 Sep 29 08:20 a file.txt
    lrwxr-xr-x    ? deploy   wheel          10 Sep 29 08:20 link
    -rw-r--r--    1 root     root      1048576 Mar  2  2024 old.tar
    drwx------    2 deploy   staff          64 Sep 29 08:20 .ssh
    -rw-r--r--    ? deploy   wheel           0 Sep 29 08:21   two leading spaces
    """

    @Test func parsesEntriesAndSkipsTheRest() throws {
        let now = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 12)))
        let files = SFTPListing.parse(output, in: "/srv/data", now: now)
        #expect(files.map(\.name) == ["a file.txt", "link", "old.tar", ".ssh", "  two leading spaces"])

        let file = files[0]
        #expect(file.path == "/srv/data/a file.txt")
        #expect(file.kind == .file)
        #expect(file.size == 3)
        #expect(file.permissions == "rw-r--r--")
        #expect(file.owner == "deploy")
        #expect(file.group == "wheel")

        #expect(files[1].kind == .symlink)
        #expect(files[3].kind == .directory)
        #expect(files[3].isHidden)

        let calendar = Calendar.current
        let recent = try #require(file.modified)
        #expect(calendar.dateComponents([.year, .month, .day, .hour, .minute], from: recent)
                == DateComponents(year: 2026, month: 9, day: 29, hour: 8, minute: 20))
        let old = try #require(files[2].modified)
        #expect(calendar.dateComponents([.year, .month, .day], from: old)
                == DateComponents(year: 2024, month: 3, day: 2))
    }

    /// A date shown without a year that would lie in the future is last year's.
    @Test func yearlessDatesAheadOfTodayAreLastYear() throws {
        let now = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 10)))
        let file = try #require(SFTPListing.parseLine("-rw-r--r--    1 a b 1 Dec 30 23:10 f", in: "/", now: now))
        #expect(Calendar.current.component(.year, from: try #require(file.modified)) == 2025)
        #expect(file.path == "/f")
    }

    @Test func escapedNamesAreDecoded() {
        #expect(SFTPListing.unescape(#"\320\272\320\270\321\200.txt"#) == "кир.txt")
        #expect(SFTPListing.unescape(#"back\\slash"#) == #"back\slash"#)
        #expect(SFTPListing.unescape("plain") == "plain")
        let line = #"-rw-r--r--    ? lab      lab            24 Sep 29 08:56 \320\272.txt"#
        #expect(SFTPListing.parseLine(line, in: "/h")?.name == "к.txt")
    }

    @Test func quotingKeepsNamesIntact() {
        #expect(SFTPClient.quote("/a b/c") == "\"/a b/c\"")
        #expect(SFTPClient.quote("q\"uote") == "\"q\\\"uote\"")
        #expect(SFTPClient.quote("back\\slash") == "\"back\\\\slash\"")
        // Literal inside quotes already; escaping them added a backslash.
        #expect(SFTPClient.quote("*[x]?") == "\"*[x]?\"")
        #expect(SFTPClient.shellQuote("it's") == "'it'\\''s'")
    }

    @Test func workingDirectoryAndErrors() throws {
        #expect(try SFTPClient.workingDirectory(in: output) == "/srv/data")
        #expect(throws: SFTPError.self) { try SFTPClient.workingDirectory(in: "nothing") }
        #expect(SFTPClient.error(from: "Control socket connect(/tmp/cm): No such file or directory\n") == .notReady)
        #expect(SFTPClient.error(from: "sftp> ls\nCan't ls: \"/x\" not found\n") == .failed("Can't ls: \"/x\" not found"))
    }

    @Test func remotePaths() {
        #expect(RemotePath.join("/", "etc") == "/etc")
        #expect(RemotePath.join("/etc", "nginx") == "/etc/nginx")
        #expect(RemotePath.parent(of: "/etc/nginx") == "/etc")
        #expect(RemotePath.parent(of: "/etc") == "/")
        #expect(RemotePath.parent(of: "/") == "/")
        #expect(RemotePath.name(of: "/etc/nginx/") == "nginx")
    }

    @MainActor
    @Test func namesAndFreeNames() throws {
        #expect(FileBrowser.validName("  logs ") == "logs")
        #expect(FileBrowser.validName("a/b") == nil)
        #expect(FileBrowser.validName("..") == nil)
        #expect(FileBrowser.validName("") == nil)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sb-free-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(FileBrowser.freeName("app.log", in: folder) == "app.log")
        FileManager.default.createFile(atPath: folder.appendingPathComponent("app.log").path, contents: nil)
        FileManager.default.createFile(atPath: folder.appendingPathComponent("app 2.log").path, contents: nil)
        #expect(FileBrowser.freeName("app.log", in: folder) == "app 3.log")
        FileManager.default.createFile(atPath: folder.appendingPathComponent("Makefile").path, contents: nil)
        #expect(FileBrowser.freeName("Makefile", in: folder) == "Makefile 2")
    }

    @MainActor
    @Test func foldersSortFirstAndHiddenFilesAreOptional() {
        let browser = FileBrowser(connection: nil)
        #expect(browser.visibleFiles.isEmpty)

        func file(_ name: String, _ kind: RemoteFile.Kind = .file) -> RemoteFile {
            RemoteFile(name: name, path: "/h/" + name, kind: kind, size: 1, modified: nil,
                       permissions: "rw-r--r--", owner: "u", group: "g")
        }
        let files = [file("b10.log"), file("logs", .directory), file(".env"), file("b9.log"),
                     file(".cache", .directory), file("a.txt")]
        #expect(FileBrowser.sortedForDisplay(files, showHidden: false).map(\.name)
                == ["logs", "a.txt", "b9.log", "b10.log"])
        #expect(FileBrowser.sortedForDisplay(files, showHidden: true).map(\.name)
                == [".cache", "logs", ".env", "a.txt", "b9.log", "b10.log"])

        // What each render used to pay, twice, before the result was stored.
        let big = (0..<10_000).map { file("file-\($0).log") }.shuffled()
        let start = Date()
        _ = FileBrowser.sortedForDisplay(big, showHidden: false)
        print("SFTP_SORT_MS \(Int(Date().timeIntervalSince(start) * 1000)) for 10,000 files")
    }

    /// The terminal's ssh is the master; the arguments must say so.
    @Test func terminalArgumentsShareTheConnection() throws {
        let plan = try SSHLaunch.plan(forAddress: "deploy@web")
        let arguments = plan.arguments(configPath: "/tmp/c", controlPath: "/tmp/sb-1/cm")
        #expect(arguments == ["-F", "/tmp/c", "-o", "ServerAliveInterval=30",
                              "-o", "ControlMaster=auto", "-o", "ControlPath=/tmp/sb-1/cm",
                              "-o", "ControlPersist=no", plan.target.alias])
    }
}
