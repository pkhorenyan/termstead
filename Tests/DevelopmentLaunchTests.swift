import Testing
@testable import Termstead

/// The Debug menu can clear every session without asking, so a user's launch
/// must never show it; any `-sb-*` flag marks a developer's.
struct DevelopmentLaunchTests {
    @Test func aPlainLaunchIsNotADevelopersOne() {
        #expect(!DevelopmentLaunch.isActive(arguments: [:]))
        #expect(!DevelopmentLaunch.isActive(arguments: ["NSDocumentRevisionsDebugMode": "YES"]))
    }

    @Test func anySbFlagIs() {
        #expect(DevelopmentLaunch.isActive(arguments: ["sb-sample": "YES"]))
        #expect(DevelopmentLaunch.isActive(arguments: ["sb-route": "empty"]))
    }
}
