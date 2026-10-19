import SwiftUI

/// A session's tunnels, opened from its context menu. They run on a
/// connection of their own, started with "Start Port Forwarding" — never
/// with the session's terminal. An edit reaches running tunnels through
/// "Save & Restart"; stopping and starting a tunnel that is already there
/// goes to the running ssh at once.
struct PortForwardingSheet: View {
    private static let width: CGFloat = 520
    private static let margin: CGFloat = 28

    @Environment(\.theme) private var theme
    @Environment(\.closeForm) private var close
    @Environment(SessionStore.self) private var sessionStore
    @Environment(ConnectionStore.self) private var connectionStore

    var sessionID: String

    @State private var forwards: [PortForward] = []
    @State private var didLoad = false
    /// What "Import from ~/.ssh/config" found, or that it found nothing.
    @State private var importNote: String?
    @State private var isImporting = false

    private var problem: String? {
        for (index, forward) in kept.enumerated() {
            do { _ = try SSHLaunch.forwardArguments(forward, index: index) } catch {
                return String(describing: error)
            }
        }
        return nil
    }

    /// Rows with nothing typed are dropped rather than saved as blanks.
    private var kept: [PortForward] { forwards.filter { !$0.isBlank } }

    private var isForwarding: Bool { connectionStore.isForwarding(sessionID) }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Port forwarding",
                        subtitle: "Tunnels for \(sessionID). They run on a connection of their own, not with the terminal.",
                        horizontalPadding: Self.margin)

            // The bar's lane comes out of the trailing margin, as in
            // `SessionSheet`, so the rows keep their place when it shows.
            ScrollView {
                list
                    .frame(width: Self.width - 2 * Self.margin, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 20)
                    .background(ThinScroller(isDark: theme.isDark, alwaysVisible: true))
            }
            .padding(.leading, Self.margin)
            .padding(.trailing, Self.margin - SlimScroller.lane)
            .frame(maxHeight: .infinity)

            footer
        }
        .frame(width: Self.width, height: 560)
        .background(theme.chrome.color)
        .onAppear(perform: load)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            if forwards.isEmpty {
                InsetNote(text: "No tunnels. Local reaches a port behind the server from this Mac, Remote opens a port on the server that leads back here, SOCKS sends a browser through the server.")
            }

            ForEach(Array(forwards.enumerated()), id: \.element.id) { index, _ in
                forwardRow(index: index, forward: $forwards[index])
                    .padding(.bottom, 6)
            }

            Button {
                forwards.append(PortForward())
            } label: {
                Label("Add port forward", systemImage: "plus")
                    .labelStyle(InlineIconLabelStyle(spacing: 6, iconSize: 11))
            }
            .buttonStyle(DashedButtonStyle(theme: theme, fontSize: 12.5))

            HStack(spacing: 8) {
                Button("Import from ~/.ssh/config", action: importFromConfig)
                    .buttonStyle(.plain)
                    .font(SBFont.ui(12))
                    .foregroundStyle(theme.accent.color)
                    .disabled(isImporting)
                if let importNote {
                    Text(importNote)
                        .font(SBFont.ui(12))
                        .foregroundStyle(theme.textMuted.color)
                }
            }
            .padding(.top, 2)
        }
    }

    /// Laid out like a jump host: a numbered header with the kind and the
    /// remove button, then where it listens and where it leads.
    private func forwardRow(index: Int, forward: Binding<PortForward>) -> some View {
        let kind = forward.wrappedValue.kind
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("\(index + 1)")
                    .font(SBFont.ui(11.5, .semibold))
                    .foregroundStyle(theme.text.color)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(theme.selected.color))
                SegmentedPicker(options: PortForward.Kind.allCases,
                                selection: forward.kind,
                                label: \.label,
                                title: "Kind of port forward \(index + 1)",
                                height: 28, fontSize: 12.5,
                                segmentCornerRadius: 6, cornerRadius: 9)
                Button {
                    let id = forward.wrappedValue.id
                    forwards.removeAll { $0.id == id }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.textSecondary.color)
                }
                .buttonStyle(IconButtonStyle(theme: theme, size: CGSize(width: 28, height: 28),
                                             cornerRadius: 8, bordered: true, borderColor: theme.border))
                .accessibilityLabel("Remove port forward \(index + 1)")
            }

            liveState(forward.wrappedValue, index: index)

            HStack(alignment: .bottom, spacing: 12) {
                FormField(label: "Listen on \(kind.listenSide)") {
                    SBTextField(text: forward.bindAddress, placeholder: "localhost",
                                font: SBFont.mono(13))
                }
                .accessibilityLabel("Listen address for port forward \(index + 1)")
                FormField(label: "Port") {
                    SBTextField(text: portBinding(forward, \.listenPort),
                                placeholder: kind == .dynamic ? "1080" : "8080",
                                font: SBFont.mono(13))
                }
                .frame(width: 84)
                .accessibilityLabel("Listen port for port forward \(index + 1)")
            }

            if kind != .dynamic {
                HStack(alignment: .bottom, spacing: 12) {
                    FormField(label: "Destination, as seen from \(kind.destinationSide)") {
                        SBTextField(text: forward.destinationHost, placeholder: "localhost",
                                    font: SBFont.mono(13))
                    }
                    .accessibilityLabel("Destination host for port forward \(index + 1)")
                    FormField(label: "Port") {
                        SBTextField(text: portBinding(forward, \.destinationPort),
                                    placeholder: "80", font: SBFont.mono(13))
                    }
                    .frame(width: 84)
                    .accessibilityLabel("Destination port for port forward \(index + 1)")
                }
            }
        }
        .padding(.vertical, 6)
    }

    /// The tunnel while port forwarding is on: its state, Stop / Start right
    /// after it, and a failure's reason on the line below. Nothing while
    /// port forwarding is off.
    @ViewBuilder
    private func liveState(_ forward: PortForward, index: Int) -> some View {
        if connectionStore.isForwarding(sessionID) {
            Group {
                if let state = liveStateOf(forward) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 10) {
                            // A fixed width, so the button stays put as the
                            // state changes.
                            ForwardStateLabel(state: state, showsReason: false)
                                .frame(width: Self.stateWidth, alignment: .leading)
                            let running = state == .running || state == .opening
                            Button {
                                connectionStore.setForward(forward.id, of: sessionID, running: !running)
                            } label: {
                                Label(running ? "Stop" : "Start", systemImage: running ? "stop.fill" : "play.fill")
                                    .labelStyle(InlineIconLabelStyle(spacing: 6, iconSize: 10))
                                    .frame(width: Self.liveButtonWidth)
                            }
                            .buttonStyle(SecondaryButtonStyle(theme: theme, height: 30, horizontalPadding: 0,
                                                              fontSize: 13, filled: true))
                            .accessibilityLabel("\(running ? "Stop" : "Start") port forward \(index + 1)")
                            if state == .running, let url = forward.browserURL {
                                Button {
                                    NSWorkspace.shared.open(url)
                                } label: {
                                    Label("Open in Browser", systemImage: "arrow.up.right.square")
                                        .labelStyle(InlineIconLabelStyle(spacing: 6, iconSize: 11))
                                }
                                .buttonStyle(SecondaryButtonStyle(theme: theme, height: 30, horizontalPadding: 12,
                                                                  fontSize: 13, filled: true))
                                .help(url.absoluteString)
                            }
                            Spacer(minLength: 0)
                        }
                        if case .failed(let reason) = state {
                            Text(reason)
                                .font(SBFont.ui(12))
                                .foregroundStyle(theme.ansiRed.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    Text("Changed since port forwarding started: applies on restart")
                        .font(SBFont.ui(12))
                        .foregroundStyle(theme.textMuted.color)
                }
            }
            .padding(.leading, 30)
        }
    }

    /// Wide enough for "● Opening…", the longest state.
    private static let stateWidth: CGFloat = 96

    /// Wide enough to read as the tunnel's own control, not a chip.
    private static let liveButtonWidth: CGFloat = 104

    /// The tunnel's state, when it is as port forwarding started it — not
    /// edited here or saved since; `nil` otherwise.
    private func liveStateOf(_ forward: PortForward) -> ForwardState? {
        guard forward == saved(forward.id),
              forward == connectionStore.launchedForward(forward.id, of: sessionID) else { return nil }
        return connectionStore.forwardState(forward.id, of: sessionID)
    }

    private func saved(_ id: UUID) -> PortForward? {
        sessionStore.session(sessionID)?.forwards.first { $0.id == id }
    }

    /// Adds the tunnels the user's `~/.ssh/config` gives this host. Termstead
    /// no longer lets ssh open those by itself (`ClearAllForwardings`), so
    /// this is how a session imported earlier gets them back.
    private func importFromConfig() {
        guard let host = sessionStore.session(sessionID)?.host else { return }
        isImporting = true
        Task {
            let found = await Task.detached { SSHConfigImport.forwards(forHost: host) }.value
            isImporting = false
            let fresh = found.filter { candidate in
                !forwards.contains { $0.kind == candidate.kind && $0.listenPort == candidate.listenPort }
            }
            forwards.removeAll(where: \.isBlank)
            forwards += fresh
            importNote = fresh.isEmpty
                ? "~/.ssh/config has no tunnels for \(host) that are not here already."
                : "Added \(fresh.count) from ~/.ssh/config. Save to keep them."
        }
    }

    private func portBinding(_ forward: Binding<PortForward>,
                             _ field: WritableKeyPath<PortForward, Int?>) -> Binding<String> {
        Binding(
            get: { forward.wrappedValue[keyPath: field].map(String.init) ?? "" },
            set: { forward.wrappedValue[keyPath: field] = Int($0.filter(\.isNumber).prefix(5)) }
        )
    }


    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Cancel") { close() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(SecondaryButtonStyle(theme: theme, height: 36,
                                                  horizontalPadding: 16, fontSize: 13.5))
            if let problem {
                Text(problem)
                    .font(SBFont.ui(12))
                    .foregroundStyle(theme.ansiRed.color)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Save") { save(thenStart: false) }
                .buttonStyle(SecondaryButtonStyle(theme: theme, height: 36,
                                                  horizontalPadding: 16, fontSize: 13.5, filled: true))
                .disabled(problem != nil)
            Button(isForwarding ? "Save & Restart" : "Save & Start") { save(thenStart: true) }
                .buttonStyle(PrimaryButtonStyle(theme: theme, height: 36,
                                                horizontalPadding: 18, fontSize: 13.5))
                .disabled(problem != nil || kept.isEmpty)
        }
        .padding(.horizontal, Self.margin)
        .padding(.top, 16)
        .padding(.bottom, 22)
        .overlay(alignment: .top) { Divider1(theme.border) }
    }

    // MARK: - Loading and saving

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        forwards = sessionStore.session(sessionID)?.forwards ?? []
        if forwards.isEmpty { forwards = [PortForward()] }
    }

    /// "Save & Start" starts port forwarding; "Save & Restart" starts it
    /// again with what was just saved.
    private func save(thenStart: Bool) {
        guard problem == nil, var session = sessionStore.session(sessionID) else { return }
        session.forwards = kept
        // No parent: the session stays where it is in its group.
        sessionStore.applySessionEdits(originalID: sessionID, updated: session, parentID: nil)
        close()
        guard thenStart else { return }
        connectionStore.stopTunnels(sessionID: sessionID)
        connectionStore.startTunnels(sessionID: sessionID, in: sessionStore)
    }
}

/// A tunnel's state as the forms and the status bar show it.
struct ForwardStateLabel: View {
    @Environment(\.theme) private var theme
    var state: ForwardState
    /// A failure's reason beside it; the status bar's list puts it on a
    /// line of its own instead, to keep the button next to the state.
    var showsReason = true

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(color: color.color, size: 7)
            Text(title)
                .font(SBFont.ui(12.5, .medium))
                .foregroundStyle((state == .running ? theme.text : theme.textMuted).color)
            if showsReason, case .failed(let reason) = state {
                Text(reason)
                    .font(SBFont.ui(12))
                    .foregroundStyle(theme.ansiRed.color)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(reason)
            }
        }
    }

    private var title: String {
        switch state {
        case .opening: "Opening…"
        case .running: "Running"
        case .stopped: "Stopped"
        case .failed: showsReason ? "Failed:" : "Failed"
        }
    }

    private var color: RGB {
        switch state {
        case .running: theme.accent
        case .opening: theme.ansiYellow
        case .stopped: theme.textFaint
        case .failed: theme.ansiRed
        }
    }
}
