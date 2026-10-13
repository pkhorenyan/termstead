import Foundation

/// The figures the status bar shows for the server in front: CPU, memory,
/// the root file system and network traffic.
struct ServerLoad: Equatable, Sendable {
    /// Busy share of all CPUs, 0…1. `nil` until two samples are in.
    var cpu: Double?
    var memoryUsed: UInt64
    var memoryTotal: UInt64
    /// Of `/`, as `df` reports it, 0…100.
    var diskPercent: Int?
    var diskUsed: UInt64?
    var diskTotal: UInt64?
    /// Bytes per second across every interface but loopback; `nil` until two
    /// samples are in.
    var receiveRate: Double?
    var sendRate: Double?
    var loadAverage: [Double]
    var uptime: TimeInterval

    var memoryShare: Double { memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) : 0 }

    /// What a fresh watch cannot know yet — the CPU share and the rates need
    /// a second sample — is carried over from the figures shown before, so
    /// coming back to a tab does not blank them for a few seconds.
    func filling(from earlier: ServerLoad?) -> ServerLoad {
        var load = self
        load.cpu = cpu ?? earlier?.cpu
        load.receiveRate = receiveRate ?? earlier?.receiveRate
        load.sendRate = sendRate ?? earlier?.sendRate
        return load
    }
}

extension ServerLoad {
    static func percent(_ share: Double) -> String {
        "\(Int((share * 100).rounded()))%"
    }

    /// Binary gigabytes, as Activity Monitor counts memory: one decimal
    /// below 10, none above.
    static func gigabytes(_ bytes: UInt64) -> String {
        let value = Double(bytes) / 1_073_741_824
        return value < 10 ? String(format: "%.1f", value) : String(Int(value.rounded()))
    }

    /// Decimal units, as network speeds are counted.
    static func rate(_ bytesPerSecond: Double?) -> String {
        guard let value = bytesPerSecond else { return "–" }
        switch value {
        case ..<1_000: return "\(Int(value)) B/s"
        case ..<1_000_000: return "\(Int(value / 1_000)) KB/s"
        case ..<1_000_000_000: return String(format: "%.1f MB/s", value / 1_000_000)
        default: return String(format: "%.1f GB/s", value / 1_000_000_000)
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let days = minutes / 1_440, hours = minutes % 1_440 / 60
        if days > 0 { return "\(days) d \(hours) h" }
        if hours > 0 { return "\(hours) h \(minutes % 60) min" }
        return "\(minutes) min"
    }

    /// The tooltip: what there is no room for in the bar itself.
    var details: String {
        var lines: [String] = []
        if loadAverage.count == 3 {
            lines.append("Load average " + loadAverage.map { String(format: "%.2f", $0) }.joined(separator: "  "))
        }
        if let diskUsed, let diskTotal {
            lines.append("Disk /: \(Self.gigabytes(diskUsed)) of \(Self.gigabytes(diskTotal)) GB used")
        }
        if uptime > 0 { lines.append("Up \(Self.duration(uptime))") }
        return lines.joined(separator: "\n")
    }
}

/// One reading of the counters, from one block of `ServerLoadScript` output.
struct ServerLoadSample: Equatable, Sendable {
    var cpuTotal: UInt64
    var cpuIdle: UInt64
    var memoryTotal: UInt64
    var memoryAvailable: UInt64
    var received: UInt64
    var sent: UInt64
    var diskPercent: Int?
    var diskUsed: UInt64?
    var diskTotal: UInt64?
    var uptime: TimeInterval
    var loadAverage: [Double]

    /// Parses one block, the lines between `@end` markers. `nil` when the
    /// CPU or memory lines are missing — there is nothing worth showing then.
    static func parse(_ block: String) -> ServerLoadSample? {
        var section = ""
        var cpu: [UInt64] = []
        var memory: [String: UInt64] = [:]
        var received: UInt64 = 0, sent: UInt64 = 0
        var disk: (used: UInt64, available: UInt64, percent: Int)?
        var uptime: TimeInterval = 0
        var loadAverage: [Double] = []

        for raw in block.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.hasPrefix("@") {
                section = line
                continue
            }
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            switch section {
            case "@stat":
                // user nice system idle iowait irq softirq steal; guest time
                // is already counted in user.
                if fields.first == "cpu" { cpu = fields.dropFirst().prefix(8).compactMap { UInt64($0) } }
            case "@mem":
                if fields.count >= 2, let value = UInt64(fields[1]) {
                    memory[fields[0].trimmingCharacters(in: [":"])] = value * 1024
                }
            case "@net":
                // "  eth0: 1234 12 0 0 0 0 0 0 5678 …": received bytes come
                // first after the colon, sent bytes ninth.
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces)
                let counters = line[line.index(after: colon)...].split(whereSeparator: \.isWhitespace)
                guard name != "lo", counters.count >= 9,
                      let rx = UInt64(counters[0]), let tx = UInt64(counters[8]) else { continue }
                received &+= rx
                sent &+= tx
            case "@df":
                // Filesystem 1024-blocks Used Available Capacity Mounted-on,
                // read from the end: a file system's name may hold spaces.
                let count = fields.count
                guard count >= 6, let used = UInt64(fields[count - 4]),
                      let available = UInt64(fields[count - 3]),
                      let percent = Int(fields[count - 2].trimmingCharacters(in: ["%"])) else { continue }
                disk = (used * 1024, available * 1024, percent)
            case "@up":
                if fields.count == 2, let seconds = Double(fields[0]) {
                    uptime = seconds
                } else if fields.count >= 3 {
                    loadAverage = fields.prefix(3).compactMap { Double($0) }
                }
            default:
                break
            }
        }

        guard cpu.count >= 4, let total = memory["MemTotal"], total > 0 else { return nil }
        // MemAvailable came with Linux 3.14; before it, free plus caches is
        // what `free` itself showed.
        let available = memory["MemAvailable"]
            ?? (memory["MemFree"] ?? 0) + (memory["Buffers"] ?? 0) + (memory["Cached"] ?? 0)
        let idle = cpu[3] + (cpu.count > 4 ? cpu[4] : 0)
        return ServerLoadSample(cpuTotal: cpu.reduce(0, +), cpuIdle: idle,
                                memoryTotal: total, memoryAvailable: min(available, total),
                                received: received, sent: sent,
                                diskPercent: disk?.percent, diskUsed: disk?.used,
                                diskTotal: disk.map { $0.used + $0.available },
                                uptime: uptime, loadAverage: loadAverage)
    }

    /// The figures for this sample, with the CPU share and the rates taken
    /// over the time since `previous`.
    func load(since previous: ServerLoadSample?) -> ServerLoad {
        var cpu: Double?
        var receiveRate: Double?, sendRate: Double?
        if let previous {
            if cpuTotal > previous.cpuTotal {
                let total = Double(cpuTotal - previous.cpuTotal)
                let idle = Double(cpuIdle >= previous.cpuIdle ? cpuIdle - previous.cpuIdle : 0)
                cpu = min(max((total - idle) / total, 0), 1)
            }
            // Counters can go back — an interface removed, a wrap — and the
            // rate then means nothing for this one step.
            let elapsed = uptime - previous.uptime
            if elapsed > 0, received >= previous.received, sent >= previous.sent {
                receiveRate = Double(received - previous.received) / elapsed
                sendRate = Double(sent - previous.sent) / elapsed
            }
        }
        return ServerLoad(cpu: cpu, memoryUsed: memoryTotal - memoryAvailable, memoryTotal: memoryTotal,
                          diskPercent: diskPercent, diskUsed: diskUsed, diskTotal: diskTotal,
                          receiveRate: receiveRate, sendRate: sendRate,
                          loadAverage: loadAverage, uptime: uptime)
    }
}

/// What runs on the server: a loop printing one block of counters every
/// `interval` seconds. Linux only — it reads /proc — and it says so at once
/// elsewhere. When the tab goes away the next `echo` hits a closed channel
/// and the loop ends with it.
enum ServerLoadScript {
    static let interval = 3
    static let unsupported = "@unsupported"
    static let blockEnd = "@end"

    static var text: String {
        """
        [ -r /proc/stat ] && [ -r /proc/meminfo ] || { echo \(unsupported); exit 0; }
        while :; do
          echo @stat
          read -r l < /proc/stat; echo "$l"
          echo @mem
          while read -r k v _; do
            case $k in MemTotal:|MemAvailable:|MemFree:|Buffers:|Cached:) echo "$k $v";; esac
          done < /proc/meminfo
          echo @net
          cat /proc/net/dev 2>/dev/null
          echo @df
          df -Pk / 2>/dev/null | tail -n 1
          echo @up
          cat /proc/uptime /proc/loadavg 2>/dev/null
          echo \(blockEnd)
          sleep \(interval) || exit 0
        done
        """
    }
}

/// Runs `ServerLoadScript` over a tab's connection and reports each block.
///
/// One channel that stays open, rather than a command every few seconds: each
/// new channel is a line in the server's auth log ("Starting session:
/// command …"), and a poll would have written thousands a day per tab.
@MainActor
final class ServerLoadWatch {
    private var process: Process?
    private var previous: ServerLoadSample?
    private let onLoad: (ServerLoad) -> Void
    private let onUnsupported: () -> Void

    init(onLoad: @escaping (ServerLoad) -> Void, onUnsupported: @escaping () -> Void) {
        self.onLoad = onLoad
        self.onUnsupported = onUnsupported
    }

    /// - Parameter arguments: ssh's, joining the tab's connection master.
    func start(arguments: [String]) {
        stop()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: SSHLaunch.executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        let blocks = BlockSplitter()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            for block in blocks.append(data) {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.receive(block) }
                }
            }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
        }
    }

    func stop() {
        guard let process else { return }
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        self.process = nil
        previous = nil
    }

    private func receive(_ block: String) {
        guard process != nil else { return }
        if block.contains(ServerLoadScript.unsupported) {
            stop()
            onUnsupported()
            return
        }
        guard let sample = ServerLoadSample.parse(block) else { return }
        let load = sample.load(since: previous)
        previous = sample
        onLoad(load)
    }

    /// Collects output and hands back each complete block. The reads come on
    /// a background queue and may cut a block anywhere.
    private final class BlockSplitter: @unchecked Sendable {
        private var buffer = ""
        private let lock = NSLock()

        func append(_ data: Data) -> [String] {
            lock.withLock {
                buffer += String(decoding: data, as: UTF8.self)
                var blocks: [String] = []
                while let end = buffer.range(of: ServerLoadScript.blockEnd + "\n")
                        ?? buffer.range(of: ServerLoadScript.unsupported) {
                    blocks.append(String(buffer[..<end.upperBound]))
                    buffer.removeSubrange(..<end.upperBound)
                }
                return blocks
            }
        }
    }
}
