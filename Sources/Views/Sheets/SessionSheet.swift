import SwiftUI

/// Creates a session, or edits an existing one.
///
/// The reference mockup stacks this form into a single 1170pt column, which
/// cannot fit a sheet on an 800pt window without scrolling. The same fields are
/// laid out in two columns here — connection on the left, authentication and
/// the jump chain on the right — so nothing is hidden or scrolled away.
struct SessionSheet: View {
    enum Mode: Hashable {
        case create(parentGroupID: String?)
        case edit(sessionID: String)
    }

    private static let columnWidth: CGFloat = 330
    /// The fields' width. Their scroll view is a lane wider, for the bar.
    private static let rightColumnWidth: CGFloat = 406
    private static let margin: CGFloat = 28

    @Environment(\.theme) private var theme
    @Environment(\.closeForm) private var close
    @Environment(SessionStore.self) private var sessionStore
    @Environment(ConnectionStore.self) private var connectionStore

    var mode: Mode

    @State private var name = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var user = ""
    @State private var icon: SessionIcon = .server
    @State private var parentID: String?
    @State private var authMode: SessionAuth = .password
    @State private var keyPath = Session.defaultKeyPath
    @State private var password = ""
    @State private var passphrase = ""
    @State private var saveToKeychain = true
    @State private var pinToTop = false
    /// The session's own color: `nil` takes the group's (see `Session.colorID`).
    @State private var colorID: String?
    @State private var jumps: [JumpHost] = []
    /// What was typed into the hops' password fields. Never part of the model:
    /// on Save it goes to the Keychain (see `storeSecrets`) and nowhere else.
    @State private var jumpPasswords: [UUID: String] = [:]
    /// Keychain accounts that already hold something, looked up when the form
    /// opens. Only their existence is read — the secrets never enter the UI.
    @State private var storedAccounts: Set<String> = []
    @State private var didLoad = false
    @State private var isGroupPickerOpen = false

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var editingSessionID: String? {
        if case .edit(let id) = mode { return id }
        return nil
    }

    private var groupOptions: [(id: String, name: String, depth: Int, colorID: String?)] {
        sessionStore.groupOptions()
    }

    private var groupColor: RGB? {
        guard let parentID else { return nil }
        return GroupColor.rgb(for: sessionStore.effectiveColorID(ofGroup: parentID))
    }

    /// What the session will show: its group's color when the group has one,
    /// otherwise its own (`GroupColor.sessionColorID`).
    private var sessionColor: RGB? {
        groupColor ?? GroupColor.rgb(for: colorID)
    }

    private var groupPath: [String] {
        guard let parentID else { return [] }
        return sessionStore.groupPath(parentID)
    }

    /// With no groups at all, saving creates the first one
    /// (`SessionStore.createSession`), and the field says so.
    private var groupName: String { groupPath.last ?? SessionStore.firstGroupName }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: isEditing ? "Session settings" : "New session",
                subtitle: "Saved to the sidebar. Passwords are stored in the macOS Keychain.",
                horizontalPadding: 28
            )

            HStack(alignment: .top, spacing: 28) {
                connectionColumn.frame(width: Self.columnWidth)

                // The jump chain is the only part that grows without bound, so
                // this column scrolls instead of stretching the sheet past the
                // window and taking the footer buttons with it.
                //
                // The bar's lane is taken out of the right margin: the fields
                // keep a fixed width, and the scroll view is one lane wider.
                // With no bar the lane is empty margin, so both sides read 28;
                // with the bar it sits in the lane, and nothing moves.
                ScrollView {
                    authenticationColumn
                        .frame(width: Self.rightColumnWidth, alignment: .leading)
                        // Held to the leading edge: a ScrollView centres content
                        // narrower than itself, which split the lane between
                        // both sides and shifted the column when the bar came.
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(ThinScroller(isDark: theme.isDark, alwaysVisible: true))
                }
                .frame(width: Self.rightColumnWidth + SlimScroller.lane)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.leading, Self.margin)
            .padding(.trailing, Self.margin - SlimScroller.lane)
            .padding(.vertical, 20)

            footer
        }
        .frame(width: 820, height: 648)
        .background(theme.chrome.color)
        .onAppear(perform: load)
    }

    // MARK: - Left column

    private var connectionColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            FormField(label: "Name") {
                SBTextField(text: $name, placeholder: "prod-web-03",
                            font: SBFont.ui(14), focused: !isEditing)
            }

            HStack(alignment: .bottom, spacing: 12) {
                FormField(label: "Host") {
                    SBTextField(text: $host, placeholder: "10.0.1.14", font: SBFont.mono(13))
                }
                FormField(label: "Port") {
                    SBTextField(text: $port, placeholder: "22", font: SBFont.mono(13))
                }
                .frame(width: 84)
            }

            FormField(label: "User") {
                SBTextField(text: $user, placeholder: "deploy", font: SBFont.mono(13))
            }

            VStack(alignment: .leading, spacing: 6) {
                FormLabel("Group")
                groupPicker
            }

            iconPicker
            colorAndPin

            Spacer(minLength: 0)
        }
    }

    /// A button that drops the same parent list the group settings sheet uses.
    /// `Menu` with a custom label collapses it, so this is a plain popover.
    /// With no groups there is nothing to pick — the popover came up as an
    /// empty frame, a lone dot — so the field only names the group to come.
    @ViewBuilder
    private var groupPicker: some View {
        if groupOptions.isEmpty {
            groupField(isPicker: false)
                .accessibilityElement(children: .combine)
        } else {
            groupPickerButton
        }
    }

    private func groupField(isPicker: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: groupColor == nil ? "folder" : "folder.fill")
                .font(.system(size: 11))
                .foregroundStyle((groupColor ?? theme.textMuted).color)
            if groupPath.count > 1 {
                Text(groupPath.dropLast().joined(separator: " / ") + " /")
                    .font(SBFont.ui(14))
                    .foregroundStyle(theme.textMuted.color)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Text(groupName)
                .font(SBFont.ui(14))
                .foregroundStyle(theme.text.color)
                .lineLimit(1)
            Spacer(minLength: 0)
            if isPicker {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.textMuted.color)
            } else {
                Text("new group")
                    .font(SBFont.ui(12))
                    .foregroundStyle(theme.textMuted.color)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(height: 36)
        .frame(maxWidth: .infinity)
        .background(FieldBackground(theme: theme))
        .contentShape(Rectangle())
    }

    private var groupPickerButton: some View {
        Button {
            isGroupPickerOpen.toggle()
        } label: {
            groupField(isPicker: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Group: \(groupName)")
        .popover(isPresented: $isGroupPickerOpen, arrowEdge: .bottom) {
            ScrollView {
                ParentGroupList(options: parentPickerOptions, selection: parentSelection)
                    .padding(10)
                    .background(ThinScroller(isDark: theme.isDark, alwaysVisible: true))
            }
            .frame(width: 260)
            .frame(maxHeight: 280)
            .background(theme.elevated.color)
            .environment(\.theme, theme)
        }
    }

    private var parentPickerOptions: [ParentGroupList.ParentOption] {
        groupOptions.map {
            ParentGroupList.ParentOption(id: $0.id, label: $0.name,
                                         depth: $0.depth, colorID: $0.colorID)
        }
    }

    /// Selecting a group closes the popover; a session always has one.
    private var parentSelection: Binding<String?> {
        Binding(
            get: { parentID },
            set: { newValue in
                guard let newValue else { return }
                parentID = newValue
                isGroupPickerOpen = false
            }
        )
    }

    private var iconPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            FormLabel("Icon")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6),
                      spacing: 6) {
                ForEach(SessionIcon.allCases) { candidate in
                    let isOn = candidate == icon
                    Button { icon = candidate } label: {
                        Image(systemName: candidate.symbolName)
                            .font(.system(size: 14))
                            .foregroundStyle(isOn ? (sessionColor ?? theme.accent).color
                                                  : theme.textSecondary.color)
                            .frame(maxWidth: .infinity)
                            .frame(height: 34)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(isOn ? (sessionColor?.tileFill ?? theme.accent.tileFill)
                                               : theme.field.color)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(isOn ? (sessionColor ?? theme.accent).color
                                                       : theme.border.color, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(candidate.label)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
        }
    }

    /// The session's color and the pin. A colored group sets the color of
    /// every session in it, so there the swatches give way to a note; the
    /// session's own color is kept, untouched, for when it moves out.
    private var colorAndPin: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                FormLabel("Color")
                Spacer(minLength: 0)
                Toggle(isOn: $pinToTop) {
                    Text("Pin to top")
                        .font(SBFont.ui(13))
                        .foregroundStyle(theme.text.color)
                }
                .toggleStyle(.checkbox)
                .tint(theme.accent.color)
            }
            if groupColor == nil {
                ColorSwatchRow(selection: $colorID, surface: theme.chrome,
                               inherited: nil, diameter: 24)
            } else {
                InsetNote(text: "Sessions in a colored group take its color. To give this one its own, move it out of the group.")
            }
        }
    }

    // MARK: - Right column

    private var authenticationColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                FormLabel("Authentication")
                SegmentedPicker(options: SessionAuth.allCases,
                                selection: $authMode,
                                label: \.label,
                                title: "Authentication method")
            }

            if authMode == .key { keyFields } else { passwordFields }

            jumpHostsSection
        }
    }

    private var keyFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 8) {
                FormField(label: "Key file") {
                    SBTextField(text: $keyPath, placeholder: Session.defaultKeyPath,
                                font: SBFont.mono(13))
                }
                Button("Choose…") {
                    if let path = KeyFilePicker.choose(startingAt: keyPath) { keyPath = path }
                }
                .buttonStyle(SecondaryButtonStyle(theme: theme, height: 36,
                                                  horizontalPadding: 14, filled: true))
            }

            secretField(label: "Key passphrase (optional)", text: $passphrase,
                        placeholder: "Ask on connect", account: passphraseAccount)
            keychainToggle
        }
    }

    private var passwordFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            secretField(label: "Password", text: $password, placeholder: "Ask on connect",
                        account: sessionPasswordAccount)
            keychainToggle
        }
    }

    private var keychainToggle: some View {
        Toggle(isOn: $saveToKeychain) {
            Text("Save to Keychain")
                .font(SBFont.ui(13))
                .foregroundStyle(theme.text.color)
        }
        .toggleStyle(.checkbox)
        .tint(theme.accent.color)
    }

    /// A password-like field that knows whether the Keychain already has a value
    /// for it. An empty field then means "keep what is stored", not "none".
    private func secretField(label: String, text: Binding<String>, placeholder: String,
                             account: String?) -> some View {
        let isStored = account.map(storedAccounts.contains) ?? false
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                FormLabel(label)
                Spacer(minLength: 0)
                if isStored, let account {
                    Button("Forget") {
                        KeychainStore.shared.delete(account)
                        storedAccounts.remove(account)
                    }
                    .buttonStyle(.plain)
                    .font(SBFont.ui(12))
                    .foregroundStyle(theme.accent.color)
                    .accessibilityLabel("Remove the saved \(label.lowercased()) from the Keychain")
                }
            }
            SBTextField(text: text, placeholder: isStored ? "Saved in Keychain" : placeholder,
                        font: SBFont.ui(14), isSecure: true)
        }
    }

    // MARK: - Keychain accounts

    /// Named after the session as it is saved; a new session has no account
    /// to show as stored yet.
    private var sessionPasswordAccount: String? {
        editingSessionID.map(SSHLaunch.sessionPasswordAccount)
    }

    private var passphraseAccount: String? {
        let path = keyPath.trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : SSHLaunch.passphraseAccount(forKey: path)
    }

    private var jumpHostsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Jump hosts")
                    .font(SBFont.ui(13, .semibold))
                    .foregroundStyle(theme.text.color)
                Text("ProxyJump, in order")
                    .font(SBFont.ui(12))
                    .foregroundStyle(theme.textFaint.color)
                Spacer(minLength: 0)
            }

            if jumps.isEmpty {
                InsetNote(text: "Direct connection, no intermediate hosts.")
            }

            ForEach(Array(jumps.enumerated()), id: \.element.id) { index, _ in
                jumpRow(index: index, hop: $jumps[index])
            }

            Button {
                jumps.append(JumpHost(host: ""))
            } label: {
                Label("Add jump host", systemImage: "plus")
                    .labelStyle(InlineIconLabelStyle(spacing: 6, iconSize: 11))
            }
            .buttonStyle(DashedButtonStyle(theme: theme, fontSize: 12.5))

            routeSummary
        }
        .padding(.top, 16)
        .overlay(alignment: .top) { Divider1(theme.border) }
    }

    /// The address on top, then how this hop authenticates, then whatever that
    /// choice needs. A bastion often takes a different key from the host behind
    /// it, so the chain cannot assume one credential all the way down.
    /// One hop, laid out like the session's own fields: Host with its Port
    /// beside it, User beneath, then authentication — labelled, rather than
    /// squeezed onto one line. A header row names the hop and carries the move
    /// and remove buttons at its right edge; the fields below run the full
    /// width of the column, flush with the number and the "Add jump host" button.
    private func jumpRow(index: Int, hop: Binding<JumpHost>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: Self.hopNumberGap) {
                Text("\(index + 1)")
                    .font(SBFont.ui(11.5, .semibold))
                    .foregroundStyle(theme.text.color)
                    .frame(width: Self.hopNumberSize, height: Self.hopNumberSize)
                    .background(Circle().fill(theme.selected.color))
                Text("Jump host")
                    .font(SBFont.ui(13, .semibold))
                    .foregroundStyle(theme.text.color)
                Spacer(minLength: 0)
                hopButtons(index: index, hop: hop)
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .bottom, spacing: 12) {
                    FormField(label: "Host") {
                        SBTextField(text: hop.host, placeholder: "bastion-01 or a saved session",
                                    font: SBFont.mono(13))
                    }
                    .accessibilityLabel("Host for jump host \(index + 1)")
                    FormField(label: "Port") {
                        SBTextField(text: portBinding(hop), placeholder: "22", font: SBFont.mono(13))
                    }
                    .frame(width: 84)
                    .accessibilityLabel("Port for jump host \(index + 1)")
                }

                FormField(label: "User") {
                    SBTextField(text: hop.user, placeholder: "ssh default", font: SBFont.mono(13))
                }
                .accessibilityLabel("User for jump host \(index + 1)")

                FormField(label: "Authentication") {
                    SegmentedPicker(options: JumpHost.Auth.allCases,
                                    selection: hop.auth,
                                    label: \.shortLabel,
                                    title: "Auth for jump host \(index + 1)",
                                    height: 28, fontSize: 12.5,
                                    segmentCornerRadius: 6, cornerRadius: 9)
                }

                jumpCredentials(index: index, hop: hop)
            }
        }
        .padding(.vertical, 6)
    }

    private static let hopNumberSize: CGFloat = 22
    private static let hopNumberGap: CGFloat = 8

    /// Move up, move down and remove, at the right end of the hop's header.
    private func hopButtons(index: Int, hop: Binding<JumpHost>) -> some View {
        HStack(spacing: 6) {
            moveButton(index: index, by: -1)
            moveButton(index: index, by: 1)

            Button {
                let id = hop.wrappedValue.id
                jumps.removeAll { $0.id == id }
                jumpPasswords[id] = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.textSecondary.color)
            }
            .buttonStyle(IconButtonStyle(theme: theme, size: CGSize(width: 28, height: 28),
                                         cornerRadius: 8, bordered: true, borderColor: theme.border))
            .accessibilityLabel("Remove jump host \(index + 1)")
        }
    }

    /// Swaps the hop with its neighbour; disabled at either end of the chain.
    private func moveButton(index: Int, by offset: Int) -> some View {
        let target = index + offset
        let enabled = jumps.indices.contains(target)
        return Button {
            guard jumps.indices.contains(target) else { return }
            jumps.swapAt(index, target)
        } label: {
            Image(systemName: offset < 0 ? "arrow.up" : "arrow.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle((enabled ? theme.textSecondary : theme.disabled).color)
        }
        .buttonStyle(IconButtonStyle(theme: theme, size: CGSize(width: 28, height: 28),
                                     cornerRadius: 8, bordered: true, borderColor: theme.border))
        .disabled(!enabled)
        .accessibilityLabel("Move jump host \(index + 1) \(offset < 0 ? "up" : "down")")
    }

    /// Digits only; an empty field means "the default", not port 0.
    private func portBinding(_ hop: Binding<JumpHost>) -> Binding<String> {
        Binding(
            get: { hop.wrappedValue.port.map(String.init) ?? "" },
            set: { hop.wrappedValue.port = Int($0.filter(\.isNumber).prefix(5)) }
        )
    }

    @ViewBuilder
    private func jumpCredentials(index: Int, hop: Binding<JumpHost>) -> some View {
        switch hop.wrappedValue.auth {
        case .session:
            EmptyView()

        case .key:
            HStack(alignment: .bottom, spacing: 8) {
                FormField(label: "Key file") {
                    SBTextField(text: hop.keyPath, placeholder: Session.defaultKeyPath,
                                font: SBFont.mono(13))
                }
                Button("Choose…") {
                    if let path = KeyFilePicker.choose(startingAt: hop.wrappedValue.keyPath) {
                        hop.wrappedValue.keyPath = path
                    }
                }
                .buttonStyle(SecondaryButtonStyle(theme: theme, height: 36,
                                                  horizontalPadding: 14, filled: true))
            }
            .accessibilityLabel("Key file for jump host \(index + 1)")

        case .password:
            secretField(label: "Password", text: passwordBinding(for: hop.wrappedValue.id),
                        placeholder: "Ask on connect",
                        account: SSHLaunch.hopPasswordAccount(hop.wrappedValue.id))
                .accessibilityLabel("Password for jump host \(index + 1)")
        }
    }

    private var routeSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Route")
                .font(SBFont.ui(11.5))
                .foregroundStyle(theme.textFaint.color)

            FlowRow(spacing: 6, lineSpacing: 6) {
                chip("this Mac", background: theme.elevated, foreground: theme.textSecondary)
                ForEach(jumps) { jump in
                    Text("→").foregroundStyle(theme.textMuted.color).font(SBFont.mono(12))
                    chip(jump.hostPart, background: theme.elevated, foreground: theme.text)
                }
                Text("→").foregroundStyle(theme.textMuted.color).font(SBFont.mono(12))
                chip(host.isEmpty ? "…" : host,
                     background: theme.accent, foreground: theme.accent, tinted: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FieldBackground(theme: theme))
    }

    private func chip(_ text: String, background: RGB, foreground: RGB, tinted: Bool = false) -> some View {
        Text(text)
            .font(SBFont.mono(12))
            .foregroundStyle(tinted ? theme.accentHover.color : foreground.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(tinted ? background.tileFill : background.color)
            )
    }

    /// Kept out of `jumps` on purpose — see `jumpPasswords`.
    private func passwordBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { jumpPasswords[id] ?? "" },
            set: { jumpPasswords[id] = $0 }
        )
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Cancel") { close() }
                .buttonStyle(SecondaryButtonStyle(theme: theme, height: 36,
                                                  horizontalPadding: 16, fontSize: 13.5))
            Spacer(minLength: 0)
            Button("Save") { save(thenConnect: false) }
                .buttonStyle(SecondaryButtonStyle(theme: theme, height: 36,
                                                  horizontalPadding: 16, fontSize: 13.5, filled: true))
                .disabled(!isValid)
            Button(isEditing ? "Save & reconnect" : "Save & connect") { save(thenConnect: true) }
                .buttonStyle(PrimaryButtonStyle(theme: theme, height: 36,
                                                horizontalPadding: 18, fontSize: 13.5))
                .disabled(!isValid)
        }
        .padding(.horizontal, 28)
        .padding(.top, 16)
        .padding(.bottom, 22)
        .overlay(alignment: .top) { Divider1(theme.border) }
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !host.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Loading and saving

    private func load() {
        guard !didLoad else { return }
        didLoad = true

        switch mode {
        case .create(let parent):
            parentID = parent ?? groupOptions.first?.id
            name = ""
            host = ""
            user = NSUserName()
            port = "22"
            icon = .server
            colorID = nil
            authMode = .password
            keyPath = Session.defaultKeyPath
            jumps = []

        case .edit(let id):
            guard let session = sessionStore.session(id) else { return }
            name = session.id
            host = session.host
            port = String(session.port)
            user = session.user
            icon = session.icon
            colorID = session.colorID
            parentID = sessionStore.currentGroupID(ofSession: id)
            pinToTop = sessionStore.isPinned(id)
            authMode = session.auth
            keyPath = session.keyPath
            jumps = session.jumps
        }
        refreshStoredAccounts()
    }

    private func refreshStoredAccounts() {
        var accounts = jumps.map { SSHLaunch.hopPasswordAccount($0.id) }
        if let sessionPasswordAccount { accounts.append(sessionPasswordAccount) }
        if let passphraseAccount { accounts.append(passphraseAccount) }
        storedAccounts = Set(accounts.filter(KeychainStore.shared.contains))
    }

    /// Writes what was typed; leaves alone what was not. Also keeps the
    /// Keychain in step with a rename and with hops that were removed.
    private func storeSecrets(for sessionID: String) {
        let keychain = KeychainStore.shared
        if let editingSessionID {
            keychain.move(SSHLaunch.sessionPasswordAccount(editingSessionID),
                          to: SSHLaunch.sessionPasswordAccount(sessionID))
            let kept = Set(jumps.map(\.id))
            for hop in sessionStore.session(editingSessionID)?.jumps ?? [] where !kept.contains(hop.id) {
                keychain.delete(SSHLaunch.hopPasswordAccount(hop.id))
            }
        }
        guard saveToKeychain else { return }

        if authMode == .password, !password.isEmpty {
            keychain.set(password, for: SSHLaunch.sessionPasswordAccount(sessionID))
        }
        if authMode == .key, !passphrase.isEmpty, let passphraseAccount {
            keychain.set(passphrase, for: passphraseAccount)
        }
        for hop in jumps where hop.auth == .password {
            if let secret = jumpPasswords[hop.id], !secret.isEmpty {
                keychain.set(secret, for: SSHLaunch.hopPasswordAccount(hop.id))
            }
        }
    }

    private func save(thenConnect: Bool) {
        guard isValid else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let session = Session(
            id: trimmedName,
            user: user.trimmingCharacters(in: .whitespaces),
            host: host.trimmingCharacters(in: .whitespaces),
            port: Int(port) ?? 22,
            icon: icon,
            auth: authMode,
            keyPath: keyPath.trimmingCharacters(in: .whitespaces).isEmpty
                ? Session.defaultKeyPath
                : keyPath.trimmingCharacters(in: .whitespaces),
            // Hops with nothing typed in them are dropped rather than saved as
            // blanks the chain summary would have to filter out again.
            jumps: jumps.filter { !$0.host.trimmingCharacters(in: .whitespaces).isEmpty },
            colorID: colorID
        )

        var savedID: String?
        storeSecrets(for: trimmedName)
        if let editingSessionID {
            sessionStore.applySessionEdits(originalID: editingSessionID,
                                           updated: session, parentID: parentID)
            connectionStore.renameSession(from: editingSessionID, to: trimmedName)
            applyPin(to: trimmedName)
            sessionStore.selectedID = trimmedName
            savedID = trimmedName
        } else if let created = sessionStore.createSession(session, parentID: parentID) {
            applyPin(to: created)
            sessionStore.selectedID = created
            savedID = created
        }
        close()

        guard thenConnect, let savedID else { return }
        if isEditing {
            connectionStore.reconnect(sessionID: savedID, in: sessionStore)
        } else {
            connectionStore.connect(sessionID: savedID, in: sessionStore, newTab: true)
        }
    }

    private func applyPin(to id: String) {
        if pinToTop != sessionStore.isPinned(id) { sessionStore.togglePin(id) }
    }
}
