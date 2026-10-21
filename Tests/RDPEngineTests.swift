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
