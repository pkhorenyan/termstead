import Foundation

// termstead-askpass: the program ssh runs (as SSH_ASKPASS) whenever it needs to
// ask for something — a password, a key's passphrase, a yes/no.
//
// It first asks Termstead, over the socket named in the environment, whether a
// stored secret answers this prompt. If not — nothing stored, a prompt it does
// not recognise, or the stored secret already tried once and refused — it asks
// on the terminal itself, the way ssh would have.
//
// It never reads the Keychain: an ad-hoc-signed helper's access would change
// with every build and turn each connection into a Keychain dialog. The app
// reads its own items without one.

let prompt = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Password: "

func askTermstead() -> String? {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment[AskpassProtocol.socketVariable],
          let token = environment[AskpassProtocol.tokenVariable],
          var address = AskpassProtocol.address(for: path) else { return nil }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    // Long enough for a Keychain access dialog to be answered: with an
    // ad-hoc-signed build, the first read after each rebuild asks for one.
    var timeout = timeval(tv_sec: 60, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0,
          var request = try? JSONEncoder().encode(AskpassProtocol.Request(token: token, prompt: prompt))
    else { return nil }
    request.append(0x0A)
    guard request.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == request.count else { return nil }

    var reply = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while !reply.contains(0x0A) {
        let count = read(fd, &buffer, buffer.count)
        guard count > 0 else { break }
        reply.append(contentsOf: buffer[0..<count])
    }
    let line = reply.prefix { $0 != 0x0A }
    return (try? JSONDecoder().decode(AskpassProtocol.Reply.self, from: line))?.secret
}

/// Asks on the controlling terminal, hiding the input unless it is a plain
/// yes/no. ssh's own stdin and stdout are not the terminal here; /dev/tty is.
func askTerminal() -> String? {
    let tty = open("/dev/tty", O_RDWR)
    guard tty >= 0 else { return nil }
    defer { close(tty) }

    let hide = !AskpassProtocol.isConfirmation(prompt)
    var saved = termios()
    let canHide = hide && tcgetattr(tty, &saved) == 0
    if canHide {
        var quiet = saved
        quiet.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(tty, TCSAFLUSH, &quiet)
    }
    defer { if canHide { tcsetattr(tty, TCSAFLUSH, &saved) } }

    _ = Array(prompt.utf8).withUnsafeBytes { write(tty, $0.baseAddress, $0.count) }
    var line = [UInt8]()
    var byte: UInt8 = 0
    while read(tty, &byte, 1) == 1, byte != 0x0A, byte != 0x0D {
        line.append(byte)
    }
    if canHide { _ = write(tty, "\r\n", 2) }
    return String(decoding: line, as: UTF8.self)
}

guard let answer = askTermstead() ?? askTerminal() else { exit(1) }
FileHandle.standardOutput.write(Data((answer + "\n").utf8))
exit(0)
