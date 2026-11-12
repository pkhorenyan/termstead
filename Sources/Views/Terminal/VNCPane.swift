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
        if desktop.phase == .showing {
            container.inset = NSEdgeInsets()
            container.mount(desktop.view)
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
    var body: some View {
        if let question = desktop.loginQuestion {
            ZStack {
                theme.terminal.color.opacity(0.7)
                VStack(alignment: .leading, spacing: 14) {
                    Text("VNC login to \(question.host)")
                        .font(SBFont.ui(15, .semibold)).foregroundStyle(theme.text.color)
                    if let problem = question.problem {
                        Text(problem).font(SBFont.ui(13)).foregroundStyle(theme.ansiRed.color)
                    }
                    FormField(label: "User (Apple Remote Desktop only)") {
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
        }
    }
}
