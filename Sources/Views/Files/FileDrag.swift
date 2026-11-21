import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FileDrag: NSViewRepresentable {
    var file: RemoteFile
    var browser: FileBrowser
    var onFocus: () -> Void

    func makeNSView(context: Context) -> FileDragView { FileDragView() }

    func updateNSView(_ view: FileDragView, context: Context) {
        view.file = file
        view.browser = browser
        view.onFocus = onFocus
    }
}

final class FileDragView: NSView, NSDraggingSource {
    var file: RemoteFile?
    weak var browser: FileBrowser?
    var onFocus: () -> Void = {}
    private var pressLocation: NSPoint?
    private var collapsesOnMouseUp = false
    private(set) var pressedFiles: [RemoteFile] = []

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent, event.type == .leftMouseDown,
              !event.modifierFlags.contains(.control) else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        resetPress()
        guard let file, let browser else { return }
        onFocus()
        let modifiers = event.modifierFlags.intersection([.command, .shift])
        if modifiers.isEmpty, event.clickCount >= 2 {
            browser.open(file)
            return
        }
        // A plain press on a selected row may start a drag of the whole group.
        let selection = browser.filesForAction(on: file)
        if modifiers.isEmpty, selection.count > 1 {
            collapsesOnMouseUp = true
        } else {
            browser.select(file, modifiers: modifiers)
        }
        pressedFiles = browser.filesForAction(on: file)
        pressLocation = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressLocation, !pressedFiles.isEmpty else { return }
        let dx = event.locationInWindow.x - start.x
        let dy = event.locationInWindow.y - start.y
        guard dx * dx + dy * dy > 9 else { return }
        guard let browser else { return }
        let items = Self.draggingItems(for: pressedFiles, from: browser, at: convert(start, from: nil))
        resetPress()
        guard !items.isEmpty else { return }
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.draggingFormation = .stack
    }

    override func mouseUp(with event: NSEvent) {
        if collapsesOnMouseUp, let file { browser?.select(file) }
        resetPress()
    }

    private func resetPress() {
        pressLocation = nil
        collapsesOnMouseUp = false
        pressedFiles = []
    }

    static func draggingItems(for files: [RemoteFile], from browser: FileBrowser, at point: NSPoint) -> [NSDraggingItem] {
        if browser.isLocal {
            return draggingItems(for: files, at: point) { file in
                URL(fileURLWithPath: file.path, isDirectory: file.kind == .directory) as NSURL
            }
        }
        guard let client = browser.transferClient, let reference = browser.beginRemoteDrag(files),
              let data = try? JSONEncoder().encode(reference) else { return [] }
        return draggingItems(for: files, at: point) { file in
            let promise = RemoteFilePromise(file: file, client: client)
            let type: UTType = file.kind == .directory ? .folder : .data
            let writer = RemoteFileDragWriter(fileType: type.identifier, delegate: promise)
            writer.userInfo = promise // The provider's delegate is weak.
            writer.reference = data
            return writer
        }
    }

    private static func draggingItems(for files: [RemoteFile], at point: NSPoint,
                                      writer: (RemoteFile) -> any NSPasteboardWriting) -> [NSDraggingItem] {
        let frame = NSRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24)
        return files.enumerated().map { index, file in
            let item = NSDraggingItem(pasteboardWriter: writer(file))
            // AppKit still writes each item even when it has no drag image.
            let image = index < 5 ? NSWorkspace.shared.icon(for: file.kind == .directory ? .folder : .data) : nil
            item.setDraggingFrame(frame, contents: image)
            return item
        }
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

struct RemoteFileDragReference: Codable, Equatable, Sendable {
    static let type = UTType(exportedAs: "com.pavelkhorenyan.termstead.remote-file-drag", conformingTo: .data)
    let connectionID: UUID
    let token: UUID
}

private final class RemoteFileDragWriter: NSFilePromiseProvider {
    static let pasteboardType = NSPasteboard.PasteboardType(RemoteFileDragReference.type.identifier)
    var reference: Data?

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [Self.pasteboardType]
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == Self.pasteboardType { return reference }
        return super.pasteboardPropertyList(forType: type)
    }
}

private final class RemoteFilePromise: NSObject, NSFilePromiseProviderDelegate {
    let file: RemoteFile
    let client: any FileSource

    init(file: RemoteFile, client: any FileSource) {
        self.file = file
        self.client = client
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        file.name
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        let file = self.file
        let client = self.client
        Task {
            let local = LocalFiles()
            let stage = url.deletingLastPathComponent()
                .appendingPathComponent(".termstead-transfer-\(UUID().uuidString)", isDirectory: true)
            do {
                try await local.makeTransferStage(stage.path)
                var recursive = file.kind == .directory
                if file.kind == .symlink { recursive = await client.isDirectory(file.path) }
                try await client.download(file.path, recursive: recursive,
                                          to: stage, as: url.lastPathComponent)
                let stagedFile = stage.appendingPathComponent(url.lastPathComponent)
                try await local.finishTransfer(stagedFile.path, at: url.path, replacing: false)
                try? await local.discardTransferStage(stage.path)
                completionHandler(nil)
            } catch {
                try? await local.discardTransferStage(stage.path)
                completionHandler(error)
            }
        }
    }
}
