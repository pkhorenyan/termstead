import Foundation
import Testing
@testable import Termstead

@MainActor
struct SessionArchiveTests {
    private func sample() -> SessionSnapshot { SessionStore.sample().snapshot }

    @Test func plainExportRoundTripsEverySavedField() throws {
        let snapshot = sample()
        let data = try SessionArchive.encode(SessionArchive.document(snapshot))
        #expect(try !SessionArchive.isEncrypted(data))
        let contents = try SessionArchive.decode(data)
        #expect(contents.snapshot == snapshot)
        #expect(contents.credentials.isEmpty)
        #expect(contents.unsupportedCount == 0)
    }

    @Test func encryptedExportKeepsSecretsAndUsesFreshRandomness() throws {
        let snapshot = sample()
        let identity = try #require(snapshot.sessions.first?.persistentID)
        let document = try SessionArchive.document(snapshot, credentials: [
            .init(sessionID: identity, role: "password", value: "private-password-秘密")])
        let first = try SessionArchive.encode(document, password: "backup-password-🔐")
        let second = try SessionArchive.encode(document, password: "backup-password-🔐")
        #expect(first != second)
        #expect(!String(decoding: first, as: UTF8.self).contains("private-password"))
        #expect(!String(decoding: first, as: UTF8.self).contains(snapshot.sessions[0].host))
        #expect(try SessionArchive.isEncrypted(first))
        let result = try SessionArchive.decode(first, password: "backup-password-🔐")
        #expect(result.snapshot == snapshot)
        #expect(result.credentials.first?.value == "private-password-秘密")
        #expect(throws: SessionArchive.Problem.self) { try SessionArchive.decode(first) }
        #expect(throws: SessionArchive.Problem.self) { try SessionArchive.decode(first, password: "wrong") }
    }

    @Test func plainFilesCannotContainPasswords() throws {
        let snapshot = sample()
        let document = try SessionArchive.document(snapshot, credentials: [
            .init(sessionID: snapshot.sessions[0].persistentID!, role: "password", value: "secret")])
        #expect(throws: SessionArchive.Problem.self) { try SessionArchive.encode(document) }
        #expect(throws: SessionArchive.Problem.self) { try SessionArchive.decode(JSONEncoder().encode(document)) }
    }

    @Test func encryptionDetectsTamperingAndRejectsExpensiveKDFParameters() throws {
        let data = try SessionArchive.encode(SessionArchive.document(sample()), password: "password")
        var envelope = try JSONDecoder().decode(SessionArchive.Envelope.self, from: data)
        envelope.sealed[envelope.sealed.count / 2] ^= 1
        let tampered = try JSONEncoder().encode(envelope)
        #expect(throws: SessionArchive.Problem.self) { try SessionArchive.decode(tampered, password: "password") }
        envelope.rounds = UInt32.max
        #expect(throws: SessionArchive.Problem.self) {
            try SessionArchive.decode(JSONEncoder().encode(envelope), password: "password")
        }
    }

    @Test func futureVNCSessionsAreSkippedBeforeDecodingTheirOptions() throws {
        let snapshot = sample()
        var document = try SessionArchive.document(snapshot)
        document.sessions.append(.init(type: "vnc", settings: .object([
            "id": .string("future-vnc"), "persistentID": .string(UUID().uuidString),
            "vncOptions": .object(["encoding": .string("future-encoding")])
        ])))
        document.groups[0].children.append(.session("future-vnc"))
        let contents = try SessionArchive.decode(SessionArchive.encode(document))
        #expect(contents.snapshot.sessions == snapshot.sessions)
        #expect(contents.snapshot.sessions.count == document.sessions.count - 1)
        #expect(contents.unsupportedTypes == ["vnc"])
        #expect(contents.unsupportedCount == 1)
        #expect(!contents.snapshot.tree[0].children.contains(.session("future-vnc")))
    }

    @Test func newerEnvelopeAndBadFilesAreRejected() throws {
        var document = try SessionArchive.document(sample())
        document.version += 1
        #expect(throws: SessionArchive.Problem.self) { try SessionArchive.decode(JSONEncoder().encode(document)) }
        #expect(throws: SessionArchive.Problem.self) { try SessionArchive.decode(Data("not JSON".utf8)) }
        #expect(throws: SessionArchive.Problem.self) {
            try SessionArchive.decode(Data(repeating: 0, count: SessionArchive.maxFileSize + 1))
        }
    }

    @Test func malformedNamesIdentitiesTreeAndCredentialsAreRejected() throws {
        let snapshot = sample()
        let document = try SessionArchive.document(snapshot)
        var duplicate = document
        duplicate.sessions.append(document.sessions[0])
        #expect(throws: SessionArchive.Problem.self) { try SessionArchive.contents(duplicate) }
        var missing = document
        missing.groups = []
        #expect(throws: SessionArchive.Problem.self) { try SessionArchive.contents(missing) }
        var groups = document
        groups.groups.append(document.groups[0])
        #expect(throws: SessionArchive.Problem.self) { try SessionArchive.contents(groups) }
        var credentials = document
        credentials.credentials = [.init(sessionID: UUID(), role: "password", value: "x")]
        #expect(throws: SessionArchive.Problem.self) { try SessionArchive.contents(credentials) }
        var role = document
        role.credentials = [.init(sessionID: snapshot.sessions[0].persistentID!, hopID: UUID(), role: "hopPassword", value: "x")]
        #expect(throws: SessionArchive.Problem.self) { try SessionArchive.contents(role) }
    }

    @Test func atomicExportHasPrivatePermissionsAndCanReplaceAFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("archive-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("backup.termstead")
        let data = try SessionArchive.encode(SessionArchive.document(sample()))
        try SessionArchive.write(Data("previous".utf8), to: url)
        try SessionArchive.write(data, to: url)
        #expect(try SessionArchive.read(from: url) == data)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["backup.termstead"])
        #expect(throws: (any Error).self) { try SessionArchive.write(data, to: folder) }
        #expect(try SessionArchive.read(from: url) == data)
    }
}
