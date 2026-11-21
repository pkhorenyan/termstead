import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Local files are native drag items, one file URL per selected row.
struct LocalFileDrag: NSViewRepresentable {
    var file: RemoteFile
    var browser: FileBrowser
    var onFocus: () -> Void

    func makeNSView(context: Context) -> LocalFileDragView { LocalFileDragView() }

    func updateNSView(_ view: LocalFileDragView, context: Context) {
        view.file = file
        view.browser = browser
        view.onFocus = onFocus
    }
}

final class LocalFileDragView: NSView, NSDraggingSource {
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
        let items = Self.draggingItems(for: pressedFiles, at: convert(start, from: nil))
        resetPress()
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

    static func draggingItems(for files: [RemoteFile], at point: NSPoint) -> [NSDraggingItem] {
        let frame = NSRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24)
        return files.enumerated().map { index, file in
            let url = URL(fileURLWithPath: file.path, isDirectory: file.kind == .directory)
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            // AppKit still writes each item even when it has no drag image.
            let image = index < 5 ? NSWorkspace.shared.icon(for: file.kind == .directory ? .folder : .data) : nil
            item.setDraggingFrame(frame, contents: image)
            return item
        }
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}
