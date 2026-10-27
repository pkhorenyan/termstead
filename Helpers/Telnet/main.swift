import Darwin
import Foundation

// termstead-telnet host [port]
//
// A Telnet client for a Termstead tab: macOS has had no `telnet` since High
// Sierra. It runs in the tab's terminal as ssh does, so the tab's log,
// snippets, broadcast input and Return-to-reconnect work unchanged.
// Exit codes: 0 when the server closed the connection, 1 when it could not
// be reached, 255 when the connection was lost.

setvbuf(stdout, nil, _IONBF, 0)
let arguments = CommandLine.arguments
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

let socketFD: Int32
switch open(host, port) {
case .success(let fd):
    socketFD = fd
    say("Connected to \(host):\(port). Telnet is not encrypted.")
case .failure(let failure):
    say("Could not connect to \(host):\(port): \(failure.reason).")
    exit(1)
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
        if count == 0 { say("Connection closed by \(host)."); break }
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
exit(code)
