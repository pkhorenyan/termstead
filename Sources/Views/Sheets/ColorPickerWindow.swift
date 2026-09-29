import AppKit
import SwiftUI

/// A color as hue, saturation and brightness, each 0…1 — the space the
/// picker's square and hue strip work in.
struct HSBColor: Equatable {
    var hue: Double
    var saturation: Double
    var brightness: Double

    init(hue: Double, saturation: Double, brightness: Double) {
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
    }

    init(_ rgb: RGB) {
        let color = rgb.nsColor.usingColorSpace(.sRGB) ?? rgb.nsColor
        hue = Double(color.hueComponent)
        saturation = Double(color.saturationComponent)
        brightness = Double(color.brightnessComponent)
    }

    var rgb: RGB {
        let color = NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
            .usingColorSpace(.sRGB)!
        return RGB(r: Double(color.redComponent), g: Double(color.greenComponent), b: Double(color.blueComponent))
    }
}

/// The "Custom color" dialog, laid out like Photoshop's Color Picker: a big
/// saturation × brightness square, the hue as a vertical strip beside it, the
/// new color over the current one, the values as H S B, R G B and hex, and OK
/// and Cancel. Nothing changes until OK.
///
/// It opens over a form that is itself app-modal, so it runs a modal session
/// of its own nested inside the form's — the form is blocked while it is up,
/// as Photoshop's dialog behind the picker is. `AppModal` cannot do this: it
/// waits for the default run-loop mode, which a modal session never returns
/// to, so this starts from the modal-panel mode instead.
@MainActor
enum ColorPickerWindow {
    private static var window: NSPanel?

    static func present(start: RGB, over parent: NSWindow?, theme: Theme,
                        onPick: @escaping (RGB) -> Void) {
        guard window == nil else { return }
        let panel = PickerPanel(contentRect: .zero,
                                styleMask: [.titled, .closable, .fullSizeContentView],
                                backing: .buffered, defer: false)
        let finish: (RGB?) -> Void = { picked in
            close()
            if let picked { onPick(picked) }
        }
        let content = ColorPickerView(start: start, onOK: { finish($0) }, onCancel: { finish(nil) })
            .environment(\.theme, theme)
        let controller = NSHostingController(rootView: content)
        panel.contentViewController = controller
        // The system's own centred title, as on a macOS dialog. Drawing one in
        // SwiftUI would sit below the titlebar, or not paint at all at the
        // titlebar's height (see CLAUDE.md, the ignored safe-area inset).
        panel.title = "Color Picker"
        panel.titleVisibility = .visible
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.worksWhenModal = true
        panel.level = .modalPanel
        panel.appearance = theme.appearance
        panel.backgroundColor = theme.chrome.nsColor
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.onCancel = { finish(nil) }
        panel.setContentSize(controller.view.fittingSize)

        // Centred on the form it belongs to, a little high, like a dialog.
        if let parent {
            let frame = panel.frame
            let origin = NSPoint(x: parent.frame.midX - frame.width / 2,
                                 y: parent.frame.midY - frame.height / 2 + 40)
            panel.setFrameOrigin(origin)
            parent.addChildWindow(panel, ordered: .above)
        } else {
            panel.center()
        }
        window = panel
        panel.makeKeyAndOrderFront(nil)

        RunLoop.main.perform(inModes: [.modalPanel, .default]) { [weak panel] in
            MainActor.assumeIsolated {
                guard let panel, panel.isVisible, window === panel else { return }
                NSApp.runModal(for: panel)
            }
        }
    }

    static func close() {
        guard let panel = window else { return }
        window = nil
        if NSApp.modalWindow === panel {
            NSApp.stopModal()
            // As in `AppModal.end`: a stop only lands after the next event.
            if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                             timestamp: 0, windowNumber: 0, context: nil,
                                             subtype: 0, data1: 0, data2: 0) {
                NSApp.postEvent(wake, atStart: true)
            }
        }
        panel.parent?.removeChildWindow(panel)
        panel.close()
    }

    static var isOpen: Bool { window != nil }

    private final class PickerPanel: NSPanel {
        var onCancel: (() -> Void)?
        override func cancelOperation(_ sender: Any?) { onCancel?() }
        override var canBecomeKey: Bool { true }
        override func close() {
            // The close button goes through here too; treat it as Cancel.
            if ColorPickerWindow.window === self {
                onCancel?()
            } else {
                super.close()
            }
        }
    }
}

struct ColorPickerView: View {
    @Environment(\.theme) private var theme
    let start: RGB
    var onOK: (RGB) -> Void
    var onCancel: () -> Void

    @State private var hsb: HSBColor
    @State private var hexText: String

    private static let squareSide: CGFloat = 256
    private static let stripWidth: CGFloat = 20

    init(start: RGB, onOK: @escaping (RGB) -> Void, onCancel: @escaping () -> Void) {
        self.start = start
        self.onOK = onOK
        self.onCancel = onCancel
        _hsb = State(initialValue: HSBColor(start))
        _hexText = State(initialValue: String(start.hex.dropFirst()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            HStack(alignment: .top, spacing: 16) {
                square
                hueStrip
                VStack(alignment: .leading, spacing: 14) {
                    comparison
                    fields
                }
                .frame(width: 150)
                VStack(spacing: 8) {
                    Button { onOK(hsb.rgb) } label: { Text("OK").frame(maxWidth: .infinity) }
                        .buttonStyle(PrimaryButtonStyle(theme: theme, height: 30))
                        .keyboardShortcut(.defaultAction)
                    Button(action: onCancel) { Text("Cancel").frame(maxWidth: .infinity) }
                        .buttonStyle(SecondaryButtonStyle(theme: theme, height: 30))
                        .keyboardShortcut(.cancelAction)
                }
                .frame(width: 88)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .background(theme.chrome.color)
    }

    // MARK: - Square and strip

    /// Saturation left to right, brightness bottom to top: white fading in
    /// from the left over the pure hue, and black rising from the bottom.
    private var square: some View {
        let side = Self.squareSide
        return ZStack {
            Rectangle().fill(HSBColor(hue: hsb.hue, saturation: 1, brightness: 1).rgb.color)
            LinearGradient(colors: [RGB(0xFFFFFF).color, RGB(0xFFFFFF).color(0)],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [RGB(0x000000).color(0), RGB(0x000000).color],
                           startPoint: .top, endPoint: .bottom)
            Circle()
                .strokeBorder(hsb.brightness > 0.55 && hsb.saturation < 0.45
                              ? RGB(0x000000).color : RGB(0xFFFFFF).color, lineWidth: 1.5)
                .frame(width: 12, height: 12)
                .position(x: hsb.saturation * side, y: (1 - hsb.brightness) * side)
        }
        .frame(width: side, height: side)
        .clipped()
        .overlay(Rectangle().strokeBorder(theme.border.color, lineWidth: 1))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            hsb.saturation = clamp(value.location.x / side)
            hsb.brightness = 1 - clamp(value.location.y / side)
            syncHex()
        })
        .accessibilityLabel("Saturation and brightness")
    }

    /// Red at the top and bottom, through the spectrum, as in Photoshop.
    private var hueStrip: some View {
        let side = Self.squareSide
        return ZStack(alignment: .top) {
            LinearGradient(colors: stride(from: 1.0, through: 0.0, by: -1.0 / 6).map {
                               HSBColor(hue: $0, saturation: 1, brightness: 1).rgb.color
                           },
                           startPoint: .top, endPoint: .bottom)
                .overlay(Rectangle().strokeBorder(theme.border.color, lineWidth: 1))
            // Photoshop's pair of arrows, as one bar across the strip.
            RoundedRectangle(cornerRadius: 1.5)
                .strokeBorder(RGB(0xFFFFFF).color, lineWidth: 2)
                .background(RoundedRectangle(cornerRadius: 1.5).strokeBorder(RGB(0x000000).color(0.5), lineWidth: 3))
                .frame(width: Self.stripWidth + 6, height: 6)
                .offset(y: (1 - hsb.hue) * side - 3)
        }
        .frame(width: Self.stripWidth, height: side)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            hsb.hue = 1 - clamp(value.location.y / side)
            syncHex()
        })
        .accessibilityLabel("Hue")
    }

    // MARK: - New and current

    private var comparison: some View {
        VStack(alignment: .center, spacing: 4) {
            Text("new")
                .font(SBFont.ui(11))
                .foregroundStyle(theme.textMuted.color)
            VStack(spacing: 0) {
                Rectangle().fill(hsb.rgb.color).frame(height: 34)
                // Photoshop's "current" swatch puts the old color back on click.
                Rectangle().fill(start.color).frame(height: 34)
                    .onTapGesture {
                        hsb = HSBColor(start)
                        syncHex()
                    }
                    .help("Back to the current color")
            }
            .frame(width: 70)
            .overlay(Rectangle().strokeBorder(theme.border.color, lineWidth: 1))
            Text("current")
                .font(SBFont.ui(11))
                .foregroundStyle(theme.textMuted.color)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Values

    private var fields: some View {
        let rgb = hsb.rgb
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 6) {
                    number("H", value: Int((hsb.hue * 360).rounded()), unit: "°", range: 0...360) {
                        hsb.hue = Double($0) / 360
                    }
                    number("S", value: Int((hsb.saturation * 100).rounded()), unit: "%", range: 0...100) {
                        hsb.saturation = Double($0) / 100
                    }
                    number("B", value: Int((hsb.brightness * 100).rounded()), unit: "%", range: 0...100) {
                        hsb.brightness = Double($0) / 100
                    }
                }
                VStack(spacing: 6) {
                    number("R", value: Int((rgb.r * 255).rounded()), unit: "", range: 0...255) {
                        setRGB(RGB(r: Double($0) / 255, g: rgb.g, b: rgb.b))
                    }
                    number("G", value: Int((rgb.g * 255).rounded()), unit: "", range: 0...255) {
                        setRGB(RGB(r: rgb.r, g: Double($0) / 255, b: rgb.b))
                    }
                    number("B", value: Int((rgb.b * 255).rounded()), unit: "", range: 0...255) {
                        setRGB(RGB(r: rgb.r, g: rgb.g, b: Double($0) / 255))
                    }
                }
            }
            HStack(spacing: 6) {
                Text("#")
                    .font(SBFont.mono(12.5))
                    .foregroundStyle(theme.textSecondary.color)
                    .frame(width: 12, alignment: .trailing)
                TextField("", text: $hexText)
                    .textFieldStyle(.plain)
                    .font(SBFont.mono(12.5))
                    .foregroundStyle(theme.text.color)
                    .padding(.horizontal, 6)
                    .frame(height: 24)
                    .background(FieldBackground(theme: theme, cornerRadius: 5))
                    .onSubmit(applyHex)
                    .onChange(of: hexText) { if hexText.count == 6 { applyHex() } }
                    .accessibilityLabel("Hex color")
            }
            .padding(.top, 4)
        }
    }

    /// One labelled value, committed on Return or when focus leaves it.
    private func number(_ label: String, value: Int, unit: String, range: ClosedRange<Int>,
                        set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(SBFont.ui(12))
                .foregroundStyle(theme.textSecondary.color)
                .frame(width: 12, alignment: .trailing)
            TextField("", value: Binding(get: { value },
                                         set: { set(min(range.upperBound, max(range.lowerBound, $0))); syncHex() }),
                      format: .number.grouping(.never))
                .textFieldStyle(.plain)
                .font(SBFont.mono(12.5))
                .foregroundStyle(theme.text.color)
                .multilineTextAlignment(.trailing)
                .padding(.horizontal, 6)
                .frame(width: 42, height: 24)
                .background(FieldBackground(theme: theme, cornerRadius: 5))
                .accessibilityLabel(label)
            Text(unit)
                .font(SBFont.ui(11.5))
                .foregroundStyle(theme.textMuted.color)
                .frame(width: 10, alignment: .leading)
        }
    }

    private func setRGB(_ rgb: RGB) {
        var next = HSBColor(rgb)
        // A grey has no hue of its own; keep the one the strip shows.
        if next.saturation == 0 || next.brightness == 0 { next.hue = hsb.hue }
        hsb = next
    }

    private func syncHex() { hexText = String(hsb.rgb.hex.dropFirst()) }

    private func applyHex() {
        guard let rgb = RGB(hex: hexText.trimmingCharacters(in: .whitespaces)) else { return }
        setRGB(rgb)
    }

    private func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
}
