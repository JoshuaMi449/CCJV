import SwiftUI
import AppKit

struct NameEditorSheet: View {
    let title: String
    let fieldLabel: String
    let initialValue: String
    let note: String?
    let confirmLabel: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var text: String

    init(
        title: String,
        fieldLabel: String,
        initialValue: String,
        note: String? = nil,
        confirmLabel: String = "保存",
        onSave: @escaping (String) -> Void
    ) {
        self.title = title
        self.fieldLabel = fieldLabel
        self.initialValue = initialValue
        self.note = note
        self.confirmLabel = confirmLabel
        self.onSave = onSave
        _text = State(initialValue: initialValue)
    }

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(fieldLabel)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Theme.muted)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Theme.subtleFill))
                }
                .buttonStyle(.plain)
                .focusable(false)
            }

            TextField(fieldLabel, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.text)
                .focused($focused)
                .onSubmit(save)
                .padding(.horizontal, 13)
                .frame(height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.panelLift)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(focused ? Theme.accentLine : Theme.stroke, lineWidth: 1)
                }

            if let note {
                Text(note)
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(Theme.faint)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Spacer()

                Button("取消") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 15)
                .frame(height: 34)
                .background(Capsule().fill(Theme.subtleFill))

                Button(confirmLabel) {
                    save()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accentInk)
                .padding(.horizontal, 18)
                .frame(height: 34)
                .background(Capsule().fill(Theme.orangeGradient))
                .opacity(trimmed.isEmpty ? 0.45 : 1)
                .disabled(trimmed.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Theme.screen)
        .onAppear {
            focused = true
            text = initialValue
        }
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
        dismiss()
    }
}

struct GroupBallView: View {
    let style: GroupBallStyle
    let initial: String
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            Circle()
                .fill(style.gradient)
            Circle()
                .stroke(Color.white.opacity(0.24), lineWidth: 0.8)
                .padding(0.5)
            Text(initial.isEmpty ? "•" : initial)
                .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white)
                .shadow(color: Color.black.opacity(0.10), radius: 1, y: 1)
                .lineLimit(1)
        }
        .frame(width: size, height: size)
    }
}

struct GroupMembersSheet: View {
    @ObservedObject var model: AppModel
    let groupID: String

    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFocused: Bool
    @State private var query = ""

    private var group: SessionGroupRecord? {
        model.group(withID: groupID)
    }

    private var filteredSessions: [SessionSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return model.sessions }
        return model.sessions.filter { session in
            session.displayTitle.localizedCaseInsensitiveContains(trimmed)
                || session.project.localizedCaseInsensitiveContains(trimmed)
                || session.preview.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let group {
                header(group)
                searchField
                Divider()
                    .overlay(Theme.divider)
                    .padding(.top, 12)

                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(filteredSessions) { session in
                            SessionMembershipRow(
                                session: session,
                                isMember: group.sessionIDs.contains(session.id),
                                otherGroupName: model.group(forSessionID: session.id)
                                    .flatMap { $0.id == group.id ? nil : $0.name }
                            ) {
                                model.toggleSessionMembership(session.id, inGroup: group.id)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                }

                footer(group)
            } else {
                VStack(spacing: 12) {
                    Text("这个分组已经被删除了")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.muted)
                    Button("关闭") { dismiss() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 540, height: 600)
        .background(Theme.screen)
    }

    private func header(_ group: SessionGroupRecord) -> some View {
        HStack(spacing: 11) {
            GroupBallView(
                style: group.style,
                initial: String(group.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)),
                size: 34
            )

            VStack(alignment: .leading, spacing: 3) {
                Text("编辑分组 · \(group.name)")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text("\(model.sessions(in: group).count) 个会话")
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(Theme.muted)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Theme.subtleFill))
            }
            .buttonStyle(.plain)
            .focusable(false)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 16)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.faint)
            TextField("搜索会话", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, weight: .regular))
                .foregroundStyle(Theme.text)
                .focused($searchFocused)
        }
        .padding(.horizontal, 11)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.panelLift)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.stroke, lineWidth: 1)
        }
        .padding(.horizontal, 24)
    }

    private func footer(_ group: SessionGroupRecord) -> some View {
        HStack(spacing: 10) {
            Text("勾选后加入本组；已在其他组的会话会被移过来。")
                .font(.system(size: 9.5, weight: .regular))
                .foregroundStyle(Theme.faint)

            Spacer()

            Button("完成") { dismiss() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accentInk)
                .padding(.horizontal, 20)
                .frame(height: 34)
                .background(Capsule().fill(Theme.orangeGradient))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Theme.panelLift.opacity(0.45))
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }
}

private struct SessionMembershipRow: View {
    let session: SessionSummary
    let isMember: Bool
    let otherGroupName: String?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isMember ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isMember ? Theme.accent : Theme.faint.opacity(0.75))

                VStack(alignment: .leading, spacing: 3) {
                    Text(session.displayTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)

                    HStack(spacing: 5) {
                        Text(session.project)
                            .foregroundStyle(Theme.muted)
                        Text("·")
                            .foregroundStyle(Theme.faint)
                        Text(session.date.shortDateLabel)
                            .foregroundStyle(Theme.faint)

                        if let otherGroupName {
                            Text("在「\(otherGroupName)」")
                                .foregroundStyle(Theme.accentDeep)
                        }
                    }
                    .font(.system(size: 9.5, weight: .medium))
                    .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(hovering || isMember ? Theme.accentSoft : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
