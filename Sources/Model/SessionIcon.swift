import AppKit
import SwiftUI

/// The twelve icons a session can carry. The mockup draws them as custom SVG
/// strokes; the native app maps each to the closest SF Symbol.
enum SessionIcon: String, CaseIterable, Identifiable, Hashable, Codable, Sendable {
    case server, globe, database, container, cloud, shield
    case chip, drive, router, monitor, home, terminal

    var id: String { rawValue }

    var label: String {
        switch self {
        case .server: "Server"
        case .globe: "Web"
        case .database: "Database"
        case .container: "Container"
        case .cloud: "Cloud"
        case .shield: "Bastion"
        case .chip: "Board"
        case .drive: "Storage"
        case .router: "Network"
        case .monitor: "Desktop"
        case .home: "Home"
        case .terminal: "Shell"
        }
    }

    /// Primary symbol, with a fallback for anything missing on the deployment
    /// target. `symbolName` resolves to whichever of the two actually exists.
    private var candidates: [String] {
        switch self {
        case .server: ["server.rack", "externaldrive.connected.to.line.below"]
        case .globe: ["globe"]
        case .database: ["cylinder.split.1x2", "cylinder"]
        case .container: ["shippingbox"]
        case .cloud: ["cloud"]
        case .shield: ["shield"]
        case .chip: ["cpu"]
        case .drive: ["internaldrive"]
        case .router: ["wifi.router", "network"]
        case .monitor: ["desktopcomputer"]
        case .home: ["house"]
        case .terminal: ["terminal"]
        }
    }

    /// Probing SF Symbols means building an `NSImage`. Resolving on every read
    /// meant doing that for every visible row on every redraw, so the answer is
    /// worked out once and kept.
    @MainActor
    private static let resolvedSymbols: [SessionIcon: String] = {
        var out: [SessionIcon: String] = [:]
        for icon in allCases {
            out[icon] = icon.candidates.first {
                NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil
            } ?? "questionmark.square.dashed"
        }
        return out
    }()

    @MainActor
    var symbolName: String {
        Self.resolvedSymbols[self] ?? "questionmark.square.dashed"
    }
}
