import AppKit

/// The tab owns its scroll view as well as its framebuffer view. Moving a tab
/// between panes preserves both its zoom and its scroll position.
final class VNCViewport: NSScrollView {
    let desktopView: VNCDesktopView
    var zoom = 0 { didSet { resizeDesktop() } }
    var pixels = CGSize.zero { didSet { resizeDesktop() } }

    init(view: VNCDesktopView) {
        desktopView = view
        super.init(frame: .zero)
        drawsBackground = true
        backgroundColor = .black
        borderType = .noBorder
        scrollerStyle = .overlay
        documentView = view
        contentView.postsBoundsChangedNotifications = true
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override func layout() { super.layout(); resizeDesktop() }

    private func resizeDesktop() {
        let viewport = contentView.bounds.size
        let scaled = Self.documentSize(pixels: pixels, viewport: viewport, zoom: zoom)
        if hasVerticalScroller != (zoom != 0) { hasVerticalScroller = zoom != 0 }
        if hasHorizontalScroller != (zoom != 0) { hasHorizontalScroller = zoom != 0 }
        if desktopView.frame.size != scaled { desktopView.setFrameSize(scaled) }
    }
    static func documentSize(pixels: CGSize, viewport: CGSize, zoom: Int) -> CGSize {
        guard zoom > 0 else { return viewport }
        let factor = CGFloat(min(max(zoom, 25), 400)) / 100
        return CGSize(width: max(viewport.width, pixels.width * factor),
                      height: max(viewport.height, pixels.height * factor))
    }
}
