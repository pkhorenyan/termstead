import Foundation

@main struct NativeFileOracle {
    static func main() throws {
        let args = CommandLine.arguments
        if args[1] == "receive" {
            let input = try Data(contentsOf: URL(fileURLWithPath: args[2]))
            let destination = URL(fileURLWithPath: args[3])
            let receiver = try VNCFileDownloadStream(folder: destination)
            var offset = 0
            while offset + 6 <= input.count {
                let length = (0..<4).reduce(0) { $0 | Int(input[offset + $1]) << (8 * $1) }
                let command = UInt16(input[offset + 4]) | UInt16(input[offset + 5]) << 8
                guard length >= 2, length <= input.count - offset - 4 else { throw VNCFileError.invalid }
                if command == 1 {
                    try receiver.accept(VNCFileMessage(wire: input.subdata(in: offset + 6..<offset + 4 + length)))
                }
                offset += 4 + length
            }
            guard receiver.done else { throw VNCFileError.changed }
        } else {
            let sender = try VNCFileUpload(urls: [URL(fileURLWithPath: args[2])], session: 123, revision: 0)
            let output = URL(fileURLWithPath: args[3])
            _ = FileManager.default.createFile(atPath: output.path, contents: nil)
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            while let packet = try sender.next() { try handle.write(contentsOf: packet) }
        }
    }
}
