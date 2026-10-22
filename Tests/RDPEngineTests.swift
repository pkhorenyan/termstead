import Foundation
import IOSurface
import Testing
@testable import Termstead

enum TestLabRDP {
    /// The lab's xrdp, published on 127.0.0.1:3390.
    static let isUp: Bool = {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(3390).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }()

    static let docker: String? = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker",
                                  "/Applications/Docker.app/Contents/Resources/bin/docker"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    /// A command in the lab's xrdp container, with its exit status and output.
    static func inContainer(_ command: [String]) -> (status: Int32, output: String) {
        guard let docker else { return (-1, "") }
        let compose = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestLab/docker-compose.yml").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: docker)
        process.arguments = ["compose", "-f", compose, "exec", "-T", "rdp"] + command
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (-1, "") }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Certificates trusted in tests go here, never to the user's file.
    static let knownHosts = RDPKnownHosts(url: FileManager.default.temporaryDirectory
        .appendingPathComponent("termstead-rdp-known-hosts-\(UUID().uuidString)"))

    /// Waits for the desktop, answering what the tab asks on the way: the
    /// lab's self-signed certificate is trusted, the login is the lab's.
    @MainActor
    static func waitUntilShowing(_ desktop: RDPDesktop, seconds: Double = 30,
                                 password: String = "lab") async {
        let deadline = Date().addingTimeInterval(seconds)
        while desktop.phase != .showing, Date() < deadline {
            if desktop.certificateQuestion != nil { desktop.answerCertificate(trust: true) }
            if desktop.loginQuestion != nil {
                desktop.answerLogin(RDPLogin(user: "lab", domain: "", password: password), save: false)
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

/// The RDP engine, TermsteadRDP.xpc, against the lab's xrdp: the app opens
/// the socket, the engine logs in and draws into a surface the app can read.
@MainActor
@Suite(.serialized, .enabled(if: TestLabRDP.isUp, "the lab's RDP server is not running (TestLab/lab.sh up)"))
struct RDPEngineTests {
    private func settings(width: Int = 1024, height: Int = 768) -> RDPConnectSettings {
        let settings = RDPConnectSettings()
        settings.host = "rdp"
        settings.user = "lab"
        settings.password = "lab"
        settings.width = width
        settings.height = height
        settings.sound = false
        return settings
    }

    /// Suspends, rather than spins, so the main queue can deliver the
    /// engine's messages meanwhile.
    private func wait(upTo seconds: Double, until done: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Pixels that are not black: an empty surface has none.
    private func drawnPixels(in surface: IOSurface) -> Int {
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let base = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        var count = 0
        for y in stride(from: 0, to: surface.height, by: 8) {
            for x in stride(from: 0, to: surface.width, by: 8) {
                let pixel = base + y * surface.bytesPerRow + x * 4
                if pixel[0] > 16 || pixel[1] > 16 || pixel[2] > 16 { count += 1 }
            }
        }
        return count
    }

    @Test func theEngineDrawsTheDesktop() async throws {
        let engine = RDPEngineConnection()
        var surface: IOSurface?
        var changes = 0
        var certificateAsked = false
        var ended: String?
        engine.onSurface = { made, _, _ in surface = made }
        engine.onChange = { _ in changes += 1 }
        engine.onVerifyCertificate = { pem, host, _, reply in
            certificateAsked = pem.contains("BEGIN CERTIFICATE") && host == "rdp"
            reply(true)
        }
        engine.onDisconnected = { reason, _ in ended = reason }

        engine.connect(settings(), socket: try await RDPSocket.connect(host: "127.0.0.1", port: 3390))
        await wait(upTo: 20) { surface.map { drawnPixels(in: $0) > 100 } ?? false || ended != nil }

        #expect(ended == nil)
        #expect(certificateAsked)
        let drawn = try #require(surface)
        #expect(drawn.width == 1024 && drawn.height == 768)
        #expect(changes > 0)
        #expect(drawnPixels(in: drawn) > 100)
        engine.close()
    }

    /// No to the certificate, and nothing is drawn: the engine ends.
    @Test func aRefusedCertificateEndsTheSession() async throws {
        let engine = RDPEngineConnection()
        var surface: IOSurface?
        var ended: String?
        engine.onSurface = { made, _, _ in surface = made }
        engine.onVerifyCertificate = { _, _, _, reply in reply(false) }
        engine.onDisconnected = { reason, _ in ended = reason }

        engine.connect(settings(), socket: try await RDPSocket.connect(host: "127.0.0.1", port: 3390))
        await wait(upTo: 20) { ended != nil }

        let reason = try #require(ended)
        #expect(!reason.isEmpty)
        #expect(surface == nil)
        engine.close()
    }

    /// Two sessions in the one engine process, each with its own surface.
    @Test func twoDesktopsAtOnce() async throws {
        var surfaces: [IOSurface] = []
        var engines: [RDPEngineConnection] = []
        for _ in 0..<2 {
            let engine = RDPEngineConnection()
            engine.onSurface = { made, _, _ in surfaces.append(made) }
            engine.onVerifyCertificate = { _, _, _, reply in reply(true) }
            engine.connect(settings(width: 800, height: 600),
                           socket: try await RDPSocket.connect(host: "127.0.0.1", port: 3390))
            engines.append(engine)
        }
        await wait(upTo: 20) { surfaces.count == 2 }
        #expect(surfaces.count == 2)
        #expect(surfaces.count < 2 || surfaces[0] !== surfaces[1])
        engines.forEach { $0.close() }
    }
}

/// A pretend server on the other end of a socket pair that answers every
/// connection request by picking legacy RDP security, as a machine in the
/// middle would. FreeRDP tries the other protocols in turn and gives up:
/// nothing but connection requests may reach it — the next thing would have
/// been the MCS request, and after it the password.
@MainActor
@Suite struct RDPLegacySecurityTests {
    @Test func aServerWithoutTLSIsNotLoggedInTo() async throws {
        var pair: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let server = pair[1]
        defer { close(server) }
        let engine = RDPEngineConnection()
        var ended: (reason: String, code: Int)?
        engine.onDisconnected = { ended = ($0, $1) }
        let settings = RDPConnectSettings()
        settings.host = "legacy"
        settings.user = "lab"
        settings.password = "not for this server"
        settings.sound = false
        // Handed over and let go: the engine's end is the only one left, so
        // the server reads to the end once the engine closes it.
        engine.connect(settings, socket: FileHandle(fileDescriptor: pair[0], closeOnDealloc: true))

        let received = await Task.detached { Self.pickLegacySecurity(on: server) }.value
        #expect(!received.isEmpty)
        // An X.224 Connection Request each (TPDU code 0xE0), and no data.
        #expect(received.allSatisfy { $0.count > 5 && $0[0] == 0x03 && $0[5] == 0xE0 })
        let deadline = Date().addingTimeInterval(10)
        while ended == nil, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        #expect(ended?.code == 0x0002_000C)
        engine.close()
    }

    /// Answers each PDU with a Connection Confirm whose RDP_NEG_RSP selects
    /// protocol 0, PROTOCOL_RDP, until the engine closes its end; returns
    /// what it was sent.
    nonisolated private static func pickLegacySecurity(on fd: Int32) -> [[UInt8]] {
        let confirm: [UInt8] = [0x03, 0x00, 0x00, 0x13, 0x0E, 0xD0, 0x00, 0x00, 0x12, 0x34, 0x00,
                                0x02, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00]
        var received: [[UInt8]] = []
        while received.count < 10 {
            let header = read(fd, count: 4, seconds: 10)
            guard header.count == 4 else { break }
            let length = Int(header[2]) << 8 | Int(header[3])
            received.append(header + read(fd, count: max(length - 4, 0), seconds: 10))
            guard write(fd, confirm, confirm.count) == confirm.count else { break }
        }
        return received
    }

    nonisolated private static func read(_ fd: Int32, count: Int, seconds: Double) -> [UInt8] {
        var out: [UInt8] = []
        let deadline = Date().addingTimeInterval(seconds)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while out.count < count {
            let left = Int32(max(deadline.timeIntervalSinceNow, 0) * 1000)
            var waiting = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard left > 0, poll(&waiting, 1, left) > 0 else { break }
            let got = Darwin.read(fd, &buffer, min(buffer.count, count - out.count))
            guard got > 0 else { break }
            out += buffer[0..<got]
        }
        return out
    }
}
