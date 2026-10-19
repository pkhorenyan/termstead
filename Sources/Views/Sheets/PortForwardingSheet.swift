import SwiftUI

/// A session's tunnels, opened from its context menu. They start with the
/// session's terminal (`SSHLaunchPlan.forwards`), so an edit reaches a live
/// tab only through "Save & reconnect"; stopping and starting a tunnel that
/// is already there goes to the running ssh at once.
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
    /// Tunnels with a stop or start on its way to ssh.
    @State private var busy: Set<UUID> = []
    /// What ssh said when it refused to stop or start a tunnel.
    @State private var refusals: [UUID: String] = [:]

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

    private var isLive: Bool { connectionStore.isLive(sessionID) }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Port forwarding",
                        subtitle: "Tunnels for \(sessionID), opened with its terminal.",
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

    /// Whether the tunnel is open on the session's live connection, and the
    /// button that stops or starts it there — as MobaXterm's tunnels have.
    /// Nothing while the session is not connected.
    @ViewBuilder
    private func liveState(_ forward: PortForward, index: Int) -> some View {
        if let holder = connectionStore.forwardHolder(of: sessionID) {
            HStack(spacing: 8) {
                if !holder.carriesForward(forward.id) || forward != saved(forward.id) {
                    Text("Changed since the session connected: applies on reconnect")
                        .font(SBFont.ui(12))
                        .foregroundStyle(theme.textMuted.color)
                } else {
                    let running = connectionStore.isForwardRunning(forward.id, of: sessionID)
                    StatusDot(color: (running ? theme.accent : theme.textFaint).color, size: 7)
                    Text(running ? "Running" : "Stopped")
                        .font(SBFont.ui(12.5, .medium))
                        .foregroundStyle((running ? theme.text : theme.textMuted).color)
                    if let refusal = refusals[forward.id] {
                        Text(refusal)
                            .font(SBFont.ui(12))
                            .foregroundStyle(theme.ansiRed.color)
                            .lineLimit(2)
                            .help(refusal)
                    }
                    Spacer(minLength: 0)
                    Button {
                        toggle(forward.id, running: !running)
                    } label: {
                        Label(running ? "Stop" : "Start",
                              systemImage: running ? "stop.fill" : "play.fill")
                            .labelStyle(InlineIconLabelStyle(spacing: 5, iconSize: 9))
                    }
                    .buttonStyle(SecondaryButtonStyle(theme: theme, height: 26,
                                                      horizontalPadding: 10, fontSize: 12, filled: true))
                    .disabled(busy.contains(forward.id))
                    .accessibilityLabel("\(running ? "Stop" : "Start") port forward \(index + 1)")
                }
            }
            .padding(.leading, 30)
            .frame(minHeight: 26)
        }
    }

    private func saved(_ id: UUID) -> PortForward? {
        sessionStore.session(sessionID)?.forwards.first { $0.id == id }
    }

    private func toggle(_ id: UUID, running: Bool) {
        busy.insert(id)
        refusals[id] = nil
        Task {
            let problem = await connectionStore.setForward(id, of: sessionID, running: running)
            busy.remove(id)
            refusals[id] = problem
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
            if isLive {
                Button("Save") { save(thenReconnect: false) }
                    .buttonStyle(SecondaryButtonStyle(theme: theme, height: 36,
                                                      horizontalPadding: 16, fontSize: 13.5, filled: true))
                    .disabled(problem != nil)
                Button("Save & reconnect") { save(thenReconnect: true) }
                    .buttonStyle(PrimaryButtonStyle(theme: theme, height: 36,
                                                    horizontalPadding: 18, fontSize: 13.5))
                    .disabled(problem != nil)
            } else {
                Button("Save") { save(thenReconnect: false) }
                    .buttonStyle(PrimaryButtonStyle(theme: theme, height: 36,
                                                    horizontalPadding: 18, fontSize: 13.5))
                    .disabled(problem != nil)
            }
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

    private func save(thenReconnect: Bool) {
        guard problem == nil, var session = sessionStore.session(sessionID) else { return }
        session.forwards = kept
        // No parent: the session stays where it is in its group.
        sessionStore.applySessionEdits(originalID: sessionID, updated: session, parentID: nil)
        close()
        if thenReconnect { connectionStore.reconnect(sessionID: sessionID, in: sessionStore) }
    }
}
