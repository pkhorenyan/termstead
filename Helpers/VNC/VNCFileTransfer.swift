import Foundation

/// Called only on LibVNCClient's worker. Every request uses the authenticated
/// VNC connection (including existing SSH tunnels); no guest agent or SSH login.
final class VNCFileTransfer {
    let revision: Int
    let sending: Bool
    let token: UInt32
    var session: UInt32 { upload?.session ?? id }
    var copied: UInt64 { upload?.copied ?? completedBytes + (download?.copied ?? 0) }
    var total: UInt64 { upload?.total ?? max(copied, completedBytes + (download?.total ?? 0)) }
    var waitingForUploadReply: Bool { upload?.awaitingReply == true }
    private let upload: VNCFileUpload?
    private let urls: [URL]
    private let folder: URL?
    private var id: UInt32
    private var index = 0
    private var download: VNCFileDownloadStream?
    private var completedBytes: UInt64 = 0
    private var localURLs: [URL] = []
    private(set) var ready: [String]?
    private var retained = false

    init(urls: [URL], revision: Int, upload: Bool, id: UInt32) throws {
        self.revision = revision; sending = upload; self.urls = urls; self.id = id; token = id
        guard !urls.isEmpty, urls.count <= 64 else { throw VNCFileError.limit }
        if upload {
            self.upload = try VNCFileUpload(urls: urls, session: id, revision: revision)
            folder = nil
        } else {
            self.upload = nil
            let folder = URL.temporaryDirectory.appendingPathComponent("termstead-vnc-\(UUID())")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                     attributes: [.posixPermissions: 0o700])
            self.folder = folder
        }
    }
    deinit {
        // Complete clipboard files must outlive the tab so Finder can paste.
        if !retained, let folder { try? FileManager.default.removeItem(at: folder) }
    }
    func next() throws -> Data? {
        if let upload { return try upload.next() }
        guard download == nil, index < urls.count, let folder else { return nil }
        download = try VNCFileDownloadStream(folder: folder.appendingPathComponent(String(index)))
        return try VNCFileMessage.start(session: id, path: urls[index].path, upload: false).wire
    }
    func accept(_ message: VNCFileMessage) throws {
        guard message.session == session else { return } // Late reply after cancellation.
        if let upload {
            if message.kind == 200 {
                let name = try message.completionName()
                guard upload.awaitingReply else { throw VNCFileError.invalid }
                guard name == URL(string: upload.remoteURLs[0])?.deletingLastPathComponent().lastPathComponent else {
                    throw VNCFileError.invalid
                }
                ready = upload.remoteURLs
            }
            // Progress/status messages never make us read extra host paths.
        } else if let download {
            if message.kind == 200 { _ = try message.completionName(); throw VNCFileError.invalid }
            try download.accept(message)
            if download.done {
                localURLs.append(contentsOf: download.top)
                completedBytes += download.copied
                self.download = nil; index += 1; id &+= 1
                if index == urls.count {
                    retained = true
                    ready = localURLs.map(\.absoluteString)
                }
            }
        }
    }
    static func fileURLs(_ strings: [String]) -> [URL]? {
        guard !strings.isEmpty, strings.count <= 64 else { return nil }
        var urls: [URL] = []
        for value in strings {
            guard let url = URL(string: value), url.isFileURL,
                  url.host == nil || url.host == "" || url.host == "localhost",
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.path.hasPrefix("/"), !url.path.contains("\0"), url.path.utf8.count <= 1023 else { return nil }
            urls.append(url)
        }
        return urls
    }
}
