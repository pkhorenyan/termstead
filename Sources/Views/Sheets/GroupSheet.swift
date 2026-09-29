import SwiftUI

/// Creates a group, or edits an existing one. A group's color lives here rather
/// than in the sidebar, so this is the one place it is set.
struct GroupSheet: View {
    enum Mode: Hashable {
        case create(parentGroupID: String?)
        case edit(groupID: String)
    }

    @Environment(\.theme) private var theme
    @Environment(\.closeForm) private var close
    @Environment(SessionStore.self) private var sessionStore

    var mode: Mode

    @State private var name = ""
    @State private var parentID: String?
    @State private var colorID: String?
    @State private var didLoad = false

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var editingGroupID: String? {
        if case .edit(let id) = mode { return id }
        return nil
    }

    /// "Top level" plus every group except the one being edited and its own
    /// descendants, which would be an impossible parent.
    private var parentOptions: [ParentGroupList.ParentOption] {
        let forbidden = editingGroupID.map { sessionStore.subtreeGroupIDs(of: $0) } ?? []
        let top = ParentGroupList.ParentOption(id: nil, label: "Top level", depth: 0, colorID: nil)
        return [top] + sessionStore.groupOptions().map { option in
            ParentGroupList.ParentOption(
                id: option.id,
                label: option.name,
                depth: option.depth,
                colorID: option.colorID,
                isDisabled: forbidden.contains(option.id)
            )
        }
    }

    /// Top-level groups are plain folders, so the palette only applies below.
    private var isTopLevel: Bool { parentID == nil }

    /// The color the parent passes down, if any — after its own "no color".
    private var inheritedColor: RGB? {
        guard let parentID else { return nil }
        return GroupColor.rgb(for: sessionStore.effectiveColorID(ofGroup: parentID))
    }

    private var inheritNote: String {
        let parentName = parentOptions.first(where: { $0.id == parentID })?.label ?? "the parent"
        switch colorID {
        case nil where inheritedColor != nil:
            return "Inherits \(parentName)'s color, and passes it on."
        case nil, "none":
            return inheritedColor == nil
                ? "No color."
                : "No color, even inside \(parentName). Groups and sessions inside have none either, unless they set their own."
        default:
            return "Sessions inside use this color. So do groups inside, unless they set their own."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: isEditing ? "Group settings" : "New group",
                subtitle: "Top-level groups are plain folders. Groups inside them can have a color.",
                horizontalPadding: 24
            )

            VStack(alignment: .leading, spacing: 16) {
                FormField(label: "Name") {
                    SBTextField(text: $name, placeholder: "Group name",
                                font: SBFont.ui(14), focused: !isEditing)
                }

                VStack(alignment: .leading, spacing: 6) {
                    FormLabel("Inside")
                    // Capped and scrollable: the tree can hold far more groups
                    // than the sheet has room for, and the footer must stay put.
                    ScrollView {
                        ParentGroupList(options: parentOptions, selection: $parentID)
                            .background(ThinScroller(isDark: theme.isDark, alwaysVisible: true))
                    }
                    .frame(maxHeight: 220)
                }

                VStack(alignment: .leading, spacing: 8) {
                    FormLabel("Color")
                    if isTopLevel {
                        InsetNote(text: "Top-level groups have no color. Put a group inside one to color it.")
                    } else {
                        ColorSwatchRow(selection: $colorID, surface: theme.chrome,
                                       inherited: inheritedColor)
                        Text(inheritNote)
                            .font(SBFont.ui(12))
                            .foregroundStyle(theme.textMuted.color)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("Cancel") { close() }
                    .buttonStyle(SecondaryButtonStyle(theme: theme, height: 36,
                                                      horizontalPadding: 16, fontSize: 13.5))
                Button(isEditing ? "Save" : "Create group") { save() }
                    .buttonStyle(PrimaryButtonStyle(theme: theme, height: 36,
                                                    horizontalPadding: 18, fontSize: 13.5))
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 20)
            .overlay(alignment: .top) { Divider1(theme.border) }
        }
        .frame(width: 460, height: 600)
        .background(theme.chrome.color)
        .onAppear(perform: load)
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        switch mode {
        case .create(let parent):
            name = ""
            parentID = parent
            colorID = nil
        case .edit(let id):
            let path = sessionStore.groupPath(id)
            name = path.last ?? ""
            parentID = sessionStore.parentID(ofGroup: id)
            colorID = sessionStore.colorID(ofGroup: id)
        }
    }

    private func save() {
        if let editingGroupID {
            sessionStore.applyGroupEdits(id: editingGroupID, name: name,
                                         colorID: colorID, parentID: parentID)
        } else {
            sessionStore.createGroup(name: name, parentID: parentID, colorID: colorID)
        }
        close()
    }
}
