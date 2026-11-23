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
    private(set) var draggedFiles: FileDrop.Payload?
    private(set) var draggedSelection: (browser: FileBrowser, files: [RemoteFile])?

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
        guard dx * dx + dy * dy > 36 else { return }
        let items = prepareDrag(at: convert(start, from: nil))
        resetPress()
        guard !items.isEmpty else { return }
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.draggingFormation = .stack
    }

    func prepareDrag(at point: NSPoint) -> [NSDraggingItem] {
        draggedFiles = nil
        draggedSelection = nil
        guard let browser else { return [] }
        let items = Self.draggingItems(for: pressedFiles, from: browser, at: point)
        guard !items.isEmpty else { return [] }
        draggedSelection = (browser, pressedFiles)
        if browser.isLocal {
            draggedFiles = .local(pressedFiles.map { URL(fileURLWithPath: $0.path) })
        } else if let reference = (items.first?.item as? RemoteFileDragWriter)?.reference {
            draggedFiles = .remote(reference)
        }
        return items
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
            writer.reference = reference
            writer.referenceData = data
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
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.copy, .move] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        draggedFiles = nil
        draggedSelection = nil
    }
}

struct RemoteFileDragReference: Codable, Equatable, Sendable {
    static let type = UTType(exportedAs: "com.pavelkhorenyan.termstead.remote-file-drag", conformingTo: .data)
    static let pasteboardType = NSPasteboard.PasteboardType(type.identifier)
    let connectionID: UUID
    let token: UUID
}

private final class RemoteFileDragWriter: NSFilePromiseProvider {
    var reference: RemoteFileDragReference?
    var referenceData: Data?

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [RemoteFileDragReference.pasteboardType]
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == RemoteFileDragReference.pasteboardType { return referenceData }
        return super.pasteboardPropertyList(forType: type)
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType,
                                 pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        if type == RemoteFileDragReference.pasteboardType { return [] }
        return super.writingOptions(forType: type, pasteboard: pasteboard)
    }
}

/// AppKit supplies the drag source and its pasteboard directly to this target.
struct FileDropTarget: NSViewRepresentable {
    var browser: FileBrowser
    var folder: String?
    var onTargeted: (Bool) -> Void
    var onDrop: (FileDrop.Payload) -> Bool

    func makeNSView(context: Context) -> FileDropTargetView { FileDropTargetView() }

    func updateNSView(_ view: FileDropTargetView, context: Context) {
        view.browser = browser
        view.folder = folder
        view.onTargeted = onTargeted
        view.onDrop = onDrop
    }
}

final class FileDropTargetView: NSView {
    weak var browser: FileBrowser?
    var folder: String? {
        didSet { if oldValue != folder { updateDropTypes() } }
    }
    var onTargeted: (Bool) -> Void = { _ in }
    var onDrop: (FileDrop.Payload) -> Bool = { _ in false }
    private var operation: NSDragOperation = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        updateDropTypes()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not loaded from a nib") }

    private func updateDropTypes() {
        var types: [NSPasteboard.PasteboardType] = [.fileURL]
        if folder != nil {
            types.append(RemoteFileDragReference.pasteboardType)
            // The native source can supply the remote selection even if the
            // system advertises only the standard file promise types.
            types += NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        }
        unregisterDraggedTypes()
        registerForDraggedTypes(types)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        switch NSApp.currentEvent?.type {
        case .leftMouseUp where operation.isEmpty: return nil
        case .leftMouseDown, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
             .mouseMoved, .scrollWheel: return nil
        default: return super.hitTest(point)
        }
    }

    private func dropOperation(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let source = sender.draggingSource as? FileDragView
        if let selection = source?.draggedSelection, let browser {
            guard let folder else { return [] }
            if selection.browser === browser {
                return browser.canMove(selection.files, into: folder) && sender.draggingSourceOperationMask.contains(.move)
                    ? .move : []
            }
        }
        guard sender.draggingSourceOperationMask.contains(.copy) else { return [] }
        switch source?.draggedFiles {
        case .local: return .copy
        case .remote: return browser?.isLocal == true && folder != nil ? .copy : []
        case nil:
            let types = sender.draggingPasteboard.types ?? []
            if types.contains(RemoteFileDragReference.pasteboardType) {
                return browser?.isLocal == true && folder != nil ? .copy : []
            }
            return types.contains(.fileURL) ? .copy : []
        }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        operation = dropOperation(sender)
        onTargeted(!operation.isEmpty)
        return operation
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let updated = dropOperation(sender)
        if operation != updated {
            operation = updated
            onTargeted(!operation.isEmpty)
        }
        return operation
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { clearTarget() }

    private func clearTarget() {
        operation = []
        onTargeted(false)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { clearTarget() }
        let source = sender.draggingSource as? FileDragView
        let operation = dropOperation(sender)
        if operation == .move, let selection = source?.draggedSelection, let folder {
            return selection.browser.move(selection.files, into: folder)
        }
        guard operation == .copy else { return false }
        guard let payload = source?.draggedFiles ?? FileDrop.read(sender.draggingPasteboard) else { return false }
        if case .remote = payload, browser?.isLocal != true { return false }
        return onDrop(payload)
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
