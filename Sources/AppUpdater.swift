import Sparkle

/// Updates outside the App Store, through Sparkle: an automatic check a day
/// against the appcast published with each release (`SUFeedURL` in
/// Info.plist), and "Check for Updates…" in the app menu. Sparkle verifies the
/// download against `SUPublicEDKey` before it replaces anything.
///
/// Never started in a developer's launch (`DevelopmentLaunch`): a Debug build,
/// a test run or an `-sb-*` flag would otherwise offer to replace the build
/// under development with the published one.
@MainActor
final class AppUpdater {
    private let controller: SPUStandardUpdaterController
    let isActive: Bool

    init(starts: Bool = !DevelopmentLaunch.isActive) {
        isActive = starts
        controller = SPUStandardUpdaterController(startingUpdater: starts,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
