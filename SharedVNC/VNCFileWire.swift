import Foundation

/// Apple's authenticated Screen Sharing file-copy channel (RFB type 0x22).
/// A file's data/resource forks are streamed separately, never an in-memory zip.
struct VNCFileMessage: Sendable {
    static let chunk = 65_536
    static let limit: UInt64 = 100 << 30
    var kind: UInt16
    var session: UInt32
    var argument: UInt32 = 0
    var payload = Data()
    var selector: UInt8 = 0

    var wire: Data {
        var data = Data([0x22, selector])
        data.appendBE(UInt32(12 + payload.count))
        data.appendBE(UInt16(1)); data.appendBE(kind)
        data.appendBE(session); data.appendBE(argument); data.append(payload)
        return data
    }
    init(kind: UInt16, session: UInt32, argument: UInt32 = 0, payload: Data = Data(), selector: UInt8 = 0) {
        self.kind = kind; self.session = session; self.argument = argument
        self.payload = payload; self.selector = selector
    }
    init(wire: Data) throws {
        guard wire.count >= 18, wire.count <= 131_078, wire[0] == 0x22,
              wire.be32(2) == wire.count - 6, wire.be16(6) == 1 else { throw VNCFileError.invalid }
        kind = wire.be16(8); session = wire.be32(10); argument = wire.be32(14)
        payload = Data(wire.dropFirst(18)); selector = wire[1]
    }
    static func start(session: UInt32, path: String, upload: Bool) throws -> Self {
        let path = Data(path.utf8)
        guard !path.isEmpty, path.count <= 1023, !path.contains(0) else { throw VNCFileError.invalid }
        var payload = Data(); payload.appendBE(UInt32(4)) // UTF-8 path; no data compression.
        payload.appendBE(UInt16(path.count)); payload.append(path)
        return Self(kind: upload ? 2 : 1, session: session, payload: payload, selector: 2)
    }
    static func item(session: UInt32, name: String, directory: Bool, level: Int,
                     size: UInt64, resource: UInt64 = 0, mode: UInt16 = 0o644,
                     modified: TimeInterval? = nil) throws -> Self {
        guard safeName(name), (0...64).contains(level), size <= limit, resource <= limit - size else {
            throw VNCFileError.invalid
        }
        let bytes = Data(name.utf8)
        var p = Data(repeating: 0, count: 100)
        p.putBE(resource, at: 30); p.putBE(size, at: 38)
        if let modified {
            let seconds = UInt64(max(0, min(modified + 2_082_844_800, Double(UInt32.max)))) << 16
            for offset in [46, 54, 62, 70] { p.putBE(seconds, at: offset) }
        }
        p.putBE(UInt16(directory ? 0x10 : 0), at: 86)
        p.putBE(UInt16(level), at: 88)
        p.putBE(UInt16(directory ? 0o40700 : 0o100000) | (mode & 0o777), at: 90)
        p.putBE(UInt16(126), at: 94) // Legacy catalog-info byte count.
        p.putBE(UInt16(bytes.count), at: 96)
        p.append(bytes); p.append(0)
        return Self(kind: 101, session: session, argument: directory ? 0x02000000 : 0x01000000, payload: p)
    }
    static func safeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 1023 &&
        !name.contains("/") && !name.contains("\0") && !name.contains(":")
    }
    /// Kind 200 uses a signed 16-bit status plus a 16-bit UTF-8 name length
    /// in place of the usual argument; it is not a kind-5 client stop command.
    func completionName() throws -> String {
        guard kind == 200 else { throw VNCFileError.invalid }
        let status = Int16(bitPattern: UInt16(argument >> 16))
        if status != 0 { throw VNCFileError.remote(Int32(status)) }
        let length = Int(argument & 0xffff)
        guard length <= 1023, payload.count == length + 1, payload.last == 0,
              let name = String(data: payload.prefix(length), encoding: .utf8),
              length == 0 || Self.safeName(name) else { throw VNCFileError.invalid }
        return name
    }
}

enum VNCFileError: Error, CustomStringConvertible {
    case invalid, unsupported, changed, remote(Int32), limit
    var description: String {
        switch self {
        case .invalid: "Cannot copy the files: invalid file data or an unsupported file name."
        case .unsupported: "Only regular files and folders can be copied; symbolic links are not followed."
        case .changed: "A copied file changed or could not be read. Copy it again."
        case .remote(let code): "The remote Mac could not copy the files (error \(code))."
        case .limit: "The copy exceeds the limit of 10,000 items, 64 folder levels, or 100 GB."
        }
    }
}

extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
    mutating func putBE<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { replaceSubrange(offset..<offset + $0.count, with: $0) }
    }
    func be16(_ offset: Int) -> UInt16 { UInt16(self[offset]) << 8 | UInt16(self[offset + 1]) }
    func be32(_ offset: Int) -> UInt32 { (offset..<offset + 4).reduce(0) { $0 << 8 | UInt32(self[$1]) } }
    func be64(_ offset: Int) -> UInt64 { (offset..<offset + 8).reduce(0) { $0 << 8 | UInt64(self[$1]) } }
}
