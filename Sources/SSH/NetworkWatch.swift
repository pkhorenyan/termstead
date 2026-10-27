import Foundation
import Network

/// Whether this Mac has a network to reach servers over, for reconnecting
/// a dropped tab: dialing while Wi-Fi is still coming back after sleep only
/// spends an attempt.
@MainActor
final class NetworkWatch {
    static let shared = NetworkWatch()

    private(set) var isOnline = true
    private let monitor = NWPathMonitor()
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private init() {
        monitor.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            Task { @MainActor in NetworkWatch.shared.update(online) }
        }
        monitor.start(queue: DispatchQueue(label: "com.pavelkhorenyan.Termstead.network"))
    }

    private func update(_ online: Bool) {
        isOnline = online
        guard online else { return }
        let resumed = waiting
        waiting = []
        resumed.forEach { $0.resume() }
    }

    /// Returns at once when online, otherwise once the network is back.
    func untilOnline() async {
        guard !isOnline else { return }
        await withCheckedContinuation { waiting.append($0) }
    }
}
