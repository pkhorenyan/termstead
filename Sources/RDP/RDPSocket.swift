import Foundation

/// Opens the connection a remote desktop runs over. The engine has no
/// network of its own (see `RDPService`): it is handed this socket.
enum RDPSocket {
    enum Failure: Error, CustomStringConvertible, Equatable {
        case resolve(String)
        case connect(String)
        case timedOut

        var description: String {
            switch self {
            case .resolve(let problem): "The address could not be resolved: \(problem)."
            case .connect(let problem): "Could not connect: \(problem)."
            case .timedOut: "Could not connect: no answer."
            }
        }
    }

    /// TCP to `host:port`, trying each address the name resolves to, each for
    /// up to `timeout`. Off the main thread: resolving and connecting block.
    static func connect(host: String, port: Int, timeout: TimeInterval = 10) async throws -> FileHandle {
        try await Task.detached {
            try openTCP(host: host, port: port, timeout: timeout)
        }.value
    }

    /// An ssh tunnel's end, a Unix socket in the connection's private folder.
    static func connect(unixPath path: String) throws -> FileHandle {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.connect(String(cString: strerror(errno))) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw Failure.connect("the socket path is too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let problem = String(cString: strerror(errno))
            close(fd)
            throw Failure.connect(problem)
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private static func openTCP(host: String, port: Int, timeout: TimeInterval) throws -> FileHandle {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var found: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &found)
        guard status == 0, let first = found else {
            throw Failure.resolve(String(cString: gai_strerror(status)))
        }
        defer { freeaddrinfo(first) }

        var lastFailure = Failure.timedOut
        var next: UnsafeMutablePointer<addrinfo>? = first
        while let candidate = next {
            next = candidate.pointee.ai_next
            let info = candidate.pointee
            do {
                let fd = try open(family: info.ai_family, address: info.ai_addr, length: info.ai_addrlen,
                                  timeout: timeout)
                return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            } catch let failure as Failure {
                lastFailure = failure
            }
        }
        throw lastFailure
    }

    /// A non-blocking connect, waited on with `poll`, so an address that
    /// never answers costs `timeout` rather than the system's minute or so.
    private static func open(family: Int32, address: UnsafeMutablePointer<sockaddr>?, length: socklen_t,
                             timeout: TimeInterval) throws -> Int32 {
        let fd = socket(family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw Failure.connect(String(cString: strerror(errno))) }
        var keep = false
        defer { if !keep { close(fd) } }

        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        if Darwin.connect(fd, address, length) != 0 {
            guard errno == EINPROGRESS else { throw Failure.connect(String(cString: strerror(errno))) }
            var waiting = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&waiting, 1, Int32(timeout * 1000))
            guard ready > 0 else { throw Failure.timedOut }
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size)
            guard error == 0 else { throw Failure.connect(String(cString: strerror(error))) }
        }
        _ = fcntl(fd, F_SETFL, flags)
        // Small writes — a key, a mouse move — go out at once.
        var on: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &on, socklen_t(MemoryLayout<Int32>.size))
        keep = true
        return fd
    }
}
