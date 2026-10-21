import SwiftUI

/// What an RDP tab asks while connecting — trust a certificate, or a login —
/// over the tab itself rather than in a window: it belongs to that tab, and
/// another tab can be used meanwhile, as with ssh's questions in a terminal.
struct RDPQuestionView: View {
    @Environment(\.theme) private var theme
    var desktop: RDPDesktop

    var body: some View {
        if let question = desktop.certificateQuestion {
            card { CertificateQuestionCard(question: question, desktop: desktop) }
        } else if let question = desktop.loginQuestion {
            card { LoginQuestionCard(question: question, desktop: desktop) }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack {
            theme.terminal.color.opacity(0.7)
            content()
                .padding(22)
                .frame(width: 440)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(theme.chrome.color)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(theme.border.color, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
        }
    }
}

private struct CertificateQuestionCard: View {
    @Environment(\.theme) private var theme
    var question: RDPDesktop.CertificateQuestion
    var desktop: RDPDesktop

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: question.changed ? "exclamationmark.shield.fill" : "lock.shield")
                    .font(.system(size: 20))
                    .foregroundStyle((question.changed ? theme.ansiRed : theme.accent).color)
                Text(question.changed ? "The server's certificate has changed" : "Trust this server?")
                    .font(SBFont.ui(15, .semibold))
                    .foregroundStyle(theme.text.color)
            }

            Text(explanation)
                .font(SBFont.ui(13))
                .foregroundStyle((question.changed ? theme.ansiRed : theme.textSecondary).color)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                detail("Server", "\(question.host):\(question.port)")
                if !question.subject.isEmpty { detail("Certificate", question.subject) }
                detail("SHA-256", question.fingerprint, mono: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FieldBackground(theme: theme))

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("Cancel") { desktop.answerCertificate(trust: false) }
                    .buttonStyle(SecondaryButtonStyle(theme: theme, height: 32, horizontalPadding: 14))
                    .keyboardShortcut(.cancelAction)
                trustButton
            }
        }
    }

    /// Return trusts a new server, as "yes" would; a changed certificate
    /// takes a click — it is what an interception would look like.
    @ViewBuilder
    private var trustButton: some View {
        let button = Button(question.changed ? "Trust the New Certificate" : "Trust") {
            desktop.answerCertificate(trust: true)
        }
        .buttonStyle(PrimaryButtonStyle(theme: theme, height: 32, horizontalPadding: 16))
        if question.changed {
            button
        } else {
            button.keyboardShortcut(.defaultAction)
        }
    }

    private var explanation: String {
        if question.changed {
            return "A different certificate was trusted for this server before. It may have been given a new one — or someone may be intercepting the connection. \(question.problem)"
        }
        return "macOS does not trust the certificate this server presented: \(question.problem) Check the fingerprint with whoever runs the server; once trusted, Termstead remembers it."
    }

    private func detail(_ label: String, _ value: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(SBFont.ui(11.5))
                .foregroundStyle(theme.textFaint.color)
            Text(value)
                .font(mono ? SBFont.mono(11.5) : SBFont.ui(12.5))
                .foregroundStyle(theme.text.color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct LoginQuestionCard: View {
    @Environment(\.theme) private var theme
    var question: RDPDesktop.LoginQuestion
    var desktop: RDPDesktop

    @State private var user = ""
    @State private var domain = ""
    @State private var password = ""
    @State private var save = true
    @State private var didLoad = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "person.badge.key")
                    .font(.system(size: 20))
                    .foregroundStyle(theme.accent.color)
                Text("Log in to \(question.host)")
                    .font(SBFont.ui(15, .semibold))
                    .foregroundStyle(theme.text.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let problem = question.problem {
                Text(problem)
                    .font(SBFont.ui(13))
                    .foregroundStyle(theme.ansiRed.color)
            }

            HStack(alignment: .bottom, spacing: 10) {
                FormField(label: "User") {
                    SBTextField(text: $user, placeholder: "Administrator", font: SBFont.mono(13))
                }
                FormField(label: "Domain") {
                    SBTextField(text: $domain, placeholder: "optional", font: SBFont.mono(13))
                }
                .frame(width: 130)
            }
            FormField(label: "Password") {
                SBTextField(text: $password, placeholder: "", font: SBFont.ui(14), isSecure: true,
                            focusOnAppear: true)
            }

            HStack(spacing: 10) {
                if question.canSave {
                    Toggle(isOn: $save) {
                        Text("Save to Keychain")
                            .font(SBFont.ui(13))
                            .foregroundStyle(theme.text.color)
                    }
                    .toggleStyle(.checkbox)
                    .tint(theme.accent.color)
                }
                Spacer(minLength: 0)
                Button("Cancel") { desktop.answerLogin(nil, save: false) }
                    .buttonStyle(SecondaryButtonStyle(theme: theme, height: 32, horizontalPadding: 14))
                    .keyboardShortcut(.cancelAction)
                Button("Log In") {
                    desktop.answerLogin(RDPLogin(user: user.trimmingCharacters(in: .whitespaces),
                                                 domain: domain.trimmingCharacters(in: .whitespaces),
                                                 password: password),
                                        save: question.canSave && save)
                }
                .buttonStyle(PrimaryButtonStyle(theme: theme, height: 32, horizontalPadding: 16))
                .keyboardShortcut(.defaultAction)
                .disabled(user.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            user = question.user
            domain = question.domain
        }
    }
}
