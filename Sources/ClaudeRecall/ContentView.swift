import SwiftUI
import AppKit
import ImageIO

struct ContentView: View {
    @StateObject private var model = AppModel()
    @StateObject private var settings = AppSettings()
    @State private var sidebarVisible = true
    @State private var groupBallCutouts: [GroupBallCutout] = []
    @State private var sessionListFrame: CGRect = .null

    private var visibleGroupBallCutouts: [GroupBallCutout] {
        guard sidebarVisible, !sessionListFrame.isNull else { return [] }
        return groupBallCutouts
    }

    var body: some View {
        ZStack {
            AppBackground()

            CornerPanel {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        HStack(spacing: 0) {
                            Color.clear
                                .frame(width: sidebarVisible ? 284 : 0)

                            ReadingCanvas(model: model, referenceWidth: proxy.size.width)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }

                        SessionTray(model: model, isVisible: sidebarVisible)
                            .frame(width: 284)
                            .offset(x: sidebarVisible ? 0 : -294)
                            .opacity(sidebarVisible ? 1 : 0)
                            .allowsHitTesting(sidebarVisible)
                            .disabled(!sidebarVisible)
                            .accessibilityHidden(!sidebarVisible)
                            .zIndex(1)
                    }
                }
            }
            .coordinateSpace(name: "claudeRecallPanel")
            .onPreferenceChange(GroupBallCutoutPreferenceKey.self) { cutouts in
                guard cutouts != groupBallCutouts else { return }
                groupBallCutouts = cutouts
            }
            .onPreferenceChange(SessionListFramePreferenceKey.self) { frame in
                guard frame != sessionListFrame else { return }
                sessionListFrame = frame
            }
            .mask {
                CutoutPanelMask(
                    rings: visibleGroupBallCutouts,
                    viewport: sessionListFrame
                )
                .fill(Color.white)
            }
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    ForEach(visibleGroupBallCutouts) { cutout in
                        GroupBallView(
                            style: cutout.style,
                            initial: cutout.initial,
                            size: cutout.size
                        )
                        .position(cutout.center)
                        .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .mask(SessionListClip(rect: sessionListFrame))
            }
            .overlay(alignment: .topLeading) {
                Button {
                    withAnimation(.snappy(duration: 0.26)) {
                        sidebarVisible.toggle()
                    }
                } label: {
                    BrandBall(size: 48, symbol: sidebarVisible ? "sidebar.left" : "sidebar.right")
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(sidebarVisible ? "收起会话列表" : "展开会话列表")
                .padding(.leading, 4)
                .padding(.top, 4)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 18)
            .animation(.snappy(duration: 0.26), value: sidebarVisible)
        }
        .environmentObject(settings)
        .id(settings.revision)
        .preferredColorScheme(settings.darkMode ? .dark : .light)
    }
}

// MARK: - Session tray

private struct BrandBall: View {
    var size: CGFloat = 30
    var symbol: String = "sidebar.left"

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Theme.accentLight, Theme.accent, Theme.accentDeep],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: symbol)
                .font(.system(size: size * 0.24, weight: .semibold))
                .foregroundStyle(Color.white)
        }
        .frame(width: size, height: size)
    }
}

private struct SessionTray: View {
    @ObservedObject var model: AppModel
    var isVisible: Bool = true
    @FocusState private var searchFocused: Bool
    @State private var outlineSessionID: String?
    @State private var activePromptID: String?
    @State private var selectedSessionIDs: Set<String> = []
    @State private var selectionAnchorID: String?
    @State private var outlineContentFrames: [String: CGRect] = [:]
    @State private var groupHeaderFrames: [String: CGRect] = [:]
    @State private var outlineFollowTask: Task<Void, Never>?
    @State private var renameTarget: RenameTarget?
    @State private var groupCreation: GroupCreationRequest?
    @State private var editingGroup: GroupEditorTarget?
    @State private var groupPendingDeletion: SessionGroupRecord?
    @State private var showingDeleteGroup = false

    private var dateGroups: [SessionGroup] {
        let calendar = Calendar.current
        let groupedIDs = Set(model.customGroups.flatMap(\.sessionIDs))
        var today: [SessionSummary] = []
        var yesterday: [SessionSummary] = []
        var earlier: [SessionSummary] = []

        for session in model.sessions where !groupedIDs.contains(session.id) {
            if calendar.isDateInToday(session.date) {
                today.append(session)
            } else if calendar.isDateInYesterday(session.date) {
                yesterday.append(session)
            } else {
                earlier.append(session)
            }
        }

        return [
            SessionGroup(id: "today", sessions: today),
            SessionGroup(id: "yesterday", sessions: yesterday),
            SessionGroup(id: "earlier", sessions: earlier)
        ].filter { !$0.sessions.isEmpty }
    }

    private var visibleSessionIDs: [String] {
        var result: [String] = []
        for group in model.customGroups where !group.isCollapsed {
            result.append(contentsOf: model.sessions(in: group).map(\.id))
        }
        for group in dateGroups {
            result.append(contentsOf: group.sessions.map(\.id))
        }
        return result
    }

    private var selectedSessions: [SessionSummary] {
        guard !selectedSessionIDs.isEmpty else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: model.sessions.map { ($0.id, $0) })
        return visibleSessionIDs.compactMap { id in
            guard selectedSessionIDs.contains(id) else { return nil }
            return byID[id]
        }
    }

    private var pinnedGroupedSession: SessionSummary? {
        guard let id = outlineSessionID,
              model.selectedID == id,
              let group = model.group(forSessionID: id),
              let groupHeader = groupHeaderFrames[group.id],
              groupHeader.minY <= 1,
              groupHeader.maxY > 0,
              let content = outlineContentFrames[id],
              content.minY < groupHeader.maxY,
              content.maxY > groupHeader.maxY else {
            return nil
        }
        return model.sessions.first { $0.id == id }
    }

    private var pinnedGroupedSessionTop: CGFloat {
        guard let id = outlineSessionID,
              let group = model.group(forSessionID: id),
              let groupHeader = groupHeaderFrames[group.id] else {
            return 87
        }
        return max(0, groupHeader.maxY)
    }

    private var selectionChip: some View {
        Button {
            clearSelection()
        } label: {
            HStack(spacing: 4) {
                Text("已选 \(selectedSessions.count)")
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
            }
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(Theme.accentDeep)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Theme.accentSoft))
            .overlay(Capsule().stroke(Theme.accentLine, lineWidth: 0.8))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("清除选择 · ⌘ 点选单个，⇧ 连选")
    }

    private func label(for id: String) -> String {
        switch id {
        case "today": return "今天"
        case "yesterday": return "昨天"
        default: return "更早"
        }
    }

    private var trimmedQuery: String {
        model.query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            SearchField(text: $model.query, focused: $searchFocused)
                .padding(.horizontal, 18)

            if trimmedQuery.isEmpty {
                recentSessions
            } else {
                searchResults
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebarTint)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Theme.divider)
                .frame(width: 1)
        }
        .sheet(item: $renameTarget) { target in
            NameEditorSheet(
                title: target.title,
                fieldLabel: "名称",
                initialValue: target.initial,
                note: target.note,
                confirmLabel: "保存"
            ) { name in
                switch target.kind {
                case .session(let sessionID):
                    model.renameSession(sessionID, to: name)
                case .group(let groupID):
                    model.renameGroup(groupID, to: name)
                }
            }
        }
        .sheet(item: $groupCreation) { request in
            NameEditorSheet(
                title: "新建分组",
                fieldLabel: "分组名称",
                initialValue: "新分组",
                note: "分组只做本地整理，不会移动或改名 ~/.claude 里的原始 JSON。创建后可在会话右键菜单或分组菜单里添加会话。",
                confirmLabel: "创建"
            ) { name in
                withAnimation(.snappy(duration: 0.24)) {
                    _ = model.createGroup(name: name, adding: request.sessionIDs)
                    clearSelection()
                }
            }
        }
        .sheet(item: $editingGroup) { target in
            GroupMembersSheet(model: model, groupID: target.groupID)
        }
        .alert("删除这个分组？", isPresented: $showingDeleteGroup) {
            Button("删除", role: .destructive) {
                if let groupPendingDeletion {
                    withAnimation(.snappy(duration: 0.24)) {
                        model.deleteGroup(groupPendingDeletion.id)
                    }
                }
                groupPendingDeletion = nil
            }
            Button("取消", role: .cancel) {
                groupPendingDeletion = nil
            }
        } message: {
            Text("只删除分组本身，不会删除会话、原始 JSON 或本地归档。")
        }
        .onChange(of: model.sessions) { _, newSessions in
            let existingIDs = Set(newSessions.map(\.id))
            guard !selectedSessionIDs.isSubset(of: existingIDs) else { return }
            selectedSessionIDs.formIntersection(existingIDs)
            if selectedSessionIDs.isEmpty {
                selectionAnchorID = nil
            }
        }
        .onChange(of: model.query) { _, newValue in
            if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                clearSelection()
            }
        }
        .onChange(of: isVisible) { _, visible in
            if !visible {
                searchFocused = false
            }
        }
    }

    private var recentSessions: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Text("最近会话")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.muted)

                Spacer()

                groupMenu

                if selectedSessionIDs.isEmpty {
                    Text("\(model.sessions.count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.faint)
                        .monospacedDigit()
                } else {
                    selectionChip
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            if model.sessions.isEmpty {
                emptyState
            } else {
                ScrollViewReader { sidebarProxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(
                        alignment: .leading,
                        spacing: 2,
                        pinnedViews: [.sectionHeaders]
                    ) {
                        ForEach(model.customGroups) { group in
                            manualGroupSection(group)
                        }

                        ForEach(dateGroups) { group in
                            Text(label(for: group.id))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.faint)
                                .padding(.horizontal, 12)
                                .padding(.top, 14)
                                .padding(.bottom, 5)

                            ForEach(group.sessions) { session in
                                sessionEntry(session)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
                .coordinateSpace(name: "sessionTrayScroll")
                .onPreferenceChange(SessionOutlineContentFramePreferenceKey.self) { frames in
                    if frames != outlineContentFrames {
                        outlineContentFrames = frames
                    }
                }
                .onPreferenceChange(SessionGroupHeaderFramePreferenceKey.self) { frames in
                    if frames != groupHeaderFrames {
                        groupHeaderFrames = frames
                    }
                }
                .overlay(alignment: .top) {
                    if let session = pinnedGroupedSession {
                        sessionHeader(session, pinned: true, indented: true)
                            .padding(.horizontal, 8)
                            .padding(.top, pinnedGroupedSessionTop)
                            .transition(.opacity)
                    }
                }
                .onChange(of: model.activeTurnID) { _, turnID in
                    scrollOutlineToActiveTurn(turnID, proxy: sidebarProxy)
                }
                .onChange(of: outlineSessionID) { _, _ in
                    scrollOutlineToActiveTurn(model.activeTurnID, proxy: sidebarProxy)
                }
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: SessionListFramePreferenceKey.self,
                            value: proxy.frame(in: .named("claudeRecallPanel"))
                        )
                    }
                }
                }
            }
        }
    }

    private var groupMenu: some View {
        Menu {
            Button(selectedSessions.isEmpty ? "新建分组…" : "新建分组（\(selectedSessions.count) 个）…") {
                groupCreation = GroupCreationRequest(sessionIDs: selectedSessions.map(\.id))
            }

            if !model.customGroups.isEmpty {
                Divider()
                Button("全部收起为球") {
                    withAnimation(.snappy(duration: 0.24)) {
                        model.collapseAllGroups()
                    }
                    clearSelection()
                }
                Button("全部展开") {
                    withAnimation(.snappy(duration: 0.24)) {
                        model.expandAllGroups()
                    }
                }
            }
        } label: {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Theme.muted)
                .frame(width: 22, height: 20)
                .background(Capsule().fill(Theme.subtleFill))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .focusable(false)
        .help("新建或整理分组")
    }

    private let groupChildIndent: CGFloat = 16

    @ViewBuilder
    private func manualGroupSection(_ group: SessionGroupRecord) -> some View {
        let groupSessions = model.sessions(in: group)

        if group.isCollapsed {
            groupHeaderView(group, sessionCount: groupSessions.count, chainCount: model.chainCount(in: group))
        } else {
            Section {
                if groupSessions.isEmpty {
                    Text("还没有会话。右键任意会话，选择「加入分组」即可添加。")
                        .font(.system(size: 9.5, weight: .regular))
                        .foregroundStyle(Theme.faint)
                        .lineSpacing(2)
                        .padding(.leading, 68)
                        .padding(.trailing, 12)
                        .padding(.vertical, 10)
                } else {
                    ForEach(groupSessions) { session in
                        sessionEntry(session, indented: true)
                    }
                }
            } header: {
                groupHeaderView(group, sessionCount: groupSessions.count, chainCount: model.chainCount(in: group))
            }
        }
    }

    private func groupHeaderView(
        _ group: SessionGroupRecord,
        sessionCount: Int,
        chainCount: Int
    ) -> some View {
        GroupHeaderRow(
            group: group,
            sessionCount: sessionCount,
            chainCount: chainCount,
            onToggle: {
                let collapsing = !group.isCollapsed
                withAnimation(.snappy(duration: 0.26)) {
                    model.setGroupCollapsed(group.id, collapsed: collapsing)
                    if collapsing {
                        let hiddenIDs = Set(model.sessions(in: group).map(\.id))
                        selectedSessionIDs.subtract(hiddenIDs)
                        if selectedSessionIDs.isEmpty {
                            selectionAnchorID = nil
                        }
                    }
                }
            },
            onRename: {
                openRenameGroup(group)
            },
            onStyle: { style in
                withAnimation(.snappy(duration: 0.2)) {
                    model.updateGroupStyle(group.id, style: style)
                }
            },
            onMembers: {
                editingGroup = GroupEditorTarget(groupID: group.id)
            },
            onDelete: {
                groupPendingDeletion = group
                showingDeleteGroup = true
            }
        )
        .padding(.leading, -8)
        .padding(.top, 7)
        .background(Theme.sidebarOpaque)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SessionGroupHeaderFramePreferenceKey.self,
                    value: [group.id: proxy.frame(in: .named("sessionTrayScroll"))]
                )
            }
        }
    }

    @ViewBuilder
    private func sessionEntry(_ session: SessionSummary, indented: Bool = false) -> some View {
        if outlineSessionID == session.id, model.selectedID == session.id {
            Section {
                sessionOutline(for: session)
                    .transition(.opacity)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: SessionOutlineContentFramePreferenceKey.self,
                                value: [session.id: proxy.frame(in: .named("sessionTrayScroll"))]
                            )
                        }
                    }
            } header: {
                sessionHeader(session, pinned: true, indented: indented)
            }
        } else {
            sessionHeader(session, pinned: false, indented: indented)
        }
    }

    private func sessionHeader(
        _ session: SessionSummary,
        pinned: Bool,
        indented: Bool = false
    ) -> some View {
        SessionRow(
            session: session,
            isSelected: model.selectedID == session.id,
            isMultiSelected: selectedSessionIDs.contains(session.id),
            lineage: model.lineageInfo(for: session.id),
            linkBroken: model.isLinkBroken(session.id)
        ) {
            handleSessionClick(session)
        }
        .padding(.leading, indented ? groupChildIndent : 0)
        .padding(.trailing, indented ? 4 : 0)
        .background(pinned ? Theme.sidebarOpaque : Color.clear)
        .overlay(alignment: .bottom) {
            if pinned {
                Rectangle()
                    .fill(Theme.divider)
                    .frame(height: 1)
            }
        }
        .contextMenu {
            sessionContextMenu(session)
        }
    }

    @ViewBuilder
    private func sessionContextMenu(_ session: SessionSummary) -> some View {
        let targets = contextTargets(for: session)
        let targetIDs = targets.map(\.id)
        let isMulti = targets.count > 1

        if isMulti {
            Button("已选择 \(targets.count) 个会话") {}
                .disabled(true)
            Divider()
        } else {
            Button("重命名会话…") {
                openRenameSession(session)
            }

            if model.customName(for: session.id) != nil {
                Button("恢复原标题") {
                    model.renameSession(session.id, to: "")
                }
            }
            Divider()
        }

        Menu(isMulti ? "加入分组（\(targets.count) 个）" : "加入分组") {
            ForEach(model.customGroups) { group in
                let allInGroup = targets.allSatisfy {
                    model.group(forSessionID: $0.id)?.id == group.id
                }
                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        model.addSessions(targetIDs, toGroup: group.id)
                    }
                    clearSelection()
                } label: {
                    HStack {
                        Text(group.name)
                        if allInGroup {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .disabled(allInGroup)
            }

            if !model.customGroups.isEmpty {
                Divider()
            }

            Button(isMulti ? "新建分组（\(targets.count) 个）…" : "新建分组…") {
                groupCreation = GroupCreationRequest(sessionIDs: targetIDs)
            }
        }

        if targets.contains(where: { model.group(forSessionID: $0.id) != nil }) {
            Button(isMulti ? "移出分组（\(targets.count) 个）" : "移出「\(model.group(forSessionID: session.id)?.name ?? "分组")」") {
                withAnimation(.snappy(duration: 0.22)) {
                    model.removeSessionsFromGroups(targetIDs)
                }
                clearSelection()
            }
        }
    }

    private func handleSessionClick(_ session: SessionSummary) {
        let flags = NSEvent.modifierFlags

        if flags.contains(.shift) {
            let ids = visibleSessionIDs
            guard let target = ids.firstIndex(of: session.id) else { return }
            if let anchorID = selectionAnchorID, let anchor = ids.firstIndex(of: anchorID) {
                let lower = min(anchor, target)
                let upper = max(anchor, target)
                selectedSessionIDs.formUnion(ids[lower...upper])
            } else {
                selectedSessionIDs.insert(session.id)
                selectionAnchorID = session.id
            }
            return
        }

        if flags.contains(.command) {
            if selectedSessionIDs.contains(session.id) {
                selectedSessionIDs.remove(session.id)
            } else {
                selectedSessionIDs.insert(session.id)
            }
            selectionAnchorID = selectedSessionIDs.isEmpty ? nil : session.id
            return
        }

        clearSelection()
        selectionAnchorID = session.id

        let isOpen = outlineSessionID == session.id
        if model.selectedID == session.id && isOpen {
            model.setSearchScope(nil)
            withAnimation(.snappy(duration: 0.22)) {
                outlineSessionID = nil
                activePromptID = nil
            }
        } else {
            model.select(session.id)
            model.setSearchScope(session.id)
            withAnimation(.snappy(duration: 0.22)) {
                outlineSessionID = session.id
                activePromptID = nil
            }
        }
    }

    private func scrollOutlineToActiveTurn(
        _ turnID: String?,
        proxy: ScrollViewProxy
    ) {
        guard trimmedQuery.isEmpty,
              outlineSessionID == model.selectedID,
              let turnID else { return }
        activePromptID = turnID
        outlineFollowTask?.cancel()
        outlineFollowTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.12)) {
                proxy.scrollTo("prompt-\(turnID)", anchor: .center)
            }
        }
    }

    private func contextTargets(for session: SessionSummary) -> [SessionSummary] {
        guard selectedSessionIDs.contains(session.id) else { return [session] }
        let targets = selectedSessions
        return targets.contains(where: { $0.id == session.id }) ? targets : [session]
    }

    private func clearSelection() {
        selectedSessionIDs.removeAll()
        selectionAnchorID = nil
    }

    private func openRenameSession(_ session: SessionSummary) {
        renameTarget = RenameTarget(
            kind: .session(session.id),
            title: "重命名会话",
            initial: session.displayTitle,
            note: "只修改 CCJV 里的显示名，不改原始 .jsonl 文件名，避免影响 Claude Code 的 resume 和子代理目录。"
        )
    }

    private func openRenameGroup(_ group: SessionGroupRecord) {
        renameTarget = RenameTarget(
            kind: .group(group.id),
            title: "重命名分组",
            initial: group.name,
            note: "只修改分组名称，不移动或改名 ~/.claude 里的原始 JSON。"
        )
    }

    private var searchResults: some View {
        Group {
            if let active = model.activeSearchSession {
                searchSessionDetail(active)
            } else {
                searchSessionList
            }
        }
    }

    private var searchSessionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("搜索结果")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.muted)

                if !model.contentIndexReady {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Theme.accent)
                }

                Spacer()

                if model.contentIndexReady {
                    Text("\(model.searchSessions.count) 个会话 · \(model.searchTotal) 处")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Theme.faint)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            if let scope = model.searchScopeSessionID {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text("仅搜索：\(model.sessions.first { $0.id == scope }?.displayTitle ?? "当前会话")")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Theme.accentDeep)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button("清除范围") {
                        model.setSearchScope(nil)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Theme.faint)
                    .focusable(false)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }

            if !model.contentIndexReady {
                searchIndexingState
            } else if model.searchSessions.isEmpty {
                searchEmptyState
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.searchSessions) { result in
                            SearchSessionRow(
                                result: result,
                                session: model.sessions.first { $0.id == result.sessionID }
                            ) {
                                model.openSearchSession(result)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func searchSessionDetail(_ result: ContentSearchSessionResult) -> some View {
        let session = model.sessions.first { $0.id == result.sessionID }
        let questionHits = result.hits.filter { $0.entry.role == .user }
        let latestDate = questionHits.first?.entry.timestamp ?? session?.date

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                model.exitSearchSession()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 8, weight: .bold))
                    Text("全部结果")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 5) {
                Text(session?.displayTitle ?? "未命名会话")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)

                HStack(spacing: 5) {
                    Text("\(questionHits.count) 处我的提问")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    if result.chainIDs.count > 1 {
                        Text("·")
                            .foregroundStyle(Theme.faint)
                        Text("链 \(result.chainIDs.count) 段")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Theme.accentDeep)
                    }
                    Text("·")
                        .foregroundStyle(Theme.faint)
                    Text(latestDate?.shortDateLabel ?? "")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Theme.faint)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)

            if questionHits.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 16, weight: .light))
                        .foregroundStyle(Theme.faint)
                    Text("这个会话里没有匹配你的提问")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.faint)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 36)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(questionHits) { hit in
                            SearchMatchRow(
                                hit: hit,
                                isSelected: model.highlightedItemID == hit.entry.messageID
                            ) {
                                model.openSearchHit(hit)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func prompts(for session: SessionSummary) -> [PromptItem]? {
        guard let conversation = model.conversation,
              conversation.session.id == session.id else { return nil }

        return conversation.turns.compactMap { turn in
            guard let user = turn.user,
                  case .user(_, let text, let timestamp) = user else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !isInterruptionText(trimmed) else { return nil }
            return PromptItem(id: turn.id, text: trimmed, timestamp: timestamp)
        }
    }

    @ViewBuilder
    private func sessionOutline(for session: SessionSummary) -> some View {
        if let prompts = prompts(for: session) {
            VStack(alignment: .leading, spacing: 2) {
                Text("我的提问 · \(prompts.count)")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Theme.faint)
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .padding(.bottom, 2)

                if prompts.isEmpty {
                    Text("这个会话里没有你的提问")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(Theme.faint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                } else {
                    ForEach(prompts) { prompt in
                        Button {
                            activePromptID = prompt.id
                            model.focusTurn(prompt.id)
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                    .fill(activePromptID == prompt.id ? Theme.accent : Theme.accentLine)
                                    .frame(width: 2.5, height: 26)
                                    .padding(.top, 2)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(prompt.text)
                                        .font(.system(size: 11, weight: .regular))
                                        .foregroundStyle(Theme.textSoft)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)

                                    if let timestamp = prompt.timestamp {
                                        Text(timestamp.timeLabel)
                                            .font(.system(size: 8.5, weight: .medium))
                                            .foregroundStyle(Theme.faint)
                                    }
                                }

                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(activePromptID == prompt.id ? Theme.accentSoft : Color.clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .id("prompt-\(prompt.id)")
                    }
                }
            }
            .padding(.leading, 30)
            .padding(.trailing, 10)
            .padding(.bottom, 6)
            .transition(.opacity)
        } else {
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.mini)
                    .tint(Theme.accent)
                Text("正在载入你的提问…")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(Theme.faint)
            }
            .padding(.leading, 34)
            .padding(.vertical, 8)
        }
    }

    private var searchIndexingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(Theme.accent)
            Text("正在索引会话内容…")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSoft)
            Text("首次会建立本地归档，之后秒开")
                .font(.system(size: 9.5, weight: .regular))
                .foregroundStyle(Theme.faint)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 44)
    }

    private var searchEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(Theme.faint)
            Text(model.searchScopeSessionID == nil
                 ? "没有匹配的会话内容"
                 : "这个会话里没有匹配内容")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.faint)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 44)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("会话")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("\(model.sessions.count) 个 · 本地只读")
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(Theme.muted)
            }

            Spacer()
        }
        .padding(.leading, 88)
        .padding(.trailing, 18)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var emptyState: some View {
        let finished = model.status == "没有找到会话"
        return VStack(spacing: 8) {
            if !finished {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.accent)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(Theme.faint)
            }

            Text(finished ? "没有找到会话" : "正在扫描 ~/.claude/projects…")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.faint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SessionGroup: Identifiable {
    let id: String
    let sessions: [SessionSummary]
}

private struct RenameTarget: Identifiable {
    enum Kind {
        case session(String)
        case group(String)
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let initial: String
    let note: String?
}

private struct GroupCreationRequest: Identifiable {
    let id = UUID()
    let sessionIDs: [String]
}

private struct GroupEditorTarget: Identifiable {
    let id = UUID()
    let groupID: String
}

private struct PromptItem: Identifiable {
    let id: String
    let text: String
    let timestamp: Date?
}

private func isInterruptionText(_ text: String) -> Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
        .hasPrefix("[Request interrupted by user")
}

private struct SessionRow: View {
    let session: SessionSummary
    let isSelected: Bool
    let isMultiSelected: Bool
    let lineage: SessionLineage?
    let linkBroken: Bool
    let action: () -> Void
    @State private var hovering = false

    private var dateLabel: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(session.date) || calendar.isDateInYesterday(session.date) {
            return session.date.timeLabel
        }
        return session.date.shortDateLabel
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(isSelected ? Theme.accent : Color.clear)
                    .frame(width: 3, height: 30)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if isMultiSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(Theme.accent)
                        }

                        Text(session.displayTitle)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)

                        Spacer(minLength: 4)

                        Text(dateLabel)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Theme.faint)
                            .lineLimit(1)
                    }

                    HStack(spacing: 5) {
                        Text(session.project)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(isSelected ? Theme.accentDeep : Theme.muted)
                            .lineLimit(1)

                        if session.isArchived {
                            Text("归档")
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(Theme.muted)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Theme.subtleFill))
                                .help("原始 JSON 已被清理，当前显示本地归档")
                        }

                        if let badge = lineageBadge {
                            metaDot
                            HStack(spacing: 3) {
                                Image(systemName: "link")
                                    .font(.system(size: 7, weight: .bold))
                                Text(badge)
                            }
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(Theme.accentDeep)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Theme.accentSoft))
                            .help(lineageHelp)
                        }

                        if session.turns > 0 {
                            metaDot
                            Text("\(session.turns) 轮")
                        }

                        if session.subagentCount > 0 {
                            metaDot
                            Text("\(session.subagentCount) 分支")
                        }
                    }
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Theme.faint)

                    Text(session.preview.isEmpty ? "—" : session.preview)
                        .font(.system(size: 10.5, weight: .regular))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        isSelected
                            ? Theme.accentSoft
                            : (isMultiSelected ? Theme.accentSoft.opacity(0.72)
                                : (hovering ? Theme.subtleFill : Color.clear))
                    )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected || isMultiSelected ? Theme.accentLine : Color.clear, lineWidth: 1)
            }
            .shadow(color: isSelected || isMultiSelected ? Theme.cardShadow : .clear, radius: 10, y: 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var lineageBadge: String? {
        guard let lineage else { return nil }
        if linkBroken {
            return "已断开"
        }
        if lineage.parentID != nil {
            return lineage.isStrong ? "续接" : "疑似续接"
        }
        if !lineage.children.isEmpty {
            return "后续"
        }
        if lineage.isAmbiguous {
            return "续接？"
        }
        if lineage.isContinuationSegment {
            return "续接段"
        }
        return nil
    }

    private var lineageHelp: String {
        guard let lineage else { return "" }
        if linkBroken {
            return "已手动断开与前段的自动续接；可在阅读页右上角菜单恢复。"
        }
        if lineage.parentID != nil {
            let confidence = lineage.isStrong ? "共享消息 UUID" : "仅少量 UUID 证据"
            return "\(confidence)：\(lineage.evidence) 条。打开本会话会在同一页合并前段；终端 resume 仍只恢复本段。"
        }
        if !lineage.children.isEmpty {
            return "本段后面有 \(lineage.children.count) 个续接段；打开后续会话会在同一页显示本段。"
        }
        if lineage.isAmbiguous {
            return "检测到续接边界，但有多个候选前段，未自动关联。"
        }
        return "本段开头有续接边界，但本地归档里没有找到前段。"
    }

    private var metaDot: some View {
        Circle()
            .fill(Theme.faint.opacity(0.55))
            .frame(width: 2.5, height: 2.5)
    }
}

private struct GroupHeaderRow: View {
    let group: SessionGroupRecord
    let sessionCount: Int
    let chainCount: Int
    let onToggle: () -> Void
    let onRename: () -> Void
    let onStyle: (GroupBallStyle) -> Void
    let onMembers: () -> Void
    let onDelete: () -> Void

    private var initial: String {
        let trimmed = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(1))
    }

    private var groupCountLabel: String {
        guard chainCount > 0, chainCount < sessionCount else {
            return "\(sessionCount) 个会话"
        }
        return "\(chainCount) 条链 · \(sessionCount) 段"
    }

    private let headerHeight: CGFloat = 80
    private let ballSize: CGFloat = 36
    private let socketX: CGFloat = 20
    private let socketRadius: CGFloat = 28

    var body: some View {
        ZStack(alignment: .leading) {
            headerBackground

            HStack(spacing: 5) {
                Button(action: onToggle) {
                    HStack(spacing: 12) {
                        Color.clear
                            .frame(width: ballSize, height: ballSize)
                            .background {
                                GeometryReader { proxy in
                                    let frame = proxy.frame(in: .named("claudeRecallPanel"))
                                    Color.clear.preference(
                                        key: GroupBallCutoutPreferenceKey.self,
                                        value: [
                                            GroupBallCutout(
                                                id: group.id,
                                                center: CGPoint(x: frame.midX, y: frame.midY),
                                                style: group.style,
                                                initial: initial,
                                                size: ballSize,
                                                socketRadius: socketRadius
                                            )
                                        ]
                                    )
                                }
                            }

                        VStack(alignment: .leading, spacing: 3) {
                            Text(group.name)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)

                            HStack(spacing: 5) {
                                Text(groupCountLabel)
                                Text("·")
                                Text(group.isCollapsed ? "球模式" : "已展开")
                            }
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Theme.faint)
                        }

                        Spacer(minLength: 0)

                        Image(systemName: group.isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.faint)
                            .frame(width: 14)
                    }
                    .padding(.leading, socketX - ballSize / 2)
                    .padding(.trailing, 4)
                    .frame(height: headerHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Menu {
                    groupMenuContent
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.faint)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .focusable(false)
                .padding(.trailing, 7)
                .help("分组操作")
            }
            .frame(height: headerHeight)
        }
        .frame(height: headerHeight)
        .clipShape(Rectangle())
        .contextMenu {
            groupMenuContent
        }
    }

    private var headerBackground: some View {
        Theme.sidebarOpaque
    }

    @ViewBuilder
    private var groupMenuContent: some View {
        Button("重命名分组…") { onRename() }

        Menu("球样式") {
            ForEach(GroupBallStyle.allCases) { style in
                Button {
                    onStyle(style)
                } label: {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(style.gradient)
                            .frame(width: 11, height: 11)
                        Text(style.label)
                        if style == group.style {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }

        Button("管理组内会话…") { onMembers() }

        Divider()

        Button("删除分组", role: .destructive) { onDelete() }
    }
}

private struct GroupBallCutout: Identifiable, Equatable {
    var id: String
    var center: CGPoint
    var style: GroupBallStyle
    var initial: String
    var size: CGFloat
    var socketRadius: CGFloat
}

private struct GroupBallCutoutPreferenceKey: PreferenceKey {
    static var defaultValue: [GroupBallCutout] = []

    static func reduce(
        value: inout [GroupBallCutout],
        nextValue: () -> [GroupBallCutout]
    ) {
        value.append(contentsOf: nextValue())
    }
}

private struct SessionListFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .null

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isNull {
            value = next
        }
    }
}

enum TranscriptScrollDirection {
    case up
    case down
}

struct UserQuestionFrame: Equatable {
    let turnID: String
    let minY: CGFloat
    let maxY: CGFloat
}

enum QuestionSelection {
    struct Result: Equatable {
        let activeID: String?
        let visibleIDs: Set<String>
    }

    static func resolve(
        frames: [UserQuestionFrame],
        activeID: String?,
        direction: TranscriptScrollDirection,
        previousVisibleIDs: Set<String>,
        viewportHeight: CGFloat
    ) -> Result {
        guard viewportHeight > 0 else {
            return Result(activeID: activeID, visibleIDs: previousVisibleIDs)
        }

        let topEdge: CGFloat = 8
        let bottomEdge = max(topEdge + 1, viewportHeight - 8)
        let sorted = frames.sorted { $0.minY < $1.minY }
        let visible = sorted.filter {
            $0.maxY > topEdge && $0.minY < bottomEdge
        }
        let visibleIDs = Set(visible.map(\.turnID))
        let newlyVisible = visible.filter {
            !previousVisibleIDs.contains($0.turnID)
        }

        guard !visible.isEmpty else {
            return Result(activeID: activeID, visibleIDs: visibleIDs)
        }
        guard let activeID else {
            return Result(activeID: visible.first?.turnID, visibleIDs: visibleIDs)
        }

        let activeFrame = sorted.first { $0.turnID == activeID }
        var next = activeID

        switch direction {
        case .down:
            let newLower = newlyVisible.filter { frame in
                guard let activeFrame else { return true }
                return frame.minY > activeFrame.minY + 1
            }
            if let candidate = newLower.max(by: { $0.minY < $1.minY }) {
                next = candidate.turnID
            } else if !visibleIDs.contains(activeID), let last = visible.last {
                next = last.turnID
            }
        case .up:
            let newUpper = newlyVisible.filter { frame in
                guard let activeFrame else { return true }
                return frame.minY < activeFrame.minY - 1
            }
            if let candidate = newUpper.min(by: { $0.minY < $1.minY }) {
                next = candidate.turnID
            } else if !visibleIDs.contains(activeID), let first = visible.first {
                next = first.turnID
            }
        }

        return Result(activeID: next, visibleIDs: visibleIDs)
    }
}

private struct UserQuestionFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UserQuestionFrame] = []

    static func reduce(
        value: inout [UserQuestionFrame],
        nextValue: () -> [UserQuestionFrame]
    ) {
        value.append(contentsOf: nextValue())
    }
}

private struct TranscriptScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat? = nil

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() {
            value = next
        }
    }
}

private struct TranscriptViewportHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

private struct PinnedProcessInfo: Equatable {
    let turnID: String
    let summary: String
    let minY: CGFloat
    let maxY: CGFloat
}

private struct PinnedProcessPreferenceKey: PreferenceKey {
    static var defaultValue: [PinnedProcessInfo] = []

    static func reduce(
        value: inout [PinnedProcessInfo],
        nextValue: () -> [PinnedProcessInfo]
    ) {
        value.append(contentsOf: nextValue())
    }
}

private struct SessionOutlineContentFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct SessionGroupHeaderFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct PinnedBranchInfo: Equatable {
    let branchID: String
    let title: String
    let status: String
    let minY: CGFloat
    let maxY: CGFloat
}

private struct PinnedBranchPreferenceKey: PreferenceKey {
    static var defaultValue: [PinnedBranchInfo] = []

    static func reduce(
        value: inout [PinnedBranchInfo],
        nextValue: () -> [PinnedBranchInfo]
    ) {
        value.append(contentsOf: nextValue())
    }
}

private struct SessionListClip: Shape {
    var rect: CGRect

    func path(in _: CGRect) -> Path {
        guard !rect.isNull else { return Path() }
        return Path(rect)
    }
}

private struct CutoutPanelMask: Shape {
    var rings: [GroupBallCutout]
    var viewport: CGRect

    func path(in rect: CGRect) -> Path {
        let panelPath = CornerPanelShape().path(in: rect)
        var mask = panelPath.cgPath

        for ring in rings {
            guard rect.contains(ring.center) else { continue }
            var hole = socketHole(
                center: ring.center,
                radius: ring.socketRadius,
                edgeX: rect.minX,
                shoulder: 12
            )
            if !viewport.isNull {
                hole = hole.intersection(CGPath(rect: viewport, transform: nil))
            }
            mask = mask.subtracting(hole.intersection(panelPath.cgPath))
        }

        return Path(mask)
    }

    /// Cuts a bite out of the panel's left edge. The socket circle is joined to
    /// the edge by two concave shoulder arcs, so the mouth is round instead of
    /// meeting the straight edge at a sharp corner.
    private func socketHole(
        center: CGPoint,
        radius: CGFloat,
        edgeX: CGFloat,
        shoulder: CGFloat
    ) -> CGPath {
        let path = CGMutablePath()
        let filletX = edgeX + shoulder
        let dx = center.x - filletX
        guard dx > 0 else {
            return CGPath(
                ellipseIn: CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                ),
                transform: nil
            )
        }

        let filletDistance = sqrt(max(0, pow(radius + shoulder, 2) - pow(dx, 2)))
        let topFillet = CGPoint(x: filletX, y: center.y - filletDistance)
        let bottomFillet = CGPoint(x: filletX, y: center.y + filletDistance)
        let tangentScale = radius / (radius + shoulder)
        let topTangent = CGPoint(
            x: center.x + (topFillet.x - center.x) * tangentScale,
            y: center.y + (topFillet.y - center.y) * tangentScale
        )
        let bottomTangent = CGPoint(
            x: center.x + (bottomFillet.x - center.x) * tangentScale,
            y: center.y + (bottomFillet.y - center.y) * tangentScale
        )
        let overshoot: CGFloat = 2

        func point(_ around: CGPoint, _ r: CGFloat, _ degrees: CGFloat) -> CGPoint {
            let angle = degrees * .pi / 180
            return CGPoint(x: around.x + r * cos(angle), y: around.y + r * sin(angle))
        }

        func appendArc(_ around: CGPoint, _ r: CGFloat, from a0: CGFloat, to a1: CGFloat) {
            let steps = 48
            for i in 0...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let p = point(around, r, a0 + (a1 - a0) * t)
                if path.isEmpty {
                    path.move(to: p)
                } else {
                    path.addLine(to: p)
                }
            }
        }

        func angle(_ from: CGPoint, _ to: CGPoint) -> CGFloat {
            atan2(to.y - from.y, to.x - from.x) * 180 / .pi
        }

        path.move(to: CGPoint(x: edgeX, y: center.y - filletDistance))
        appendArc(
            topFillet,
            shoulder,
            from: 180,
            to: angle(topFillet, topTangent)
        )
        appendArc(
            center,
            radius,
            from: angle(center, topTangent),
            to: angle(center, bottomTangent)
        )
        let bottomExit = angle(bottomFillet, bottomTangent)
        appendArc(
            bottomFillet,
            shoulder,
            from: bottomExit < 0 ? bottomExit + 360 : bottomExit,
            to: 180
        )
        path.addLine(to: CGPoint(x: edgeX - overshoot, y: center.y + filletDistance))
        path.addLine(to: CGPoint(x: edgeX - overshoot, y: center.y - filletDistance))
        path.closeSubpath()
        return path
    }
}

// MARK: - Search

private func searchSnippetText(_ hit: ContentSearchHit) -> AttributedString {
    var result = AttributedString(hit.before)
    result.foregroundColor = Theme.textSoft

    var matched = AttributedString(hit.matched)
    matched.foregroundColor = Theme.accent
    matched.backgroundColor = Theme.searchHighlight
    matched.inlinePresentationIntent = .stronglyEmphasized

    var tail = AttributedString(hit.after)
    tail.foregroundColor = Theme.textSoft

    result.append(matched)
    result.append(tail)
    return result
}

private func searchDateLabel(_ date: Date?) -> String {
    guard let date else { return "" }
    let calendar = Calendar.current
    if calendar.isDateInToday(date) || calendar.isDateInYesterday(date) {
        return date.timeLabel
    }
    return date.shortDateLabel
}

private struct SearchSessionRow: View {
    let result: ContentSearchSessionResult
    let session: SessionSummary?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(session?.displayTitle ?? "未命名会话")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Text("\(result.count) 处")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Theme.accentDeep)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Theme.accentSoft))
                        .fixedSize()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.faint)
                }

                if let latest = result.latest {
                    Text(searchSnippetText(latest))
                        .font(.system(size: 11, weight: .regular))
                        .lineSpacing(3)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                HStack(spacing: 6) {
                    if let latest = result.latest {
                        Text(latest.entry.role.label)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.muted)
                        Circle()
                            .fill(Theme.faint.opacity(0.55))
                            .frame(width: 2.5, height: 2.5)
                    }
                    if result.chainIDs.count > 1 {
                        Text("链 \(result.chainIDs.count) 段")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.accentDeep)
                        Circle()
                            .fill(Theme.faint.opacity(0.55))
                            .frame(width: 2.5, height: 2.5)
                    }
                    Text(searchDateLabel(result.latest?.entry.timestamp ?? session?.date))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.faint)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(hovering ? Theme.subtleFill : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
    }
}

private struct SearchMatchRow: View {
    let hit: ContentSearchHit
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(isSelected ? Theme.accent : Color.clear)
                    .frame(width: 3)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Text(hit.entry.role.label)
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(hit.entry.role == .user ? Theme.accentDeep : Theme.muted)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(
                                    hit.entry.role == .user ? Theme.accentSoft : Theme.subtleFill
                                )
                            )
                            .fixedSize()

                        Spacer(minLength: 4)

                        Text(searchDateLabel(hit.entry.timestamp))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Theme.faint)
                    }

                    Text(searchSnippetText(hit))
                        .font(.system(size: 11.5, weight: .regular))
                        .lineSpacing(3)
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? Theme.accentSoft : (hovering ? Theme.subtleFill : Color.clear))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? Theme.accentLine : Color.clear, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
    }
}

private struct SearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.muted)

            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.text)
                .focused(focused)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.faint)
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Capsule().fill(Theme.panelLift.opacity(0.86)))
        .overlay {
            Capsule().stroke(
                focused.wrappedValue ? Theme.accentLine : Theme.glassBorder,
                lineWidth: 1
            )
        }
        .shadow(color: Theme.cardShadow, radius: 10, y: 4)
    }
}

// MARK: - Reading canvas

private struct ReadingCanvas: View {
    @ObservedObject var model: AppModel
    var referenceWidth: CGFloat = 0
    @EnvironmentObject private var settings: AppSettings
    @State private var toast: String?
    @State private var showingGallery = false
    @State private var showingStorage = false
    @State private var showingDeleteArchive = false
    @State private var archiveDeletionTargetID: String?
    @State private var renamingSession: SessionSummary?
    @State private var scrollTarget: String?
    @State private var pinnedProcess: PinnedProcessInfo?
    @State private var pinnedBranch: PinnedBranchInfo?
    @State private var transcriptViewportHeight: CGFloat = 0
    @State private var lastTranscriptOffset: CGFloat?
    @State private var transcriptScrollDirection: TranscriptScrollDirection = .down
    @State private var questionFrames: [UserQuestionFrame] = []
    @State private var previousVisibleQuestionIDs: Set<String> = []
    @State private var activeQuestionRefreshScheduled = false

    /// The reading canvas can grow into the sidebar's space, but its text
    /// column is measured against the sidebar-visible pane so collapsing the
    /// sidebar never reflows the text. Window resizing still changes it.
    private var columnWidth: CGFloat {
        guard referenceWidth > 0 else { return 760 }
        return max(referenceWidth - 284 - 68, 520)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                header
                    .frame(maxWidth: columnWidth, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 34)
            .padding(.top, 22)
            .padding(.bottom, 18)

            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Rectangle()
                    .fill(Theme.divider)
                    .frame(maxWidth: columnWidth)
                    .frame(height: 1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 34)

            content
        }
        .sheet(isPresented: $showingGallery) {
            ImageGallerySheet(images: model.conversation?.images ?? []) { ref in
                focusImage(ref)
            }
        }
        .sheet(isPresented: $showingStorage) {
            StorageSettingsView(model: model)
        }
        .sheet(item: $renamingSession) { session in
            NameEditorSheet(
                title: "重命名会话",
                fieldLabel: "名称",
                initialValue: session.displayTitle,
                note: "只修改 CCJV 里的显示名，不改原始 .jsonl 文件名，避免影响 Claude Code 的 resume 和子代理目录。",
                confirmLabel: "保存"
            ) { name in
                model.renameSession(session.id, to: name)
            }
        }
        .alert("删除此会话的归档？", isPresented: $showingDeleteArchive) {
            Button("删除", role: .destructive) {
                if let id = archiveDeletionTargetID {
                    model.deleteArchivedSession(id)
                }
                archiveDeletionTargetID = nil
            }
            Button("取消", role: .cancel) {
                archiveDeletionTargetID = nil
            }
        } message: {
            Text(model.archiveDeleteMessage(for: archiveDeletionTargetID))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("会话记录")
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(1.4)
                        .foregroundStyle(Theme.muted)

                    Text(title)
                        .font(.system(size: 28, weight: .semibold))
                        .tracking(-0.5)
                        .foregroundStyle(Theme.text)
                        .lineLimit(2)

                    Text(subtitle)
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                actions
            }

            if let conversation = model.conversation {
                summaryPills(conversation)
            }

            if model.conversationNeedsRefresh {
                refreshNotice
            }

            if model.readingMode == .segment,
               model.chainIsMerged(model.selectedID) {
                segmentModeNotice
            } else if let lineage = selectedLineage,
                      lineage.parentID != nil
                        || lineage.isAmbiguous
                        || lineage.isContinuationSegment
                        || model.isLinkBroken(model.selectedID)
                        || !model.strongChildren(of: lineage.parentID ?? model.selectedID ?? "").isEmpty
                        || (model.conversation?.segments.count ?? 0) > 1 {
                lineageNotice(lineage, conversation: model.conversation)
            }

            if let toast {
                Text(toast)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.green)
                    .transition(.opacity)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                copyResume()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "terminal")
                        .font(.system(size: 11, weight: .semibold))
                    Text("在终端继续")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(Theme.accentInk)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(Capsule().fill(Theme.orangeGradient))
                .shadow(color: Theme.accent.opacity(0.20), radius: 12, y: 5)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .disabled(model.selectedID == nil || isArchivedSession)
            .opacity(model.selectedID == nil || isArchivedSession ? 0.5 : 1)
            .help(
                isArchivedSession
                    ? "当前段没有可恢复的原始 JSON（归档或已被清理），无法继续"
                    : ((model.conversation?.segments.count ?? 0) > 1
                        ? "复制本段 resume 命令；终端只恢复本段，前段已在 App 内合并显示"
                        : "复制 resume 命令并在终端继续")
            )

            Menu {
                Button("重命名会话…") {
                    if let summary = model.selectedSummary {
                        renamingSession = summary
                    }
                }
                .disabled(model.selectedID == nil)

                if let id = model.selectedID, model.customName(for: id) != nil {
                    Button("恢复原标题") {
                        model.renameSession(id, to: "")
                    }
                }

                Button("刷新会话") { model.reloadSelected() }
                if let id = model.selectedID {
                    if model.lineageInfo(for: id)?.parentID != nil {
                        Button("断开与前段的续接") {
                            model.breakContinuationLink(id)
                            show("已断开续接")
                        }
                    } else if model.isLinkBroken(id) {
                        Button("恢复自动续接") {
                            model.restoreContinuationLink(id)
                            show("已恢复自动续接")
                        }
                    }
                }
                if let id = model.selectedID, model.hasArchivedCopy(id) {
                    Button(model.isArchivePinned(id) ? "取消保留此链" : "保留此链（防容量淘汰）") {
                        model.toggleArchivePin(id)
                        show(model.isArchivePinned(id) ? "已保留此链" : "已取消保留")
                    }
                    Button("删除此归档", role: .destructive) {
                        archiveDeletionTargetID = model.selectedID
                        showingDeleteArchive = true
                    }
                }
                Divider()
                Button("复制 resume 命令") { copyResume() }
                    .disabled(isArchivedSession)
                Button(isArchivedSession ? "复制归档文件夹路径" : "复制会话路径") {
                    if isArchivedSession {
                        copy(ArchiveStore.archiveFolderURL.path)
                        show("已复制归档路径")
                    } else {
                        copyPath()
                    }
                }
                Button("复制对话文本") { copyTranscript() }

                Divider()

                Button("存储与归档…") { showingStorage = true }

                Button(settings.darkMode ? "切换到浅色外观" : "切换到深色外观") {
                    settings.setDark(!settings.darkMode)
                }

                ForEach(AccentTheme.allCases) { theme in
                    Button {
                        settings.setAccent(theme)
                    } label: {
                        HStack {
                            Text(theme.label)
                            if settings.accent == theme {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textSoft)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Theme.panelLift))
                    .overlay(Circle().stroke(Theme.glassBorder, lineWidth: 1))
                    .shadow(color: Theme.cardShadow, radius: 8, y: 3)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .focusable(false)
            .help("会话操作")
        }
    }

    private var title: String {
        model.conversation?.session.displayTitle
            ?? model.selectedSummary?.displayTitle
            ?? "CCJV"
    }

    private var isArchivedSession: Bool {
        guard let id = model.selectedID else { return false }
        return !model.canResume(id)
    }

    private var selectedLineage: SessionLineage? {
        model.lineageInfo(for: model.selectedID)
    }

    private var subtitle: String {
        if let conversation = model.conversation {
            let id = String(conversation.session.id.prefix(8))
            let archive = conversation.session.isArchived ? " · 归档问答" : ""
            return "\(conversation.session.project) · \(id) · \(conversation.session.date.relativeDayLabel) · 只读\(archive)"
        }
        if let summary = model.selectedSummary {
            let id = String(summary.id.prefix(8))
            let archive = summary.isArchived ? " · 归档问答" : ""
            return "\(summary.project) · \(id) · 只读\(archive)"
        }
        return "本机 Claude Code 会话 · 只读"
    }

    private func summaryPills(_ conversation: Conversation) -> some View {
        HStack(spacing: 8) {
            statPill("轮次", "\(conversation.turns.count)")

            if conversation.session.isArchived {
                statPill("来源", "归档")
                    .help("原始 JSON 已被清理；当前内容来自 CCJV 本地归档。")
            }

            if model.hasArchivedCopy(conversation.session.id),
               model.isArchivePinned(conversation.session.id) {
                statPill("归档", "已保留")
                    .help("这条续接链不会因归档容量上限被自动淘汰。")
            }

            if let lineage = model.lineageInfo(for: conversation.session.id) {
                if model.isLinkBroken(conversation.session.id) {
                    brokenLinkPill(conversation.session.id)
                } else if let parentID = lineage.parentID {
                    lineagePill(
                        parentID: parentID,
                        lineage: lineage,
                        conversation: conversation
                    )
                } else if lineage.isAmbiguous {
                    statPill("续接", "多候选")
                        .help("检测到续接边界，但有多个候选前段，未自动关联。")
                } else if lineage.isContinuationSegment {
                    statPill("续接", "前段未找到")
                        .help("本段开头有续接边界；本地归档里没有找到对应前段。")
                }

                if lineage.checkpointCount > 0 {
                    statPill("压缩", "\(lineage.checkpointCount) 次")
                        .help("本段内发生的上下文压缩次数；压缩不会改变本段 session ID。")
                }
            }

            if conversation.segments.count > 1,
               model.lineageInfo(for: conversation.session.id)?.parentID == nil {
                statPill("合并", "\(conversation.segments.count) 段")
                    .help("后续段已并入下方；终端 resume 只恢复本段。")
            }

            if conversation.branchCount > 0 {
                statPill("子代理", "\(conversation.branchCount)")
            }

            if conversation.imageCount > 0 {
                Button {
                    showingGallery = true
                } label: {
                    HStack(spacing: 7) {
                        Text("图片")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Theme.muted)
                        Text("\(conversation.imageCount)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .monospacedDigit()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.faint)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 38)
                    .background(Capsule().fill(Theme.panel.opacity(0.74)))
                    .overlay(Capsule().stroke(Theme.glassBorder, lineWidth: 1))
                    .shadow(color: Theme.cardShadow, radius: 8, y: 3)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("查看本会话全部图片")
            }

            Spacer(minLength: 0)
        }
    }

    private func statPill(_ label: String, _ value: String) -> some View {
        HStack(spacing: 7) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.muted)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(Capsule().fill(Theme.panel.opacity(0.74)))
        .overlay(Capsule().stroke(Theme.glassBorder, lineWidth: 1))
        .shadow(color: Theme.cardShadow, radius: 8, y: 3)
    }

    private func lineageParentTitle(_ id: String) -> String {
        guard let session = model.sessions.first(where: { $0.id == id }) else {
            return "会话 \(id.prefix(8))"
        }
        let title = session.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty || title.hasPrefix("http://") || title.hasPrefix("https://") {
            return "会话 \(session.id.prefix(8))"
        }
        return title
    }

    private var refreshNotice: some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.clockwise.circle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.accentDeep)
            Text("这条链有新的会话内容")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textSoft)
            Spacer(minLength: 0)
            Button("刷新") {
                model.reloadSelected()
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .focusable(false)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.accentSoft.opacity(0.7))
        )
    }

    private var segmentModeNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.accentDeep)
            Text("正在单独查看本段完整内容；合并阅读会按续接点截断本段，这里保留全部回合。")
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(Theme.faint)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button("返回合并") {
                model.showMergedSelection()
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .focusable(false)
        }
    }

    @ViewBuilder
    private func lineageNotice(
        _ lineage: SessionLineage,
        conversation: Conversation?
    ) -> some View {
        let merged = (conversation?.segments.count ?? 0) > 1
        let anchorID = conversation?.session.id ?? model.selectedID ?? ""
        let children = model.strongChildren(of: anchorID)

        if model.isLinkBroken(anchorID) {
            HStack(spacing: 6) {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 9, weight: .semibold))
                Text("已手动断开与前段的自动续接；终端 resume 只恢复本段。")
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 10, weight: .regular))
            .foregroundStyle(Theme.faint)
        } else if lineage.parentID == nil, !merged, children.count > 1 {
            HStack(spacing: 7) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9, weight: .semibold))
                Text("有 \(children.count) 个续接分支，未自动合并：")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(Theme.faint)
                ForEach(children, id: \.self) { childID in
                    Button(lineageParentTitle(childID)) {
                        model.select(childID)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.accentDeep)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.accentSoft))
                    .focusable(false)
                    .help("打开父段与这个分支的合并阅读；终端 resume 只恢复该分支。")
                }
                Spacer(minLength: 0)
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "link")
                    .font(.system(size: 9, weight: .semibold))
                Text(lineageNoticeText(lineage, merged: merged))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 10, weight: .regular))
            .foregroundStyle(Theme.faint)
        }
    }

    private func lineageNoticeText(_ lineage: SessionLineage, merged: Bool) -> String {
        if let parentID = lineage.parentID {
            let parentTitle = lineageParentTitle(parentID)
            return merged
                ? "前段「\(parentTitle)」已并入上方；终端 resume 只恢复本段。"
                : "检测到疑似前段「\(parentTitle)」，但未自动合并；终端 resume 只恢复本段。"
        }
        if merged, !lineage.children.isEmpty {
            return "后续 \(lineage.children.count) 段已并入下方；终端 resume 只恢复本段。"
        }
        if lineage.isAmbiguous {
            return "检测到续接边界，但有多个候选前段，未自动关联。"
        }
        return "检测到续接边界，但本地归档里没有找到前段；终端 resume 仍只恢复本段。"
    }

    private func brokenLinkPill(_ id: String) -> some View {
        Button {
            model.restoreContinuationLink(id)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.muted)
                Text("续接已断开")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.muted)
                Text("恢复")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 13)
            .frame(height: 38)
            .background(Capsule().fill(Theme.panel.opacity(0.74)))
            .overlay(Capsule().stroke(Theme.glassBorder, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("已手动关闭自动识别的续接关系；点击重新按 UUID 证据关联。")
    }

    private func lineagePill(
        parentID: String,
        lineage: SessionLineage,
        conversation: Conversation
    ) -> some View {
        let parentTitle = lineageParentTitle(parentID)
        let merged = conversation.segments.contains { $0.id == parentID }
        return Button {
            guard merged else { return }
            scrollTarget = "segment-\(parentID)"
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "link")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.accentDeep)
                Text(merged ? "已合并前段" : (lineage.isStrong ? "续接自" : "疑似续接自"))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.muted)
                Text(parentTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .frame(maxWidth: 150, alignment: .leading)
                if merged {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(Theme.faint)
                }
            }
            .padding(.horizontal, 13)
            .frame(height: 38)
            .background(Capsule().fill(Theme.panel.opacity(0.74)))
            .overlay(Capsule().stroke(Theme.accentLine, lineWidth: 1))
            .shadow(color: Theme.cardShadow, radius: 8, y: 3)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(
            merged
                ? "前段已并入当前阅读；点击跳到前段开头。终端 resume 仍只恢复本段。"
                : "共享消息 UUID \(lineage.evidence) 条。前段还没有合并到当前阅读。"
        )
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            loadingState
        } else if let conversation = model.conversation {
            transcript(conversation)
        } else {
            emptyState
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
                .tint(Theme.accent)
            Text("正在解析会话…")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Theme.accentSoft)
                    .frame(width: 64, height: 64)
                Image(systemName: "text.bubble")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(Theme.accent)
            }

            Text("选择一个会话")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.text)

            Text("左侧是本机 Claude Code 历史，只读，不会上传。")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func transcriptDateLabel(_ conversation: Conversation) -> String {
        let end = conversation.endedAt ?? conversation.session.date
        guard let start = conversation.startedAt, start <= end else {
            return end.dayLabel
        }
        let calendar = Calendar.current
        guard !calendar.isDate(start, inSameDayAs: end) else {
            return end.dayLabel
        }
        return "\(start.shortDateLabel) – \(end.shortDateLabel)"
    }

    private func timestamp(of item: ConversationItem?) -> Date? {
        guard let item else { return nil }
        switch item {
        case .user(_, _, let timestamp): return timestamp
        case .assistant(_, _, _, let timestamp): return timestamp
        case .tool(_, _, let timestamp): return timestamp
        default: return nil
        }
    }

    private func turnDate(_ turn: TurnGroup) -> Date? {
        if let date = timestamp(of: turn.user) { return date }
        if let date = turn.process.compactMap({ timestamp(of: $0) }).first { return date }
        return timestamp(of: turn.answer)
    }

    private func dayDividerLabel(_ conversation: Conversation, at index: Int) -> String? {
        guard index > 0,
              let current = turnDate(conversation.turns[index]),
              let previous = turnDate(conversation.turns[index - 1]) else {
            return nil
        }
        guard !Calendar.current.isDate(current, inSameDayAs: previous) else {
            return nil
        }
        return current.dayLabel
    }

    private func segmentDivider(_ segment: ConversationSegment) -> some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(Theme.divider)
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.accentDeep)
                    Text(segment.roleLabel)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Theme.accentDeep)
                    Text(segmentTitle(segment))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.textSoft)
                        .lineLimit(1)
                    Text(String(segment.sessionID.prefix(8)))
                        .font(.system(size: 9, weight: .medium))
                        .monospaced()
                        .foregroundStyle(Theme.faint)
                    if segment.isArchived {
                        Text("归档")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(Theme.muted)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Theme.subtleFill))
                    }
                }
                Text(
                    "\(segmentDateLabel(segment)) · \(segment.turnCount) 轮"
                        + (segment.omittedTurnCount > 0 ? " · 另 \(segment.omittedTurnCount) 轮" : "")
                )
                .font(.system(size: 9, weight: .regular))
                .foregroundStyle(Theme.faint)
                .help(
                    segment.omittedTurnCount > 0
                        ? "续接点之后另有 \(segment.omittedTurnCount) 轮未并入当前线性链；可用「完整本段」查看。"
                        : ""
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.panel.opacity(0.72))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.glassBorder.opacity(0.8), lineWidth: 1)
            }
            .fixedSize(horizontal: false, vertical: true)

            Button {
                model.selectSegment(segment.sessionID)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 8.5, weight: .semibold))
                    Text("完整本段")
                        .font(.system(size: 9.5, weight: .semibold))
                }
                .foregroundStyle(Theme.accentDeep)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(Capsule().fill(Theme.accentSoft.opacity(0.8)))
                .overlay(Capsule().stroke(Theme.accentLine, lineWidth: 0.8))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("单独查看这一段原始会话，包含续接点之后未并入链的回合。")

            Rectangle()
                .fill(Theme.divider)
                .frame(height: 1)
        }
        .id("segment-\(segment.id)")
        .help("点击「已合并前段」可回到这里。")
    }

    private func segmentTitle(_ segment: ConversationSegment) -> String {
        let title = segment.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty,
              !title.hasPrefix("http://"),
              !title.hasPrefix("https://"),
              title != "未命名会话" else {
            return "会话"
        }
        return title
    }

    private func segmentDateLabel(_ segment: ConversationSegment) -> String {
        guard let start = segment.startDate else { return "时间未知" }
        guard let end = segment.endDate,
              !Calendar.current.isDate(start, inSameDayAs: end) else {
            return start.shortDateLabel
        }
        return "\(start.shortDateLabel) – \(end.shortDateLabel)"
    }

    private func transcript(_ conversation: Conversation) -> some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                HStack(alignment: .top, spacing: 0) {
                    Spacer(minLength: 0)

                    LazyVStack(alignment: .leading, spacing: 26) {
                        HStack {
                            Spacer()
                            Text(transcriptDateLabel(conversation))
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Theme.muted)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(Theme.subtleFill))
                                .overlay(Capsule().stroke(Theme.glassBorder.opacity(0.65), lineWidth: 1))
                            Spacer()
                        }
                        .id("transcript-top")

                        ForEach(Array(conversation.turns.enumerated()), id: \.element.id) { index, turn in
                            if let segment = conversation.segmentStarts[turn.id] {
                                segmentDivider(segment)
                            }

                            if conversation.segmentStarts[turn.id] == nil,
                               let dayLabel = dayDividerLabel(conversation, at: index) {
                                HStack(spacing: 10) {
                                    Rectangle()
                                        .fill(Theme.divider)
                                        .frame(height: 1)
                                    Text(dayLabel)
                                        .font(.system(size: 9.5, weight: .medium))
                                        .foregroundStyle(Theme.faint)
                                        .fixedSize()
                                    Rectangle()
                                        .fill(Theme.divider)
                                        .frame(height: 1)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 2)
                            }

                            TurnView(turn: turn, model: model, contentWidth: columnWidth) { itemID in
                                withAnimation(.snappy(duration: 0.28)) {
                                    proxy.scrollTo("item-\(itemID)", anchor: .center)
                                }
                            }
                            .id(turn.id)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("transcript-bottom")
                    }
                    .frame(maxWidth: columnWidth, alignment: .leading)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 34)
                .padding(.top, 24)
                .padding(.bottom, 64)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: TranscriptScrollOffsetPreferenceKey.self,
                            value: proxy.frame(in: .named("transcriptScroll")).minY
                        )
                    }
                }
            }
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: TranscriptViewportHeightPreferenceKey.self,
                        value: proxy.size.height
                    )
                }
            }
            .coordinateSpace(name: "transcriptScroll")
            .onChange(of: conversation.session.id) { _, _ in
                pinnedProcess = nil
                pinnedBranch = nil
                questionFrames = []
                previousVisibleQuestionIDs = []
                lastTranscriptOffset = nil
            }
            .onChange(of: model.readingMode) { _, _ in
                questionFrames = []
                previousVisibleQuestionIDs = []
                lastTranscriptOffset = nil
            }
            .onPreferenceChange(UserQuestionFramePreferenceKey.self) { frames in
                questionFrames = frames
                scheduleActiveQuestionRefresh()
            }
            .onPreferenceChange(TranscriptScrollOffsetPreferenceKey.self) { offset in
                guard let offset else { return }
                if let previous = lastTranscriptOffset {
                    let delta = offset - previous
                    if delta < -0.5 {
                        transcriptScrollDirection = .down
                    } else if delta > 0.5 {
                        transcriptScrollDirection = .up
                    }
                }
                lastTranscriptOffset = offset
                scheduleActiveQuestionRefresh()
            }
            .onPreferenceChange(TranscriptViewportHeightPreferenceKey.self) { height in
                guard height > 0, height != transcriptViewportHeight else { return }
                transcriptViewportHeight = height
                scheduleActiveQuestionRefresh()
            }
            .onPreferenceChange(PinnedProcessPreferenceKey.self) { infos in
                let active = infos
                    .filter { $0.minY < -8 && $0.maxY > 8 }
                    .max { $0.minY < $1.minY }
                if active != pinnedProcess {
                    pinnedProcess = active
                }
            }
            .onPreferenceChange(PinnedBranchPreferenceKey.self) { infos in
                let active = infos
                    .filter { $0.minY < -8 && $0.maxY > 8 }
                    .max { $0.minY < $1.minY }
                if active != pinnedBranch {
                    pinnedBranch = active
                }
            }
            .overlay(alignment: .top) {
                VStack(spacing: 6) {
                    if let pinnedProcess {
                        pinnedProcessHeader(pinnedProcess, proxy: proxy)
                            .transition(.opacity)
                    }
                    if let pinnedBranch {
                        pinnedBranchHeader(pinnedBranch, proxy: proxy)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 34)
                .padding(.top, 8)
            }
            .overlay(alignment: .bottomTrailing) {
                VStack(spacing: 6) {
                    navButton("arrow.up.to.line", help: "回到顶部") {
                        withAnimation(.snappy(duration: 0.25)) {
                            proxy.scrollTo("transcript-top", anchor: .top)
                        }
                    }
                    navButton("arrow.down.to.line", help: "到底部") {
                        withAnimation(.snappy(duration: 0.25)) {
                            proxy.scrollTo("transcript-bottom", anchor: .bottom)
                        }
                    }
                }
                .padding(20)
            }
            .task(id: "\(conversation.session.id)-\(conversation.segments.count)") {
                guard conversation.segments.count > 1,
                      model.searchFocus == nil,
                      model.turnFocus == nil,
                      model.imageFocus == nil else { return }
                try? await Task.sleep(nanoseconds: 320_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.snappy(duration: 0.25)) {
                    proxy.scrollTo("segment-\(conversation.session.id)", anchor: .top)
                }
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.snappy(duration: 0.25)) {
                    proxy.scrollTo(target, anchor: .top)
                }
                scrollTarget = nil
            }
            .onChange(of: model.jumpToBranchID) { _, branchId in
                guard let branchId else { return }
                let turnID = conversation.turns.first { turn in
                    turn.branches.contains { $0.id == branchId }
                }?.id

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                    withAnimation(.snappy(duration: 0.25)) {
                        if let turnID {
                            proxy.scrollTo(turnID, anchor: .top)
                        } else {
                            proxy.scrollTo("b-\(branchId)", anchor: .center)
                        }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    model.jumpToBranchID = nil
                }
            }
            .task(id: model.searchFocus?.id) {
                guard let focus = model.searchFocus,
                      focus.sessionID == conversation.session.id else { return }

                try? await Task.sleep(nanoseconds: 320_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.snappy(duration: 0.28)) {
                    proxy.scrollTo(focus.turnID, anchor: .center)
                }

                try? await Task.sleep(nanoseconds: 220_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.snappy(duration: 0.28)) {
                    proxy.scrollTo("hit-\(focus.itemID)", anchor: .center)
                }
            }
            .task(id: model.imageFocus?.id) {
                guard let focus = model.imageFocus,
                      focus.sessionID == conversation.session.id,
                      let turn = conversation.turns.first(where: { turn in
                          turn.process.contains { $0.id == focus.itemID }
                      }) else { return }

                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.snappy(duration: 0.28)) {
                    proxy.scrollTo(turn.id, anchor: .top)
                }

                try? await Task.sleep(nanoseconds: 900_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.snappy(duration: 0.28)) {
                    proxy.scrollTo("item-\(focus.itemID)", anchor: .center)
                }

                try? await Task.sleep(nanoseconds: 450_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.snappy(duration: 0.28)) {
                    proxy.scrollTo("item-\(focus.itemID)", anchor: .center)
                }
            }
            .task(id: "\(model.turnFocus?.id.uuidString ?? "none")-\(conversation.session.id)") {
                guard let focus = model.turnFocus,
                      focus.sessionID == conversation.session.id else { return }

                try? await Task.sleep(nanoseconds: 220_000_000)
                guard !Task.isCancelled else { return }
                proxy.scrollTo(focus.turnID, anchor: .top)

                for index in 0..<2 {
                    try? await Task.sleep(nanoseconds: index == 0 ? 250_000_000 : 400_000_000)
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo("question-\(focus.turnID)", anchor: .top)
                }

                // Lazy layout can settle after the first two jumps and leave
                // the question just above/below the top edge. Re-assert only
                // when its measured frame is not at the top.
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled else { return }
                let frame = questionFrames.first { $0.turnID == focus.turnID }
                if frame == nil || frame!.minY > 32 || frame!.minY < -4 {
                    proxy.scrollTo("question-\(focus.turnID)", anchor: .top)
                }
            }
        }
    }

    private func focusImage(_ ref: ImageRef) {
        guard let conversation = model.conversation,
              let item = conversation.items.first(where: { item in
                  if case .image(_, let imageRef) = item {
                      return imageRef.id == ref.id
                  }
                  return false
              }) else { return }

        model.focusImage(itemID: item.id, sessionID: conversation.session.id)
    }

    private func scheduleActiveQuestionRefresh() {
        guard !activeQuestionRefreshScheduled else { return }
        activeQuestionRefreshScheduled = true
        DispatchQueue.main.async {
            activeQuestionRefreshScheduled = false
            refreshActiveQuestion()
        }
    }

    private func refreshActiveQuestion() {
        guard transcriptViewportHeight > 0 else { return }
        let result = QuestionSelection.resolve(
            frames: questionFrames,
            activeID: model.activeTurnID,
            direction: transcriptScrollDirection,
            previousVisibleIDs: previousVisibleQuestionIDs,
            viewportHeight: transcriptViewportHeight
        )
        previousVisibleQuestionIDs = result.visibleIDs
        if let activeID = result.activeID {
            model.setActiveTurn(activeID)
        }
    }

    private func pinnedProcessHeader(
        _ info: PinnedProcessInfo,
        proxy: ScrollViewProxy
    ) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Theme.accentSoft)
                    )

                Text("过程")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.textSoft)

                Text(info.summary)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.to.line")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: columnWidth, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.sidebarOpaque)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Theme.glassBorder, lineWidth: 1)
            }
            .shadow(color: Theme.cardShadow, radius: 10, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .onTapGesture {
                withAnimation(.snappy(duration: 0.25)) {
                    proxy.scrollTo("process-\(info.turnID)", anchor: .top)
                }
            }
            .help("过程已置顶；点击回到过程开头。")
            .frame(maxWidth: columnWidth, alignment: .leading)
            Spacer(minLength: 0)
        }
        .animation(.easeOut(duration: 0.12), value: info)
    }

    private func pinnedBranchHeader(
        _ info: PinnedBranchInfo,
        proxy: ScrollViewProxy
    ) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.orange)
                Text("子代理 · \(info.title)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(info.status)
                    .font(.system(size: 8.8, weight: .medium))
                    .foregroundStyle(Theme.muted)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.to.line")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: columnWidth, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.sidebarOpaque)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Theme.orange.opacity(0.22), lineWidth: 1)
            }
            .shadow(color: Theme.cardShadow, radius: 9, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .onTapGesture {
                withAnimation(.snappy(duration: 0.25)) {
                    proxy.scrollTo("branch-\(info.branchID)", anchor: .top)
                }
            }
            .help("子代理已置顶；点击回到子代理开头。")
            .frame(maxWidth: columnWidth, alignment: .leading)
            Spacer(minLength: 0)
        }
    }

    private func navButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.textSoft)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Theme.panelLift.opacity(0.92)))
                .overlay(Circle().stroke(Theme.glassBorder.opacity(0.8), lineWidth: 1))
                .shadow(color: Theme.cardShadow, radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(help)
    }

    private func copyResume() {
        guard let id = model.selectedID else { return }
        guard model.canResume(id) else {
            model.reloadSelected()
            show("原始文件已不存在，无法继续")
            return
        }
        copy("claude --resume \(id)")
        show("已复制 resume 命令")
    }

    private func copyPath() {
        guard let path = model.conversation?.session.fileURL.path ?? model.selectedSummary?.fileURL.path else { return }
        copy(path)
        show("已复制会话路径")
    }

    private func copyTranscript() {
        guard let conversation = model.conversation else { return }
        copy(exportText(conversation))
        show("已复制对话文本")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func show(_ text: String) {
        withAnimation(.easeOut(duration: 0.15)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation(.easeIn(duration: 0.2)) { toast = nil }
        }
    }

    private func exportText(_ conversation: Conversation) -> String {
        var lines: [String] = []
        for item in conversation.items {
            switch item {
            case .user(_, let text, _):
                lines.append("你：\(text)")
            case .assistant(_, let text, _, _):
                lines.append("Claude：\(text)")
            case .compaction(_, let pre, let post):
                lines.append("[上下文压缩 \(pre) → \(post)]")
            case .branch(_, let node):
                lines.append("[子代理：\(node.title)]")
                if let report = node.report, !report.isEmpty {
                    lines.append("子代理回答：\(report)")
                }
            default:
                break
            }
        }
        return lines.joined(separator: "\n\n")
    }
}

private struct TurnView: View {
    let turn: TurnGroup
    @ObservedObject var model: AppModel
    let contentWidth: CGFloat
    var onImageAppeared: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let user = turn.user {
                if isInterruption(user) {
                    interruptionNotice(user)
                } else {
                    VStack(alignment: .trailing, spacing: 8) {
                        if isHit(user) { hitBadge }
                        TranscriptItemView(item: user, highlightQuery: model.searchHighlightQuery)
                            .id("hit-\(user.id)")
                            .background { hitBackdrop(user) }
                            .frame(maxWidth: min(600, contentWidth), alignment: .trailing)
                    }
                    .background {
                        GeometryReader { proxy in
                            let frame = proxy.frame(in: .named("transcriptScroll"))
                            Color.clear.preference(
                                key: UserQuestionFramePreferenceKey.self,
                                value: isQuestion(user) ? [
                                    UserQuestionFrame(
                                        turnID: turn.id,
                                        minY: frame.minY,
                                        maxY: frame.maxY
                                    )
                                ] : []
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .id("question-\(turn.id)")
                }
            }

            if !turn.process.isEmpty {
                ProcessGroupView(turn: turn, model: model, onImageAppeared: onImageAppeared)
                    .frame(maxWidth: contentWidth, alignment: .leading)
            }

            if let answer = turn.answer {
                VStack(alignment: .leading, spacing: 8) {
                    if isHit(answer) { hitBadge }
                    TranscriptItemView(item: answer, highlightQuery: model.searchHighlightQuery)
                        .id("hit-\(answer.id)")
                        .background { hitBackdrop(answer) }
                }
                .frame(maxWidth: contentWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !turn.afterAnswer.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(turn.afterAnswer) { item in
                        TranscriptItemView(item: item, highlightQuery: model.searchHighlightQuery)
                            .id("hit-\(item.id)")
                            .background { hitBackdrop(item) }
                    }
                }
                .frame(maxWidth: contentWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if turn.answer == nil {
                WaitingCard(running: turn.isRunning, model: model)
                    .frame(maxWidth: contentWidth, alignment: .leading)
            }
        }
    }

    private func isHit(_ item: ConversationItem) -> Bool {
        model.highlightedItemID == item.id
    }

    private func isInterruption(_ item: ConversationItem) -> Bool {
        guard case .user(_, let text, _) = item else { return false }
        return isInterruptionText(text)
    }

    private func isQuestion(_ item: ConversationItem) -> Bool {
        guard case .user(_, let text, _) = item else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !isInterruptionText(trimmed)
    }

    @ViewBuilder
    private func interruptionNotice(_ item: ConversationItem) -> some View {
        let timestamp: Date? = {
            if case .user(_, _, let timestamp) = item { return timestamp }
            return nil
        }()

        HStack(spacing: 7) {
            Image(systemName: "stop.circle")
                .font(.system(size: 9.5, weight: .semibold))
            Text("你中断了这次回复")
                .font(.system(size: 9.5, weight: .medium))
            if let timestamp {
                Text(timestamp.timeLabel)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(Theme.faint)
            }
        }
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Theme.subtleFill))
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func hitBackdrop(_ item: ConversationItem) -> some View {
        if isHit(item) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Theme.accentSoft.opacity(0.7))
                .padding(-9)
        }
    }

    private var hitBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 9, weight: .semibold))
            Text("搜索命中 · \(model.query)")
                .font(.system(size: 9.5, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(Theme.accentSoft))
        .overlay(Capsule().stroke(Theme.accentLine, lineWidth: 1))
    }
}

private struct ProcessGroupView: View {
    let turn: TurnGroup
    @ObservedObject var model: AppModel
    var onImageAppeared: ((String) -> Void)? = nil
    @State private var expanded = false
    @State private var didAutoScroll = false

    private var summary: String {
        var parts: [String] = []
        if !turn.process.isEmpty { parts.append("\(turn.process.count) 项") }
        if turn.interimReplyCount > 0 { parts.append("\(turn.interimReplyCount) 条中间回复") }
        if turn.imageCount > 0 { parts.append("\(turn.imageCount) 张图") }
        if turn.branchCount > 0 { parts.append("\(turn.branchCount) 个子代理") }
        return parts.joined(separator: " · ")
    }

    private var collapsedPreview: [ConversationItem] {
        turn.process.filter { item in
            switch item {
            case .assistant:
                return true
            case .tool(_, let info, _):
                return info.name == "AskUserQuestion" && !info.prompts.isEmpty
            default:
                return false
            }
        }
    }

    private func expandForImageFocus() {
        guard let focused = model.imageFocus?.itemID,
              turn.process.contains(where: { $0.id == focused }) else { return }
        expanded = true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Theme.accentSoft)
                        )

                    Text("过程")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.textSoft)

                    Text(summary)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(1)

                    if turn.isRunning {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(Theme.accent)
                        Text("子代理运行中")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }

                    Spacer()

                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.faint)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)

            if !turn.branches.isEmpty {
                HStack(spacing: 6) {
                    ForEach(turn.branches.prefix(3)) { node in
                        Button {
                            expanded = true
                            model.jumpToBranchID = node.id
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(Theme.accent)
                                Text(node.title)
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(Theme.textSoft)
                                    .lineLimit(1)
                                Circle()
                                    .fill(
                                        node.status == "失败"
                                            ? Theme.red
                                            : ((node.status == "已完成" || node.status == "已归档") ? Theme.green : Theme.accent)
                                    )
                                    .frame(width: 4, height: 4)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Theme.accentSoft))
                            .overlay(Capsule().stroke(Theme.accentLine, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                    }

                    if turn.branches.count > 3 {
                        Text("+\(turn.branches.count - 3)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.faint)
                            .padding(.horizontal, 6)
                    }

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }

            if !expanded, !collapsedPreview.isEmpty {
                Rectangle()
                    .fill(Theme.divider)
                    .frame(height: 1)

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(collapsedPreview) { item in
                        TranscriptItemView(item: item)
                    }
                }
                .padding(12)
            }

            if expanded {
                Rectangle()
                    .fill(Theme.divider)
                    .frame(height: 1)

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(turn.process) { item in
                        TranscriptItemView(item: item)
                            .id("item-\(item.id)")
                            .background {
                                if model.highlightedImageID == item.id {
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(Theme.accentSoft.opacity(0.7))
                                        .padding(-6)
                                }
                            }
                            .onAppear {
                                guard item.id == model.imageFocus?.itemID,
                                      !didAutoScroll else { return }
                                didAutoScroll = true
                                onImageAppeared?(item.id)
                            }
                    }
                }
                .padding(12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.subtleFill.opacity(0.72))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Theme.glassBorder.opacity(0.55), lineWidth: 1)
        }
        .onChange(of: model.jumpToBranchID) { _, branchId in
            guard let branchId, turn.branches.contains(where: { $0.id == branchId }) else { return }
            expanded = true
        }
        .onChange(of: model.imageFocus?.id) { _, _ in
            didAutoScroll = false
            expandForImageFocus()
        }
        .onAppear {
            if turn.isRunning && turn.answer == nil {
                expanded = true
            }
            expandForImageFocus()
        }
        .background {
            GeometryReader { proxy in
                let frame = proxy.frame(in: .named("transcriptScroll"))
                Color.clear.preference(
                    key: PinnedProcessPreferenceKey.self,
                    value: expanded ? [
                        PinnedProcessInfo(
                            turnID: turn.id,
                            summary: summary,
                            minY: frame.minY,
                            maxY: frame.maxY
                        )
                    ] : []
                )
            }
        }
        .id("process-\(turn.id)")
    }
}

private struct WaitingCard: View {
    let running: Bool
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            if running {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.orange)
            } else {
                Image(systemName: "ellipsis.bubble")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.faint)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(running ? "子代理仍在运行" : "这一轮没有文字回答")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSoft)
                Text(running ? "完成后的回答会替换当前这条；点击刷新立即检查。" : "中间过程已收起，可在上方展开。")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Theme.faint)
            }

            Spacer()

            if running {
                Button("刷新") { model.reloadSelected() }
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Theme.orange)
                    .buttonStyle(.plain)
                    .focusable(false)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.panelLift)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.stroke, lineWidth: 1)
        )
    }
}

private struct TranscriptItemView: View {
    let item: ConversationItem
    var highlightQuery: String?

    @ViewBuilder
    var body: some View {
        switch item {
        case .user(_, let text, let timestamp):
            UserMessage(text: text, timestamp: timestamp, highlightQuery: highlightQuery)
        case .assistant(_, let text, let model, let timestamp):
            AssistantMessage(text: text, model: model, timestamp: timestamp, highlightQuery: highlightQuery)
        case .tool(_, let info, _):
            if info.name == "AskUserQuestion", !info.prompts.isEmpty {
                AskUserQuestionCard(info: info)
            } else {
                ToolRow(info: info)
            }
        case .branch(_, let node):
            BranchCard(node: node)
        case .compaction(_, let pre, let post):
            CompactionRow(pre: pre, post: post)
        case .image(_, let ref):
            ImageRow(ref: ref)
        case .system(_, let text):
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.faint)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

private struct UserMessage: View {
    let text: String
    let timestamp: Date?
    var highlightQuery: String?

    private var attributedText: AttributedString {
        var attributed = AttributedString(text)
        attributed.highlightOccurrences(of: highlightQuery)
        return attributed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "person.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.accentInk)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Theme.orangeGradient))

                Text("你")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.text)

                Text(timestamp?.timeLabel ?? "")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Theme.faint)
            }

            Text(attributedText)
                .font(.system(size: 13.5, weight: .regular))
                .foregroundStyle(Theme.text)
                .lineSpacing(6)
                .textSelection(.enabled)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.promptFill)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Theme.glassBorder.opacity(0.55), lineWidth: 1)
        }
        .shadow(color: Theme.cardShadow, radius: 12, y: 5)
    }
}

private struct AssistantMessage: View {
    let text: String
    let model: String
    let timestamp: Date?
    var highlightQuery: String?

    private var modelLabel: String {
        if model.isEmpty { return "" }
        return model
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .prefix(3)
            .joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Theme.accentSoft))

                Text("Claude")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.text)

                if !modelLabel.isEmpty {
                    Text(modelLabel)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Theme.subtleFill))
                        .lineLimit(1)
                }

                Spacer()

                Text(timestamp?.timeLabel ?? "")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Theme.faint)
            }

            MarkdownMessageView(text: text, highlightQuery: highlightQuery)
        }
        .padding(.vertical, 2)
    }
}

private struct ToolRow: View {
    let info: ToolInfo
    @State private var expanded = false

    private var isEdit: Bool {
        info.name == "Edit" || info.name == "Write" || info.name == "MultiEdit"
    }

    private var statusTint: Color {
        switch info.status {
        case .running: return Theme.orange
        case .ok: return Theme.green
        case .error: return Color(hex: 0xFF6B6B)
        }
    }

    private var statusLabel: String {
        switch info.status {
        case .running: return "运行中"
        case .error: return "失败"
        case .ok: return info.name == "Read" ? "已读取" : "完成"
        }
    }

    private var hasDetail: Bool {
        !info.facts.isEmpty || info.diff != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.18)) { expanded.toggle() }
            } label: {
                header
            }
            .buttonStyle(.plain)
            .focusable(false)

            if expanded {
                Rectangle().fill(Theme.stroke).frame(height: 1)
                detailContent
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Theme.subtleFill.opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Theme.divider, lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: isEdit ? "chevron.left.forwardslash.chevron.right" : "doc.text.magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.orange)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.orange.opacity(0.09))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(info.summary)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.textSoft)
                    .lineLimit(1)
                Text(info.detail)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: 5) {
                Circle().fill(statusTint).frame(width: 5, height: 5)
                Text(statusLabel)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.muted)
            }

            if hasDetail {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.faint)
            }
        }
        .padding(11)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var detailContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if info.status == .running {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small).tint(Theme.orange)
                    Text("等待工具返回…")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Theme.muted)
                }
            }

            if !info.facts.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(info.facts) { fact in
                        HStack(alignment: .top, spacing: 10) {
                            Text(fact.label)
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(Theme.faint)
                                .frame(width: 48, alignment: .leading)
                            Text(fact.value)
                                .font(factFont(for: fact.label))
                                .foregroundStyle(Theme.textSoft)
                                .textSelection(.enabled)
                                .lineLimit(fact.label == "输出" || fact.label == "stderr" ? 12 : 4)
                        }
                    }
                }
            }

            if let diff = info.diff {
                VStack(alignment: .leading, spacing: 6) {
                    Text("DIFF")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.orange)
                    DiffBlock(text: diff)
                }
            }

            if !hasDetail {
                Text(info.detail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.muted)
            }
        }
        .padding(12)
    }

    private func factFont(for label: String) -> Font {
        if ["命令", "文件", "输出", "stderr", "模式"].contains(label) {
            return .system(size: 10, weight: .regular, design: .monospaced)
        }
        return .system(size: 10.5, weight: .medium)
    }
}

struct AskUserQuestionCard: View {
    let info: ToolInfo
    @State private var expanded = true

    private var answered: Bool {
        !info.answers.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: "questionmark.bubble.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.emphasis)
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Theme.emphasisSoft)
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Claude 向你提问")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Theme.textSoft)
                        Text(info.summary)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Theme.faint)
                            .lineLimit(1)
                    }

                    Spacer()

                    Text(answered ? "已回答" : "等待回答")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(answered ? Theme.green : Theme.emphasis)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(
                                answered
                                    ? Theme.green.opacity(0.1)
                                    : Theme.emphasis.opacity(0.12)
                            )
                        )

                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.faint)
                }
                .padding(11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)

            if expanded {
                Rectangle().fill(Theme.divider).frame(height: 1)

                VStack(alignment: .leading, spacing: 14) {
                    ForEach(info.prompts) { prompt in
                        promptView(prompt)
                    }
                }
                .padding(12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Theme.subtleFill.opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Theme.emphasisLine.opacity(0.6), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func promptView(_ prompt: QuestionPrompt) -> some View {
        let answer = info.answers[prompt.question]
        let matched = answer.map { selected in
            prompt.options.contains { isSelected($0, answer: selected) }
        } ?? false

        VStack(alignment: .leading, spacing: 8) {
            if !prompt.header.isEmpty {
                Text(prompt.header)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.emphasis)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.emphasisSoft))
            }

            Text(prompt.question)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineSpacing(5)
                .textSelection(.enabled)

            ForEach(prompt.options) { option in
                optionRow(option, selected: isSelected(option, answer: answer))
            }

            if let answer {
                if !matched {
                    Text(answer.choice.lowercased().contains("notes")
                         ? "没有选选项，只写了备注"
                         : "你的回答：\(answer.choice)")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Theme.emphasis)
                }
                if let notes = answer.notes, !notes.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Text("备注")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Theme.emphasis)
                            .padding(.top, 1)
                        Text(notes)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Theme.textSoft)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    private func isSelected(_ option: QuestionOption, answer: QuestionAnswer?) -> Bool {
        guard let choice = answer?.choice else { return false }
        if choice == option.label { return true }
        return choice
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .contains(option.label)
    }

    private func optionRow(_ option: QuestionOption, selected: Bool) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? Theme.emphasis : Theme.faint)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(option.label)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(selected ? Theme.text : Theme.muted)
                if !option.description.isEmpty {
                    Text(option.description)
                        .font(.system(size: 10.5, weight: .regular))
                        .foregroundStyle(selected ? Theme.textSoft : Theme.faint)
                        .lineSpacing(3)
                        .lineLimit(3)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Theme.emphasisSoft.opacity(0.7) : Color.clear)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(selected ? Theme.emphasisLine : Theme.divider, lineWidth: 1)
        }
    }
}

private struct DiffBlock: View {
    let text: String

    private var lines: [String] {
        text.components(separatedBy: "\n")
    }

    var body: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(color(for: line))
                        .textSelection(.enabled)
                }
            }
            .padding(10)
        }
        .frame(maxHeight: 300)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Theme.sunken)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Theme.stroke, lineWidth: 1)
        )
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("+") { return Theme.green }
        if line.hasPrefix("-") { return Color(hex: 0xFF7A7A) }
        if line.hasPrefix("@@") { return Theme.orange }
        return Theme.textSoft
    }
}

private struct BranchCard: View {
    @ObservedObject var node: BranchNode
    @State private var expanded = false

    private var statusTint: Color {
        if node.status == "运行中" || node.status == "已启动" { return Theme.orange }
        if node.status == "失败" { return Color(hex: 0xFF6B6B) }
        return Theme.green
    }

    private var durationText: String {
        guard node.duration > 0 else { return "—" }
        let total = Int(node.duration)
        if total >= 60 { return "\(total / 60)m\(total % 60)s" }
        return "\(total)s"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            VStack(spacing: 0) {
                Circle()
                    .fill(Theme.orange)
                    .frame(width: 7, height: 7)
                    .shadow(color: Theme.orange.opacity(0.6), radius: 5)
                Rectangle()
                    .fill(Theme.orange.opacity(0.25))
                    .frame(width: 1.5)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 8)
            .padding(.top, 6)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.orange)
                    Text("子代理 · \(node.title)")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)

                    Text(node.agentType)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.subtleFill))

                    Spacer()

                    HStack(spacing: 4) {
                        Circle().fill(statusTint).frame(width: 5, height: 5)
                        Text(node.status)
                            .font(.system(size: 8.8, weight: .medium))
                            .foregroundStyle(Theme.muted)
                    }
                }

                HStack(spacing: 13) {
                    if node.isArchived {
                        stat("仅存结论")
                    } else {
                        stat(node.isLoaded ? "\(node.steps) 步" : "点击加载")
                        if node.isLoaded { stat(durationText) }
                        if node.isLoaded { stat("\(node.items.count) 条") }
                    }
                    if !node.prompt.isEmpty { stat("有任务说明") }
                }

                if expanded {
                    branchContent
                }

                HStack {
                    Text(expanded ? "收起分支" : "展开分支")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Theme.orange)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Theme.orange)
                }
            }
        }
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.orange.opacity(0.065))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Theme.orange.opacity(0.18), lineWidth: 1)
        )        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.snappy(duration: 0.2)) {
                expanded.toggle()
            }
            if expanded {
                BranchLoader.load(node)
            }
        }
        .background {
            GeometryReader { proxy in
                let frame = proxy.frame(in: .named("transcriptScroll"))
                Color.clear.preference(
                    key: PinnedBranchPreferenceKey.self,
                    value: expanded ? [
                        PinnedBranchInfo(
                            branchID: node.id,
                            title: node.title,
                            status: node.status,
                            minY: frame.minY,
                            maxY: frame.maxY
                        )
                    ] : []
                )
            }
        }
        .id("branch-\(node.id)")
    }

    @ViewBuilder
    private var branchContent: some View {
        if node.isLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(Theme.orange)
                Text("正在读取子代理轨迹…")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Theme.muted)
            }
            .padding(10)
        } else if let error = node.loadError {
            Text(error)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.muted)
                .padding(10)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if !node.prompt.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("任务")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.orange)
                        Text(node.prompt)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(Theme.textSoft)
                            .lineSpacing(4)
                            .lineLimit(6)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.sunken))
                }

                if let report = node.report, !report.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(node.isArchived ? "最终回答" : "结论")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.orange)
                        Text(report)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(Theme.textSoft)
                            .lineSpacing(4)
                            .lineLimit(node.isArchived ? nil : 10)
                            .textSelection(.enabled)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.sunken))
                }

                ForEach(node.items) { item in
                    AnyView(TranscriptItemView(item: item))
                        .padding(.leading, 12)
                }
            }
        }
    }

    private func stat(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(Theme.muted)
    }
}

private struct CompactionRow: View {
    let pre: Int
    let post: Int

    private func tokens(_ value: Int) -> String {
        if value >= 1000 {
            return String(format: "%.1fk", Double(value) / 1000)
        }
        return "\(value)"
    }

    var body: some View {
        HStack(spacing: 9) {
            Rectangle().fill(Theme.stroke).frame(height: 1)

            HStack(spacing: 5) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 8, weight: .bold))
                Text("上下文已压缩 · \(tokens(pre)) → \(tokens(post)) tokens")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Theme.faint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Theme.subtleFill))
            .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))

            Rectangle().fill(Theme.stroke).frame(height: 1)
        }
        .padding(.vertical, 4)
    }
}

private func downsampleImage(data: Data, maxPixel: CGFloat) -> NSImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        kCGImageSourceCreateThumbnailWithTransform: true
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        return nil
    }
    return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
}

private struct ImageRow: View {
    let ref: ImageRef
    @State private var image: NSImage?
    @State private var showingPreview = false

    private var approxKB: Int {
        Int(Double(ref.base64.count) * 0.75 / 1024)
    }

    var body: some View {
        Button {
            showingPreview = true
        } label: {
            HStack(spacing: 11) {
                Group {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        LinearGradient(
                            colors: [Theme.orange.opacity(0.55), Theme.panelSoft],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .overlay(
                            Image(systemName: "photo")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(.white.opacity(0.62))
                        )
                    }
                }
                .frame(width: 96, height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text("图片 · \(ref.mediaType.replacingOccurrences(of: "image/", with: "").uppercased())")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.textSoft)
                    Text("约 \(approxKB) KB · base64 内嵌")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Theme.faint)
                }

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 8.5, weight: .bold))
                    Text("查看大图")
                        .font(.system(size: 9.5, weight: .semibold))
                }
                .foregroundStyle(Theme.accent)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(Theme.panelLift)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("查看大图")
        .onAppear {
            guard image == nil, let data = Data(base64Encoded: ref.base64) else { return }
            image = downsampleImage(data: data, maxPixel: 720)
        }
        .sheet(isPresented: $showingPreview) {
            ImagePreviewSheet(ref: ref)
        }
    }
}

private struct ImageGallerySheet: View {
    let images: [ImageRef]
    let onOpen: (ImageRef) -> Void
    @Environment(\.dismiss) private var dismiss

    private let columns = [
        GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 14)
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("会话图片")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("\(images.count) 张 · 点击缩略图跳转到对话中的图片")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Theme.faint)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.textSoft)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Theme.subtleFill))
                }
                .buttonStyle(.plain)
                .focusable(false)
                .keyboardShortcut(.cancelAction)
                .help("关闭")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Rectangle()
                .fill(Theme.divider)
                .frame(height: 1)

            if images.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(Theme.faint)
                    Text("这个会话里没有可显示的图片")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.faint)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(Array(images.enumerated()), id: \.element.id) { index, ref in
                            Button {
                                dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                                    onOpen(ref)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    GalleryThumb(ref: ref)
                                        .frame(height: 150)

                                    HStack(spacing: 6) {
                                        Text("图片 \(index + 1)")
                                            .font(.system(size: 9.5, weight: .semibold))
                                            .foregroundStyle(Theme.textSoft)
                                        Spacer()
                                        Text(ref.mediaType.replacingOccurrences(of: "image/", with: "").uppercased())
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundStyle(Theme.faint)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .focusable(false)
                            .help("跳转到对话中的图片")
                        }
                    }
                    .padding(18)
                }
                .background(Theme.bg.opacity(0.45))
            }
        }
        .frame(width: 980, height: 700)
        .background(Theme.panelLift)
    }
}

private struct GalleryThumb: View {
    let ref: ImageRef
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [Theme.orange.opacity(0.35), Theme.panelSoft],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .overlay(
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.textSoft)
                )
            }
        }
        .frame(maxWidth: .infinity, minHeight: 150, maxHeight: 150)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.stroke, lineWidth: 1)
        )
        .onAppear {
            guard image == nil, let data = Data(base64Encoded: ref.base64) else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let decoded = downsampleImage(data: data, maxPixel: 720)
                DispatchQueue.main.async {
                    image = decoded
                }
            }
        }
    }
}

private struct ImagePreviewSheet: View {
    let ref: ImageRef
    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?
    @State private var failed = false

    private var approxKB: Int {
        Int(Double(ref.base64.count) * 0.75 / 1024)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("图片预览")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("\(ref.mediaType.replacingOccurrences(of: "image/", with: "").uppercased()) · 约 \(approxKB) KB")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Theme.faint)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.textSoft)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Theme.subtleFill))
                }
                .buttonStyle(.plain)
                .focusable(false)
                .keyboardShortcut(.cancelAction)
                .help("关闭")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Rectangle()
                .fill(Theme.divider)
                .frame(height: 1)

            ZStack {
                Color(hex: 0x15181D)

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .padding(22)
                } else if failed {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 24, weight: .light))
                        Text("无法解码这张图片")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.55))
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 920, height: 680)
        .background(Theme.panelLift)
        .onAppear(perform: load)
    }

    private func load() {
        guard image == nil, !failed else { return }
        guard let data = Data(base64Encoded: ref.base64) else {
            failed = true
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let decoded = downsampleImage(data: data, maxPixel: 2800)
            DispatchQueue.main.async {
                if let decoded {
                    image = decoded
                } else {
                    failed = true
                }
            }
        }
    }
}
