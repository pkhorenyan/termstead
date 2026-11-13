import Foundation
import Testing
@testable import Termstead

struct VNCFileTests {
    private func temporary() throws -> URL {
        let url = URL.temporaryDirectory.appendingPathComponent("termstead-files-test-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    @Test func streamsNestedBinaryAndEmptyFilesWithoutReadingWholeFiles() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Папка 🙂")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data().write(to: source.appendingPathComponent("empty"))
        let bytes = Data((0..<2_100_007).map { UInt8(truncatingIfNeeded: $0) })
        try bytes.write(to: source.appendingPathComponent("nested/данные.bin"))
        let upload = try VNCFileUpload(urls: [source], session: 9, revision: 10)
        let download = try VNCFileDownloadStream(folder: root.appendingPathComponent("received"))
        var chunks = 0
        while let packet = try upload.next() {
            let message = try VNCFileMessage(wire: packet)
            if message.kind == 2 { continue }
            if message.kind == 102 {
                #expect(message.payload.count <= 65_536)
                chunks += 1
            }
            try download.accept(message)
        }
        try #require(download.done && upload.awaitingReply)
        #expect(chunks > 30 && download.copied == bytes.count)
        let copied = try #require(download.top.first).appendingPathComponent(source.lastPathComponent)
        #expect(try Data(contentsOf: copied.appendingPathComponent("nested/данные.bin")) == bytes)
        #expect(try Data(contentsOf: copied.appendingPathComponent("empty")).isEmpty)
    }
    @Test(arguments: ["..", ".", "/tmp/escape", "a/b", "a\0b", "a:b", ""])
    func rejectsUnsafeRemoteNames(_ name: String) throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let download = try VNCFileDownloadStream(folder: root.appendingPathComponent("received"))
        var payload = Data(repeating: 0, count: 100)
        payload.putBE(UInt16(name.utf8.count), at: 96); payload.append(contentsOf: name.utf8); payload.append(0)
        #expect(throws: (any Error).self) {
            try download.accept(VNCFileMessage(kind: 101, session: 1, argument: 0x01000000, payload: payload))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: download.folder.path).isEmpty)
    }
    @Test func rejectsMissingBytesDuplicateNamesAndUnexpectedLevels() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let missing = try VNCFileDownloadStream(folder: root.appendingPathComponent("missing"))
        try missing.accept(.item(session: 1, name: "file", directory: false, level: 0, size: 2))
        #expect(throws: (any Error).self) { try missing.accept(VNCFileMessage(kind: 104, session: 1)) }
        #expect(!missing.done)
        let duplicate = try VNCFileDownloadStream(folder: root.appendingPathComponent("duplicate"))
        try duplicate.accept(.item(session: 1, name: "same", directory: false, level: 0, size: 0))
        #expect(throws: (any Error).self) {
            try duplicate.accept(.item(session: 1, name: "SAME", directory: false, level: 0, size: 0))
        }
        let level = try VNCFileDownloadStream(folder: root.appendingPathComponent("levels"))
        #expect(throws: (any Error).self) {
            try level.accept(.item(session: 1, name: "orphan", directory: false, level: 1, size: 0))
        }
    }
    @Test func skipsNoLinksAndReadsOnlyTheSelectedRegularFiles() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("file")
        try Data([1, 2, 3]).write(to: source)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        #expect(throws: (any Error).self) { try VNCFileUpload(urls: [link], session: 1, revision: 1) }
        let upload = try VNCFileUpload(urls: [source], session: 1, revision: 1)
        try FileManager.default.removeItem(at: source)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: link)
        #expect(throws: (any Error).self) { while try upload.next() != nil {} }
    }
    @Test func malformedWireAndExcessDataAreRejected() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        var wire = VNCFileMessage(kind: 104, session: 1).wire
        wire[5] = 255
        #expect(throws: (any Error).self) { try VNCFileMessage(wire: wire) }
        #expect(throws: (any Error).self) { try VNCFileMessage(wire: Data([0x22])) }
        let download = try VNCFileDownloadStream(folder: root.appendingPathComponent("received"))
        try download.accept(.item(session: 1, name: "file", directory: false, level: 0, size: 1))
        #expect(throws: (any Error).self) {
            try download.accept(VNCFileMessage(kind: 102, session: 1, argument: 2, payload: Data([1, 2])))
        }
    }
}
