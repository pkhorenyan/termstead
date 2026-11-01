import Darwin
import Foundation

// termstead-telnet host [port]
// termstead-telnet --via socket host port ssh [ssh arguments]
//
// A Telnet client for a Termstead tab: macOS has had no `telnet` since High
// Sierra. It runs in the tab's terminal as ssh does, so the tab's log,
// snippets, broadcast input and Return-to-reconnect work unchanged.
// Exit codes: 0 when the server closed the connection, 1 when it could not
// be reached, 255 when the connection was lost.
//
// With --via it starts ssh first, on the same terminal, so jump hosts ask for
// their passwords and host keys there as in any tab. ssh is its child and
// nothing here reads the terminal until the app has forwarded the Telnet
// server to `socket`, which ssh then answers on from the last hop.

setvbuf(stdout, nil, _IONBF, 0)
// A write to a server that has just closed would end the process with
// SIGPIPE — exit code 141 in the tab — instead of saying so.
signal(SIGPIPE, SIG_IGN)
var arguments = CommandLine.arguments
var tunnelSocket: String?
var sshCommand: [String] = []
if arguments.count >= 6, arguments[1] == "--via" {
    tunnelSocket = arguments[2]
    sshCommand = Array(arguments[5...])
    arguments = [arguments[0], arguments[3], arguments[4]]
}
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: termstead-telnet host [port]\n".utf8))
    exit(2)
}
let host = arguments[1]
let port = arguments.count > 2 ? arguments[2] : "23"

func say(_ text: String) {
    FileHandle.standardError.write(Data("\u{1b}[2m\(text)\u{1b}[0m\r\n".utf8))
}

struct ConnectFailure: Error { var reason: String }

/// Tries each address in turn, giving each ten seconds.
func open(_ host: String, _ port: String) -> Result<Int32, ConnectFailure> {
    var hints = addrinfo()
    hints.ai_socktype = SOCK_STREAM
    hints.ai_family = AF_UNSPEC
    var list: UnsafeMutablePointer<addrinfo>?
    let status = getaddrinfo(host, port, &hints, &list)
    guard status == 0, let first = list else { return .failure(ConnectFailure(reason: String(cString: gai_strerror(status)))) }
    defer { freeaddrinfo(list) }
    var lastError = "no address"
    var entry: UnsafeMutablePointer<addrinfo>? = first
    while let current = entry {
        entry = current.pointee.ai_next
        let fd = socket(current.pointee.ai_family, current.pointee.ai_socktype, current.pointee.ai_protocol)
        guard fd >= 0 else { continue }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var result = Darwin.connect(fd, current.pointee.ai_addr, current.pointee.ai_addrlen)
        if result != 0, errno == EINPROGRESS {
            var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            if poll(&poller, 1, 10_000) == 1 {
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
                result = error == 0 ? 0 : -1
                errno = error
            } else {
                errno = ETIMEDOUT
            }
        }
        if result == 0 {
            _ = fcntl(fd, F_SETFL, flags)
            // A dead link is noticed rather than waited on for ever.
            var on: Int32 = 1, idle: Int32 = 60
            setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &on, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, IPPROTO_TCP, TCP_KEEPALIVE, &idle, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
            return .success(fd)
        }
        lastError = String(cString: strerror(errno))
        close(fd)
    }
    return .failure(ConnectFailure(reason: lastError))
}

/// ssh, with SIGPIPE back at its default: it is ignored here, and an ignored
/// signal stays ignored through exec.
func startSSH(_ command: [String]) -> pid_t? {
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    var defaults = sigset_t()
    sigemptyset(&defaults)
    sigaddset(&defaults, SIGPIPE)
    posix_spawnattr_setsigdefault(&attributes, &defaults)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF))
    var pid: pid_t = 0
    var words: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) } + [nil]
    defer { words.forEach { free($0) } }
    guard posix_spawn(&pid, command[0], nil, &attributes, &words, environ) == 0 else { return nil }
    return pid
}

/// ssh's way out, if it has ended: it has said why on the terminal.
func exitStatus(of ssh: pid_t) -> Int32? {
    var status: Int32 = 0
    guard waitpid(ssh, &status, WNOHANG) == ssh else { return nil }
    return status & 0x7f == 0 ? (status >> 8) & 0xff : 255
}

func connectUnix(_ path: String) -> Int32? {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    if connected == 0 { return fd }
    close(fd)
    return nil
}

/// Waits as long as the logins take: a person may be typing a password. The
/// file can appear a moment before ssh listens on it, so a refusal is tried
/// again.
func waitForTunnel(_ socket: String, ssh: pid_t) -> Int32 {
    while true {
        if let status = exitStatus(of: ssh) { exit(status) }
        if access(socket, F_OK) == 0, let fd = connectUnix(socket) { return fd }
        usleep(50_000)
    }
}

var sshPID: pid_t?
let socketFD: Int32
if let tunnelSocket {
    guard let ssh = startSSH(sshCommand) else {
        say("Could not start ssh.")
        exit(1)
    }
    sshPID = ssh
    socketFD = waitForTunnel(tunnelSocket, ssh: ssh)
    say("Tunnel open to \(host):\(port). Telnet is not encrypted past the last jump host.")
} else {
    switch open(host, port) {
    case .success(let fd):
        socketFD = fd
        say("Connected to \(host):\(port). Telnet is not encrypted.")
    case .failure(let failure):
        say("Could not connect to \(host):\(port): \(failure.reason).")
        exit(1)
    }
}

// The tab's terminal: raw while the server echoes, the line edited here
// (canonical, echoed) until it does — Telnet's default. Signals stay off
// either way: Ctrl-C is for the server.
var original = termios()
let isTerminal = tcgetattr(STDIN_FILENO, &original) == 0
@MainActor func setTerminal(serverEchoes: Bool) {
    guard isTerminal else { return }
    var mode = original
    if serverEchoes {
        cfmakeraw(&mode)
        mode.c_oflag |= tcflag_t(OPOST | ONLCR)
    } else {
        mode.c_lflag |= tcflag_t(ICANON | ECHO)
        mode.c_lflag &= ~tcflag_t(ISIG)
        // Ctrl-D on an empty line would read as the end of input here and
        // end the connection; it is for the server, as Ctrl-C is.
        // 0xff is _POSIX_VDISABLE, a macro Swift does not import.
        withUnsafeMutableBytes(of: &mode.c_cc) { $0[Int(VEOF)] = 0xff }
    }
    tcsetattr(STDIN_FILENO, TCSANOW, &mode)
}

var telnet = TelnetProtocol()
@MainActor func updateSize() {
    var size = winsize()
    if ioctl(STDIN_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 {
        telnet.columns = size.ws_col
        telnet.rows = size.ws_row
    }
}
updateSize()
setTerminal(serverEchoes: false)

// SIGWINCH through a pipe, so the poll loop below sees it.
var wake: [Int32] = [0, 0]
pipe(&wake)
nonisolated(unsafe) var wakeWriter: Int32 = wake[1]
signal(SIGWINCH) { _ in var byte: UInt8 = 1; _ = write(wakeWriter, &byte, 1) }

@MainActor func send(_ bytes: [UInt8]) -> Bool {
    var offset = 0
    while offset < bytes.count {
        let written = bytes[offset...].withUnsafeBufferPointer { write(socketFD, $0.baseAddress, $0.count) }
        if written <= 0 { return false }
        offset += written
    }
    return true
}

var buffer = [UInt8](repeating: 0, count: 16384)
var code: Int32 = 0
var sshEnded = false
loop: while true {
    var fds = [pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0),
               pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0),
               pollfd(fd: wake[0], events: Int16(POLLIN), revents: 0)]
    guard poll(&fds, 3, -1) >= 0 || errno == EINTR else { code = 255; break }
    if fds[2].revents != 0 {
        _ = read(wake[0], &buffer, buffer.count)
        updateSize()
        if !send(telnet.windowSize()) { code = 255; break }
    }
    if fds[1].revents != 0 {
        let count = read(socketFD, &buffer, buffer.count)
        if count == 0 {
            // Through a tunnel the end of it reads the same as the server
            // closing; only ssh having gone tells them apart.
            if let sshPID, exitStatus(of: sshPID) != nil {
                say("Connection to \(host) lost: the tunnel closed.")
                sshEnded = true
                code = 255
            } else {
                say("Connection closed by \(host).")
            }
            break
        }
        if count < 0 { say("Connection to \(host) lost: \(String(cString: strerror(errno)))."); code = 255; break }
        let echoed = telnet.serverEchoes
        let (text, reply) = telnet.receive(buffer[..<count])
        if telnet.serverEchoes != echoed { setTerminal(serverEchoes: telnet.serverEchoes) }
        if !text.isEmpty { _ = text.withUnsafeBufferPointer { write(STDOUT_FILENO, $0.baseAddress, $0.count) } }
        if !reply.isEmpty, !send(reply) { code = 255; break }
    }
    if fds[0].revents != 0 {
        let count = read(STDIN_FILENO, &buffer, buffer.count)
        if count <= 0 { break loop }
        if !send(telnet.encode(buffer[..<count])) {
            say("Connection to \(host) lost.")
            code = 255
            break
        }
    }
}
if isTerminal { tcsetattr(STDIN_FILENO, TCSANOW, &original) }
close(socketFD)
if let sshPID, !sshEnded {
    kill(sshPID, SIGTERM)
    var status: Int32 = 0
    waitpid(sshPID, &status, 0)
}
exit(code)
