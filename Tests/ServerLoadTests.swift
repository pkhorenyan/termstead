import Foundation
import Testing
@testable import Termstead

@MainActor
struct ServerLoadTests {
    /// One block as `ServerLoadScript` prints it on a Debian server.
    private func block(cpu: String = "cpu  4705 356 584 3699 23 23 0 0 0 0",
                       received: UInt64 = 98_765, sent: UInt64 = 4_321, uptime: Double = 12_345.67,
                       memAvailable: Bool = true) -> String {
        """
        @stat
        \(cpu)
        @mem
        MemTotal: 4026532 kB
        MemFree: 1048576 kB
        \(memAvailable ? "MemAvailable: 2013266 kB" : "")
        Buffers: 102400 kB
        Cached: 512000 kB
        @net
        Inter-|   Receive                                                |  Transmit
         face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
            lo:  555555     100    0    0    0     0          0         0   555555     100    0    0    0     0       0          0
          eth0: \(received)     812    0    0    0     0          0         0 \(sent)     640    0    0    0     0       0          0
        @df
        /dev/root 40581564 18265400 22299780 46% /
        @up
        \(uptime) 23456.78
        0.52 0.40 0.31 1/123 4567
        @end
        """
    }

    @Test func oneBlockGivesMemoryDiskAndLoad() throws {
        let sample = try #require(ServerLoadSample.parse(block()))
        #expect(sample.memoryTotal == 4_026_532 * 1024)
        #expect(sample.memoryAvailable == 2_013_266 * 1024)
        #expect(sample.received == 98_765 && sample.sent == 4_321, "loopback is left out")
        #expect(sample.diskPercent == 46)
        #expect(sample.diskTotal == (18_265_400 + 22_299_780) * 1024)
        #expect(sample.loadAverage == [0.52, 0.40, 0.31])
        #expect(sample.uptime == 12_345.67)

        let load = sample.load(since: nil)
        #expect(load.cpu == nil, "a share needs two samples")
        #expect(load.receiveRate == nil)
        #expect(load.memoryUsed == (4_026_532 - 2_013_266) * 1024)
    }

    @Test func twoBlocksGiveTheCPUShareAndTheRates() throws {
        let first = try #require(ServerLoadSample.parse(block()))
        // 100 more jiffies, 25 of them idle or waiting: 75% busy.
        let second = try #require(ServerLoadSample.parse(block(cpu: "cpu  4775 356 589 3719 28 23 0 0 0 0",
                                                               received: 98_765 + 3_000_000, sent: 4_321 + 6_000,
                                                               uptime: 12_348.67)))
        let load = second.load(since: first)
        #expect(load.cpu == 0.75)
        #expect(load.receiveRate == 1_000_000)
        #expect(load.sendRate == 2_000)
    }

    @Test func countersThatGoBackGiveNoRate() throws {
        let first = try #require(ServerLoadSample.parse(block(received: 5_000_000)))
        let second = try #require(ServerLoadSample.parse(block(received: 1_000, uptime: 12_348.67)))
        #expect(second.load(since: first).receiveRate == nil)
    }

    /// Before Linux 3.14 there is no MemAvailable.
    @Test func olderKernelsCountFreePlusCaches() throws {
        let sample = try #require(ServerLoadSample.parse(block(memAvailable: false)))
        #expect(sample.memoryAvailable == (1_048_576 + 102_400 + 512_000) * 1024)
    }

    @Test func aBlockWithoutCPUOrMemoryIsNothing() {
        #expect(ServerLoadSample.parse("@stat\n@mem\n@end") == nil)
        #expect(ServerLoadSample.parse("garbage") == nil)
    }

    @Test func theFiguresReadShort() {
        #expect(ServerLoad.percent(0.124) == "12%")
        #expect(ServerLoad.gigabytes(1_503_238_553) == "1.4")
        #expect(ServerLoad.gigabytes(34_359_738_368) == "32")
        #expect(ServerLoad.rate(nil) == "–")
        #expect(ServerLoad.rate(512) == "512 B/s")
        #expect(ServerLoad.rate(48_500) == "48 KB/s")
        #expect(ServerLoad.rate(1_250_000) == "1.2 MB/s" || ServerLoad.rate(1_250_000) == "1.3 MB/s")
        #expect(ServerLoad.duration(3 * 86_400 + 4 * 3_600 + 60) == "3 d 4 h")
        #expect(ServerLoad.duration(2 * 3_600 + 5 * 60) == "2 h 5 min")
    }

    @Test func aFreshWatchKeepsTheLastShareUntilItHasItsOwn() throws {
        let earlier = try #require(ServerLoadSample.parse(block())).load(since: nil)
        var shown = earlier
        shown.cpu = 0.4
        shown.receiveRate = 10
        let fresh = earlier.filling(from: shown)
        #expect(fresh.cpu == 0.4 && fresh.receiveRate == 10)
    }

    @Test func onlyTheTabInFrontIsWatched() {
        let store = ConnectionStore()
        for name in ["a", "b", "c"] {
            store.add(Connection(sessionID: nil, title: name, address: name, keyDescription: ""))
        }
        #expect(store.connections.allSatisfy { !$0.watchesLoad }, "off until Settings turns it on")
        store.watchesServerLoad = true
        #expect(store.connections.map(\.watchesLoad) == [false, false, true])
        store.activeID = store.connections[0].id
        #expect(store.connections.map(\.watchesLoad) == [true, false, false])
        store.close(store.connections[0].id)
        #expect(store.connections.map(\.watchesLoad) == [true, false])
        store.watchesServerLoad = false
        #expect(store.connections.allSatisfy { !$0.watchesLoad })
    }
}
