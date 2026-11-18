import AppKit
import IOSurface
import Testing
@testable import Termstead

@MainActor struct VNCOptionsTests {
    @Test func legacyOptionsKeepClipboardAndTransportPolicy() throws {
        let options = try JSONDecoder().decode(VNCOptions.self, from: Data(#"{"clipboard":false,"viewOnly":true}"#.utf8))
        #expect(!options.clipboard && options.viewOnly)
        #expect(options.sendClipboard && options.receiveClipboard)
        #expect(options.security == .standard && options.keyboard == .linux)
        #expect(options.zoom == 0 && options.autoReconnect)
        #expect(options.fileSSHSessionID == nil)
        #expect(options.fileAccess == nil)
        var changed = options
        changed.security = .tls; changed.keyboard = .macOS; changed.quality = .fast
        changed.zoom = 175; changed.receiveClipboard = false; changed.autoReconnect = false
        changed.fileSSHSessionID = UUID()
        #expect(try JSONDecoder().decode(VNCOptions.self, from: JSONEncoder().encode(changed)) == changed)
    }
    @Test func fixedScaleCanScrollOneAxisWithoutStretchingTheOther() throws {
        let pixels = CGSize(width: 1920, height: 1080)
        let viewport = CGSize(width: 800, height: 1200)
        #expect(VNCViewport.documentSize(pixels: pixels, viewport: viewport, zoom: 0) == viewport)
        #expect(VNCViewport.documentSize(pixels: pixels, viewport: viewport, zoom: 100) == CGSize(width: 1920, height: 1200))
        let desktop = VNCDesktop()
        let surface = try #require(IOSurface(properties: [.width: 1920, .height: 1080, .bytesPerElement: 4]))
        desktop.setZoom(100)
        desktop.view.setFrameSize(CGSize(width: 1920, height: 1200))
        desktop.view.show(surface)
        #expect(desktop.view.shownRect == CGRect(x: 0, y: 60, width: 1920, height: 1080))
        desktop.setZoom(50)
        desktop.view.setFrameSize(viewport)
        #expect(desktop.view.shownRect.size == CGSize(width: 960, height: 540))
    }

    @Test func sampleVNCConfiguresFileAccessInsideTheSession() throws {
        let store = SessionStore.sample()
        #expect(store.session("lab-vnc")?.vnc.fileAccess?.port == 2203)
        #expect(store.session("lab-vnc-via-bastion")?.vnc.fileAccess?.host == "vnc")
        #expect(store.session("lab-vnc")?.vnc.fileSSHSessionID == nil)
    }

    @Test func inlineFileAccessUsesVNCIdentityAndJumpRoute() throws {
        let store = SessionStore.sample()
        var session = try #require(store.session("lab-vnc-via-bastion"))
        var access = VNCFileAccess()
        access.host = "vnc"
        access.user = "lab"
        access.auth = .password
        session.vnc.fileAccess = access
        session.vnc.fileSSHSessionID = nil
        session.jumps.append(JumpHost(host: "literal.example"))
        let plan = try ConnectionStore.vncFileAccessPlan(for: session, in: store)
        #expect(plan.target.host == "vnc")
        #expect(plan.target.user == "lab")
        #expect(plan.target.port == 22)
        #expect(plan.target.passwordAccount == SSHLaunch.vncFilePasswordAccount(session.persistentID!))
        #expect(!plan.hops.isEmpty)
        #expect(plan.hops.last?.auth == .automatic)
    }
}
