import AppKit
import SwiftUI

struct VNCPane: NSViewRepresentable {
    var connection: Connection
    @Bindable var desktop: VNCDesktop
    var theme: Theme
    var font: NSFont
    var takesFocus: Bool
    var onFocus: () -> Void
    func makeNSView(context: Context) -> TerminalPane.Container { TerminalPane.Container() }
    func updateNSView(_ container: TerminalPane.Container, context: Context) {
        container.layer?.backgroundColor = theme.terminal.nsColor.cgColor
        container.onFocus = onFocus
        let gainsFocus = takesFocus && !container.takesFocus
        container.takesFocus = takesFocus
        if let ssh = desktop.filesSSH, !ssh.isLoggedIn, ssh.state.isRunning {
            // Host-key and password questions use the usual SSH terminal in
            // this pane, then return to the desktop. No extra tab is created.
            TerminalStyle.apply(theme: theme, font: font, to: ssh.terminalView)
            container.inset = NSEdgeInsets(top: 8, left: 12, bottom: 4, right: 4)
            container.mount(ssh.terminalView)
        } else if desktop.phase == .showing {
            container.inset = NSEdgeInsets()
            container.mount(desktop.viewport)
        } else {
            TerminalStyle.apply(theme: theme, font: font, to: connection.terminalView)
            container.inset = NSEdgeInsets(top: 8, left: 12, bottom: 4, right: 4)
            container.mount(connection.terminalView)
        }
        if gainsFocus { container.focusTerminal() }
    }
}

struct VNCQuestionView: View {
    @Environment(\.theme) private var theme
    var desktop: VNCDesktop
    @State private var user = ""
    @State private var password = ""
    @State private var save = true
    @State private var scale = "100"
    var body: some View {
        if let question = desktop.certificateQuestion {
            ZStack {
                theme.terminal.color.opacity(0.7)
                VStack(alignment: .leading, spacing: 14) {
                    Text(question.changed ? "The VNC server's certificate has changed" : "Trust this VNC server?")
                        .font(SBFont.ui(15, .semibold)).foregroundStyle(theme.text.color)
                    Text("\(question.host):\(question.port)\n\(question.subject)")
                        .font(SBFont.ui(13)).foregroundStyle(theme.textSecondary.color)
                    Text(question.problem).font(SBFont.ui(13)).foregroundStyle(theme.ansiRed.color)
                    Text("SHA-256\n\(question.fingerprint)").font(SBFont.mono(11.5))
                        .foregroundStyle(theme.text.color).textSelection(.enabled)
                    Text(question.changed
                         ? "A different certificate was trusted before. Check the new fingerprint with the server administrator before continuing."
                         : "Check the fingerprint with the server administrator. Termstead remembers certificates you trust.")
                        .font(SBFont.ui(12)).foregroundStyle(theme.textSecondary.color)
                    HStack {
                        Spacer()
                        Button("Cancel") { desktop.answerCertificate(trust: false) }
                            .buttonStyle(SecondaryButtonStyle(theme: theme, height: 32, horizontalPadding: 14))
                            .keyboardShortcut(.cancelAction)
                        Button(question.changed ? "Trust New Certificate" : "Trust") { desktop.answerCertificate(trust: true) }
                            .buttonStyle(PrimaryButtonStyle(theme: theme, height: 32, horizontalPadding: 16))
                    }
                }
                .padding(22).frame(width: 440)
                .background(RoundedRectangle(cornerRadius: 12).fill(theme.chrome.color))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.border.color, lineWidth: 1))
            }
        } else if let question = desktop.loginQuestion {
            ZStack {
                theme.terminal.color.opacity(0.7)
                VStack(alignment: .leading, spacing: 14) {
                    Text("VNC login to \(question.host)")
                        .font(SBFont.ui(15, .semibold)).foregroundStyle(theme.text.color)
                    if let problem = question.problem {
                        Text(problem).font(SBFont.ui(13)).foregroundStyle(theme.ansiRed.color)
                    }
                    FormField(label: "User (ARD or TLS username login)") {
                        SBTextField(text: $user, placeholder: "optional", font: SBFont.mono(13))
                    }
                    FormField(label: "Password") {
                        SBTextField(text: $password, placeholder: "VNC password", font: SBFont.ui(14),
                                    isSecure: true, focusOnAppear: true)
                    }
                    HStack(spacing: 10) {
                        if question.canSave {
                            Toggle("Save to Keychain", isOn: $save).toggleStyle(.checkbox).tint(theme.accent.color)
                        }
                        Spacer(minLength: 0)
                        Button("Cancel") { desktop.cancelLogin() }
                            .buttonStyle(SecondaryButtonStyle(theme: theme, height: 32, horizontalPadding: 14))
                            .keyboardShortcut(.cancelAction)
                        Button("Log In") {
                            desktop.answerLogin(user: user.trimmingCharacters(in: .whitespaces), password: password,
                                                save: question.canSave && save)
                        }
                        .buttonStyle(PrimaryButtonStyle(theme: theme, height: 32, horizontalPadding: 16))
                        .keyboardShortcut(.defaultAction)
                        .disabled(password.isEmpty)
                    }
                    .font(SBFont.ui(13)).foregroundStyle(theme.text.color)
                }
                .padding(22).frame(width: 440)
                .background(RoundedRectangle(cornerRadius: 12).fill(theme.chrome.color))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.border.color, lineWidth: 1))
            }
            .onChange(of: question, initial: true) { _, question in user = question.user; password = "" }
        } else if desktop.asksScale {
            ZStack {
                theme.terminal.color.opacity(0.7)
                VStack(alignment: .leading, spacing: 14) {
                    FormField(label: "Desktop scale (25–400%)") {
                        SBTextField(text: $scale, placeholder: "100", font: SBFont.mono(13), focusOnAppear: true)
                    }
                    HStack {
                        Spacer()
                        Button("Cancel") { desktop.asksScale = false }
                            .buttonStyle(SecondaryButtonStyle(theme: theme, height: 32, horizontalPadding: 14))
                            .keyboardShortcut(.cancelAction)
                        Button("Apply") {
                            if let value = Int(scale), (25...400).contains(value) { desktop.setZoom(value) }
                            desktop.asksScale = false
                        }
                        .buttonStyle(PrimaryButtonStyle(theme: theme, height: 32, horizontalPadding: 16))
                        .keyboardShortcut(.defaultAction)
                        .disabled(Int(scale).map { !(25...400).contains($0) } ?? true)
                    }
                }
                .padding(22).frame(width: 300)
                .background(RoundedRectangle(cornerRadius: 12).fill(theme.chrome.color))
                .foregroundStyle(theme.text.color)
            }
            .onAppear { scale = String(desktop.zoom == 0 ? 100 : desktop.zoom) }
        } else if let error = desktop.fileCopy?.error {
            ZStack {
                theme.terminal.color.opacity(0.7)
                VStack(alignment: .leading, spacing: 14) {
                    Text("Files could not be copied")
                        .font(SBFont.ui(15, .semibold))
                    Text(error).font(SBFont.ui(13)).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("OK") { desktop.dismissFileCopy() }
                            .buttonStyle(PrimaryButtonStyle(theme: theme, height: 32, horizontalPadding: 16))
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .foregroundStyle(theme.text.color)
                .padding(22).frame(width: 400)
                .background(RoundedRectangle(cornerRadius: 12).fill(theme.chrome.color))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.border.color, lineWidth: 1))
            }
        }
    }
}
