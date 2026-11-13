import AppKit
import Foundation

// Test utility for the isolated guest only. Never run against the host's
// general pasteboard: integration tests use a named pasteboard on the host.
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "transport-files" {
    let items = arguments.dropFirst().map { path in
        let item = NSPasteboardItem()
        item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
        // Explicit transport fixture. This private flavor is passed through
        // by Screen Sharing; ordinary Finder Command-C is a separate UI case.
        item.setData(Data(path.utf8), forType: .init("com.apple.finder.node"))
        return item
    }
    NSPasteboard.general.clearContents()
    guard NSPasteboard.general.writeObjects(items) else { exit(1) }
} else if arguments.first == "text", arguments.count == 2 {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(arguments[1], forType: .string)
} else if arguments.first == "inspect" {
    let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    let data = try JSONEncoder().encode(urls.map(\.path))
    FileHandle.standardOutput.write(data)
} else if arguments.first == "types" {
    let items = NSPasteboard.general.pasteboardItems ?? []
    let types = items.map { item in
        item.types.map { type in ["type": type.rawValue, "bytes": String(item.data(forType: type)?.count ?? 0)] }
    }
    FileHandle.standardOutput.write(try JSONEncoder().encode(types))
} else { exit(2) }
