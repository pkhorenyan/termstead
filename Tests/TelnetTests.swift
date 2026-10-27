import Foundation
import Testing
@testable import Termstead

/// Telnet's side channel, as `termstead-telnet` speaks it.
struct TelnetProtocolTests {
    typealias B = TelnetProtocol.Byte
    typealias O = TelnetProtocol.Option

    @Test func textPassesAndCommandsAreTakenOut() {
        var telnet = TelnetProtocol()
        let (text, reply) = telnet.receive([0x68, 0x69, B.iac, 241, B.iac, B.iac, 0x21])
        #expect(text == [0x68, 0x69, 0xff, 0x21])
        #expect(reply.isEmpty)
    }

    /// busybox telnetd's opening: DO ECHO, DO NAWS, WILL ECHO, WILL SGA.
    @Test func theOpeningIsAnsweredOnce() {
        var telnet = TelnetProtocol()
        telnet.columns = 132
        telnet.rows = 40
        let opening: [UInt8] = [B.iac, B.doIt, O.echo, B.iac, B.doIt, O.windowSize,
                                B.iac, B.will, O.echo, B.iac, B.will, O.suppressGoAhead]
        let (text, reply) = telnet.receive(opening)
        #expect(text.isEmpty)
        #expect(reply == [B.iac, B.wont, O.echo,
                          B.iac, B.will, O.windowSize, B.iac, B.sb, O.windowSize, 0, 132, 0, 40, B.iac, B.se,
                          B.iac, B.doIt, O.echo, B.iac, B.doIt, O.suppressGoAhead])
        #expect(telnet.serverEchoes)
        // Asked again, nothing more: no negotiation loop.
        #expect(telnet.receive(opening).reply == [B.iac, B.wont, O.echo])
    }

    @Test func theTerminalTypeIsTold() {
        var telnet = TelnetProtocol()
        _ = telnet.receive([B.iac, B.doIt, O.terminalType])
        let reply = telnet.receive([B.iac, B.sb, O.terminalType, 1, B.iac, B.se]).reply
        #expect(reply == [B.iac, B.sb, O.terminalType, 0] + Array("XTERM-256COLOR".utf8) + [B.iac, B.se])
    }

    @Test func unknownOptionsAreRefused() {
        var telnet = TelnetProtocol()
        #expect(telnet.receive([B.iac, B.doIt, 39]).reply == [B.iac, B.wont, 39])
        #expect(telnet.receive([B.iac, B.will, 0]).reply == [B.iac, B.dont, 0])
    }

    /// A command split between two reads comes out whole.
    @Test func aCommandSplitAcrossReads() {
        var telnet = TelnetProtocol()
        let first = telnet.receive([0x61, B.iac])
        let second = telnet.receive([B.will, O.echo, 0x62])
        #expect(first.text == [0x61] && second.text == [0x62])
        #expect(second.reply == [B.iac, B.doIt, O.echo])
    }

    @Test func returnIsCRLFAnd255IsDoubled() {
        var telnet = TelnetProtocol()
        #expect(telnet.encode(Array("ls\r".utf8)) == Array("ls\r\n".utf8))
        #expect(telnet.encode(Array("a\r\nb\n".utf8)) == Array("a\r\nb\r\n".utf8))
        // CR and LF of one Return in two reads.
        #expect(telnet.encode([0x0d]) == [0x0d, 0x0a])
        #expect(telnet.encode([0x0a]) == [])
        #expect(telnet.encode([0xff]) == [0xff, 0xff])
    }

    @Test func aWindowSizeOf255IsEscaped() {
        var telnet = TelnetProtocol()
        _ = telnet.receive([B.iac, B.doIt, O.windowSize])
        telnet.columns = 255
        telnet.rows = 24
        #expect(telnet.windowSize() == [B.iac, B.sb, O.windowSize, 0, 255, 255, 0, 24, B.iac, B.se])
    }
}

/// A Telnet tab against the lab's busybox telnetd on 127.0.0.1:2323.
@MainActor
@Suite(.serialized, .enabled(if: TelnetLab.isUp, "the lab's Telnet is not up (TestLab/lab.sh up)"))
struct TelnetTabTests {
    private func screen(_ tab: Connection) -> String {
        String(decoding: tab.terminalView.getTerminal().getBufferAsData(), as: UTF8.self)
    }

    private func wait(upTo seconds: Double, until done: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
    }

    @Test func aTelnetTabLogsInOnScreen() async throws {
        let tabs = ConnectionStore()
        defer { tabs.closeAll() }
        tabs.connect(sessionID: "lab-telnet", in: SessionStore.sample())
        let tab = try #require(tabs.active)
        #expect(tab.kind == .telnet)
        #expect(tab.address == "telnet 127.0.0.1:2323")
        await wait(upTo: 10) { screen(tab).contains("login:") }
        tab.terminalView.send(txt: "lab\r")
        await wait(upTo: 10) { screen(tab).contains("Password:") }
        tab.terminalView.send(txt: "lab\r")
        try await Task.sleep(for: .seconds(1))
        let marker = "SB_TELNET_\(6 * 7)"
        tab.terminalView.send(txt: "echo SB_TELNET_$((6*7)); stty size\r")
        // The shell computes it, so the echo of the typed line cannot pass for it.
        await wait(upTo: 10) { screen(tab).contains(marker) }
        #expect(screen(tab).contains(marker), "\(screen(tab))")
        // The window's size reached the server (NAWS).
        let terminal = tab.terminalView.getTerminal()
        #expect(screen(tab).contains("\(terminal.rows) \(terminal.cols)"), "\(screen(tab))")

        tab.terminalView.send(txt: "exit\r")
        await wait(upTo: 10) { !tab.state.isRunning }
        #expect(tab.state == .exited(code: 0))
        #expect(screen(tab).contains("Connection closed by 127.0.0.1"))

        // Return connects again, to the login prompt.
        tab.terminalView.send(txt: "\r")
        await wait(upTo: 10) { screen(tab).components(separatedBy: "login:").count > 2 }
        #expect(tab.state.isRunning)
    }

    @Test func anUnreachableHostIsSaid() async throws {
        let tabs = ConnectionStore()
        defer { tabs.closeAll() }
        let tab = Connection(sessionID: nil, title: "t", address: "", keyDescription: "", kind: .telnet)
        tabs.add(tab)
        tab.startTelnet(host: "127.0.0.1", port: 1)
        await wait(upTo: 10) { !tab.state.isRunning }
        #expect(tab.state == .exited(code: 1))
        #expect(screen(tab).contains("Could not connect to 127.0.0.1:1"))
    }
}

enum TelnetLab {
    static let isUp: Bool = {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(2323).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }()
}
