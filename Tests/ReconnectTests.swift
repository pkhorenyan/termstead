import Testing
@testable import Termstead

/// When a tab connects again by itself — see `Connection.shouldReconnect`.
struct ReconnectTests {
    private func reconnects(_ code: Int32?, loggedIn: Bool = true, attempts: Int = 0,
                            local: Bool = false, tunnel: Bool = false, desktop: Bool = false) -> Bool {
        Connection.shouldReconnect(exitCode: code, didLogIn: loggedIn, attempts: attempts,
                                   isLocalShell: local, isTunnelOnly: tunnel, isDesktop: desktop)
    }

    @Test func aLostConnectionAfterLoginReconnects() {
        #expect(reconnects(255))
    }

    @Test func anExitIsLeftAlone() {
        #expect(!reconnects(0))
        #expect(!reconnects(1))
        #expect(!reconnects(130))
        #expect(!reconnects(nil))
    }

    /// A wrong password would be tried for ever.
    @Test func aLoginThatNeverWorkedIsNotRetried() {
        #expect(!reconnects(255, loggedIn: false))
    }

    /// A server still down after a drop: tried again, up to the limit.
    @Test func aFailedAttemptIsRetriedUpToTheLimit() {
        #expect(reconnects(255, loggedIn: false, attempts: 1))
        #expect(!reconnects(255, loggedIn: false, attempts: Connection.maxReconnectAttempts))
    }

    @Test func onlyServerTabsReconnect() {
        #expect(!reconnects(255, local: true))
        #expect(!reconnects(255, tunnel: true))
        #expect(!reconnects(255, desktop: true))
    }
}
