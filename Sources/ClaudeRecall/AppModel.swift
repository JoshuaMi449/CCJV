import Foundation
import Combine

@MainActor
final class AppModel: ObservableObject {
    @Published var sessions: [SessionSummary] = []
    @Published var selectedID: String?
    @Published var conversation: Conversation?
    @Published var isLoading = false
    @Published var query = "" {
        didSet { scheduleSearch() }
    }
    @Published var status = "正在扫描会话…"
    @Published var jumpToBranchID: String?
    @Published private(set) var searchHits: [ContentSearchHit] = []
    @Published private(set) var searchSessions: [ContentSearchSessionResult] = []
    @Published private(set) var searchTotal = 0
    @Published private(set) var searchScopeSessionID: String?
    @Published private(set) var isIndexingContent = false
    @Published private(set) var contentIndexReady = false
    @Published var activeSearchSessionID: String?
    @Published var searchFocus: SearchFocus?
    @Published var highlightedItemID: String?
    @Published var imageFocus: ImageFocus?
    @Published var highlightedImageID: String?
    @Published var turnFocus: TurnFocus?
    /// Turn currently crossing the transcript's reading line, used to keep the
    /// open sidebar outline in sync while the user scrolls context.
    @Published private(set) var activeTurnID: String?
    @Published private(set) var archiveUsageBytes: Int64 = 0
    @Published private(set) var archiveHealth = ArchiveHealth()
    @Published private(set) var pinnedArchiveIDs: Set<String> = []
    @Published private(set) var customGroups: [SessionGroupRecord] = []
    @Published private(set) var lineages: [String: SessionLineage] = [:] {
        didSet { chainGraph = SessionChainGraph(lineages: lineages) }
    }
    @Published private(set) var readingMode: ReadingMode = .merged
    /// Set when a live sync changes the selected chain. We do not replace the
    /// visible conversation under the user without a deliberate refresh.
    @Published private(set) var conversationNeedsRefresh = false

    /// Single raw/archived segments, keyed by session id. This never contains a
    /// merged chain.
    private var cache: [String: Conversation] = [:]
    /// Merged chains, keyed by the selected segment id. Kept separately so
    /// switching between merged and complete-segment views cannot return the
    /// wrong conversation for the same id.
    private var mergedCache: [String: Conversation] = [:]
    private var chainGraph = SessionChainGraph(lineages: [:])
    private var rawSessions: [SessionSummary] = []
    private var aliases: [String: String] = [:]
    private var brokenLinks: Set<String> = []
    private var activeTurnLockUntil: Date?
    private var archive = ArchiveDocument()
    private var watcher: SessionWatcher?
    private var liveSyncTask: Task<Void, Never>?
    private var liveSyncFirstChange: Date?
    private var liveSyncPending = false
    private var isLiveSyncing = false
    private var archiveRevision = UUID()
    private var contentIndex: [ContentSearchEntry] = []
    private var indexGeneration = UUID()
    private var indexTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var pendingFocus: SearchFocus?
    private var lastSearchQuery = ""

    var selectedSummary: SessionSummary? {
        sessions.first { $0.id == selectedID }
    }

    /// A resume command is only valid when Claude Code can still see the raw
    /// session file. Archived Q&A alone is not resumable.
    func canResume(_ id: String?) -> Bool {
        guard let id,
              rawSessions.contains(where: { $0.id == id }),
              let summary = sessions.first(where: { $0.id == id }),
              !summary.isArchived else {
            return false
        }
        return FileManager.default.fileExists(atPath: summary.fileURL.path)
    }

    func lineageInfo(for id: String?) -> SessionLineage? {
        guard let id else { return nil }
        return lineages[id]
    }

    var activeSearchSession: ContentSearchSessionResult? {
        guard let activeSearchSessionID else { return nil }
        return searchSessions.first { $0.sessionID == activeSearchSessionID }
    }

    var activeSearchHits: [ContentSearchHit] {
        activeSearchSession?.hits ?? []
    }

    var searchHighlightQuery: String? {
        guard activeSearchSessionID != nil else { return nil }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? nil : q
    }

    init() {
        let workspace = SessionWorkspaceStore.load()
        aliases = workspace.aliases
        customGroups = workspace.groups
        brokenLinks = Set(workspace.brokenLinks ?? [])
        refresh()
        startWatching()
    }

    private func startWatching() {
        let watcher = SessionWatcher { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleSessionFilesChanged()
            }
        }
        watcher.start()
        self.watcher = watcher
    }

    private func handleSessionFilesChanged() {
        liveSyncPending = true
        if liveSyncFirstChange == nil {
            liveSyncFirstChange = Date()
        }
        scheduleLiveSyncIfIdle()
    }

    private func scheduleLiveSyncIfIdle() {
        guard liveSyncPending, !isIndexingContent, !isLiveSyncing else { return }

        let elapsed = Date().timeIntervalSince(liveSyncFirstChange ?? Date())
        if elapsed >= 45 {
            liveSyncPending = false
            liveSyncFirstChange = nil
            liveSyncTask?.cancel()
            liveSyncTask = nil
            performLiveSync()
            return
        }

        liveSyncTask?.cancel()
        liveSyncTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, let self else { return }
            guard self.liveSyncPending,
                  !self.isIndexingContent,
                  !self.isLiveSyncing else { return }
            self.liveSyncPending = false
            self.liveSyncTask = nil
            self.liveSyncFirstChange = nil
            self.performLiveSync()
        }
    }

    private func performLiveSync() {
        guard !isLiveSyncing, !isIndexingContent else {
            liveSyncPending = true
            return
        }
        isLiveSyncing = true
        let existing = archive
        let revision = archiveRevision
        let snapshotBrokenLinks = brokenLinks

        Task.detached(priority: .utility) {
            let raw = SessionIndexer.scan()
            let syncResult = ArchiveStore.syncWithReport(
                rawSessions: raw,
                existing: existing,
                maxBytes: AppSettings.archiveLimitBytes
            )
            let updated = syncResult.document
            let entries = ArchiveStore.searchEntries(for: updated, rawSessions: raw)
            let usage = ArchiveStore.usageBytes()
            let lineages = ArchiveLineage.build(
                sessions: updated.sessions,
                brokenLinks: snapshotBrokenLinks
            )
            let pinned = ArchiveStore.pinnedIDs()

            await MainActor.run {
                self.isLiveSyncing = false
                guard self.archiveRevision == revision else {
                    if self.liveSyncPending {
                        self.scheduleLiveSyncIfIdle()
                    }
                    return
                }
                let previousRaw = Dictionary(uniqueKeysWithValues: self.rawSessions.map { ($0.id, $0) })
                let currentRaw = Dictionary(uniqueKeysWithValues: raw.map { ($0.id, $0) })
                let previousRawIDs = Set(previousRaw.keys)
                let currentRawIDs = Set(currentRaw.keys)
                let removedRawIDs = previousRawIDs.subtracting(currentRawIDs)
                let changedRawIDs = currentRawIDs.filter { id in
                    guard let old = previousRaw[id], let new = currentRaw[id] else { return true }
                    return old.fileSize != new.fileSize || old.date != new.date
                }
                let invalidatedIDs = removedRawIDs.union(changedRawIDs)
                let previousSelectedChain = self.selectedID.map {
                    Set(self.chainIDs(for: $0))
                } ?? []

                self.rawSessions = raw
                self.archive = updated
                self.archiveUsageBytes = usage
                self.archiveHealth = ArchiveHealth(
                    unreadableFiles: self.archiveHealth.unreadableFiles,
                    failedWriteIDs: syncResult.failedWriteIDs,
                    evictedIDs: syncResult.evictedIDs,
                    overQuota: syncResult.overQuota
                )
                self.pinnedArchiveIDs = pinned
                if !invalidatedIDs.isEmpty || self.lineages != lineages {
                    self.mergedCache.removeAll()
                }
                if !invalidatedIDs.isEmpty {
                    self.cache = self.cache.filter { !invalidatedIDs.contains($0.key) }
                }
                self.lineages = lineages
                var merged = ArchiveStore.merge(raw: raw, archive: updated)
                self.applyAliases(to: &merged)
                self.sessions = merged
                self.normalizeGroupsForChains()
                self.status = merged.isEmpty ? "没有找到会话" : "\(merged.count) 个会话"
                self.contentIndex = entries

                if let selectedID = self.selectedID {
                    let newSelectedChain = Set(self.chainIDs(for: selectedID))
                    let selectedTouched = !previousSelectedChain.isDisjoint(with: invalidatedIDs)
                    if selectedTouched || previousSelectedChain != newSelectedChain {
                        self.conversationNeedsRefresh = true
                    }
                }

                if self.selectedID == nil, let first = merged.first {
                    self.select(first.id)
                }
                if let selectedID = self.selectedID, removedRawIDs.contains(selectedID) {
                    if merged.contains(where: { $0.id == selectedID }) {
                        self.loadSelection(selectedID, mode: self.readingMode)
                    } else {
                        self.conversation = nil
                        self.selectedID = merged.first?.id
                        if let first = merged.first {
                            self.select(first.id)
                        } else {
                            self.isLoading = false
                        }
                    }
                }
                if self.contentIndexReady {
                    self.scheduleSearch()
                }
                if self.liveSyncPending {
                    self.scheduleLiveSyncIfIdle()
                }
            }
        }
    }

    func refresh() {
        status = "正在扫描会话…"
        let snapshotBrokenLinks = brokenLinks
        Task.detached(priority: .userInitiated) {
            let raw = SessionIndexer.scan()
            let loadResult = ArchiveStore.loadWithReport()
            let existing = loadResult.document
            let usage = ArchiveStore.usageBytes()
            let merged = ArchiveStore.merge(raw: raw, archive: existing)
            let lineages = ArchiveLineage.build(
                sessions: existing.sessions,
                brokenLinks: snapshotBrokenLinks
            )
            let pinned = ArchiveStore.pinnedIDs()
            await MainActor.run {
                self.rawSessions = raw
                self.archive = existing
                self.archiveUsageBytes = usage
                self.archiveHealth = ArchiveHealth(unreadableFiles: loadResult.unreadableFiles)
                self.pinnedArchiveIDs = pinned
                self.lineages = lineages
                var aliased = merged
                self.applyAliases(to: &aliased)
                self.sessions = aliased
                self.normalizeGroupsForChains()
                self.status = aliased.isEmpty ? "没有找到会话" : "\(aliased.count) 个会话"
                if self.selectedID == nil, let first = aliased.first {
                    self.select(first.id)
                }
                self.rebuildArchiveAndIndex(rawSessions: raw, existingArchive: existing)
            }
        }
    }

    func select(_ id: String) {
        loadSelection(id, mode: .merged)
    }

    /// Open one raw/archived segment without merging the rest of its chain.
    /// This is the escape hatch for turns that sit after a fork point and are
    /// intentionally excluded from the linear merged view.
    func selectSegment(_ id: String) {
        loadSelection(id, mode: .segment)
    }

    func showMergedSelection() {
        guard let id = selectedID else { return }
        loadSelection(id, mode: .merged)
    }

    private func loadSelection(_ id: String, mode: ReadingMode) {
        if pendingFocus?.sessionID != id {
            pendingFocus = nil
            searchFocus = nil
            highlightedItemID = nil
            imageFocus = nil
            highlightedImageID = nil
            turnFocus = nil
        }

        if selectedID != id {
            conversationNeedsRefresh = false
        }
        let mustReload = selectedID == id && conversationNeedsRefresh

        let chain = chainIDs(for: id)
        let wantsMerged = mode == .merged && chain.count > 1

        if !mustReload, selectedID == id, let conversation {
            let shapeMatches = wantsMerged
                ? (!conversation.segments.isEmpty && chainMatches(conversation, chain))
                : conversation.segments.isEmpty
            if readingMode == mode, shapeMatches {
                activatePendingFocus()
                return
            }
        }

        let previousSelectedID = selectedID
        let previousReadingMode = readingMode
        selectedID = id
        readingMode = mode
        if previousSelectedID != id || previousReadingMode != mode {
            activeTurnID = nil
            activeTurnLockUntil = nil
        }

        if !mustReload,
           wantsMerged,
           let cached = mergedCache[id],
           chainMatches(cached, chain) {
            conversation = cached
            isLoading = false
            activatePendingFocus()
            return
        }

        if !mustReload, !wantsMerged, let cached = cache[id], cached.segments.isEmpty {
            conversation = cached
            isLoading = false
            activatePendingFocus()
            return
        }

        guard let summary = sessions.first(where: { $0.id == id }) else {
            isLoading = false
            conversation = nil
            pendingFocus = nil
            conversationNeedsRefresh = false
            return
        }
        if mustReload {
            conversationNeedsRefresh = false
        }
        isLoading = true
        conversation = nil

        if wantsMerged {
            loadMergedConversation(id: id, chain: chain)
        } else {
            loadSingleConversation(id: id, summary: summary)
        }
    }

    private func shouldApplySingleConversation(id: String) -> Bool {
        guard selectedID == id else { return false }
        return readingMode == .segment || chainIDs(for: id).count <= 1
    }

    private func loadSingleConversation(id: String, summary: SessionSummary) {
        if summary.isArchived || !FileManager.default.fileExists(atPath: summary.fileURL.path),
           let archived = archive.sessions.first(where: { $0.id == id }) {
            var result = ArchiveStore.conversation(for: archived, summary: summary)
            result.session.customTitle = aliases[id]
            cache[id] = result
            if shouldApplySingleConversation(id: id) {
                conversation = result
                isLoading = false
                activatePendingFocus()
            }
            return
        }

        Task.detached(priority: .userInitiated) {
            let parser = SessionParser(url: summary.fileURL, summary: summary)
            let parsed = parser.parse()

            await MainActor.run {
                var result = parsed
                result.session.customTitle = self.aliases[id]

                if result.items.isEmpty,
                   let archived = self.archive.sessions.first(where: { $0.id == id }) {
                    var archivedSummary = summary
                    archivedSummary.isArchived = true
                    archivedSummary.customTitle = self.aliases[id]
                    let fallback = ArchiveStore.conversation(
                        for: archived,
                        summary: archivedSummary
                    )
                    self.cache[id] = fallback
                    if self.shouldApplySingleConversation(id: id) {
                        self.conversation = fallback
                        self.isLoading = false
                        self.activatePendingFocus()
                    }
                    if let index = self.sessions.firstIndex(where: { $0.id == id }) {
                        self.sessions[index].isArchived = true
                        self.sessions[index].customTitle = self.aliases[id]
                        self.sessions[index].turns = archived.messages.filter { $0.role == .user }.count
                        self.sessions[index].subagentCount = archived.subagents.count
                    }
                    return
                }

                self.cache[id] = result
                if self.shouldApplySingleConversation(id: id) {
                    self.conversation = result
                    self.isLoading = false
                    self.activatePendingFocus()
                }
                if let index = self.sessions.firstIndex(where: { $0.id == id }) {
                    self.sessions[index].turns = result.session.turns
                    self.sessions[index].title = result.session.title
                    self.sessions[index].customTitle = self.aliases[id]
                }
            }
        }
    }

    private func chainIDs(for id: String) -> [String] {
        chainGraph.chain(for: id)
    }

    func chainRoot(for id: String) -> String {
        chainGraph.root(for: id)
    }

    func isLinkBroken(_ id: String?) -> Bool {
        guard let id else { return false }
        return brokenLinks.contains(id)
    }

    func breakContinuationLink(_ id: String) {
        guard lineages[id]?.parentID != nil, !brokenLinks.contains(id) else { return }
        brokenLinks.insert(id)
        saveWorkspace()
        rebuildLineageOverrides()
    }

    func restoreContinuationLink(_ id: String) {
        guard brokenLinks.remove(id) != nil else { return }
        saveWorkspace()
        rebuildLineageOverrides()
    }

    private func rebuildLineageOverrides() {
        mergedCache.removeAll()
        lineages = ArchiveLineage.build(
            sessions: archive.sessions,
            brokenLinks: brokenLinks
        )
        activeSearchSessionID = nil
        searchFocus = nil
        highlightedItemID = nil
        normalizeGroupsForChains()
        scheduleSearch()
        if let selectedID {
            conversation = nil
            loadSelection(selectedID, mode: readingMode)
        }
    }

    func chainIsMerged(_ id: String?) -> Bool {
        guard let id else { return false }
        return chainIDs(for: id).count > 1
    }

    func strongChildren(of id: String) -> [String] {
        chainGraph.strongChildren(of: id, lineages: lineages)
    }

    /// Strongly linked family, including siblings of a fork. Used for group
    /// membership and search display, not for the linear merged path.
    func linkedSessionIDs(for id: String) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        var queue = [id]

        while let current = queue.popLast() {
            guard seen.insert(current).inserted else { continue }
            result.append(current)
            guard let info = lineages[current] else { continue }

            var next: [String] = []
            if let parentID = info.parentID,
               info.isStrong,
               lineages[parentID]?.children.contains(current) == true {
                next.append(parentID)
            }
            for childID in info.children
            where lineages[childID]?.isStrong == true
                && lineages[childID]?.parentID == current {
                next.append(childID)
            }
            for related in next where !seen.contains(related) {
                queue.append(related)
            }
        }

        let order = Dictionary(uniqueKeysWithValues: sessions.enumerated().map { ($1.id, $0) })
        return result.sorted {
            (order[$0] ?? Int.max) < (order[$1] ?? Int.max)
        }
    }

    func chainCount(in group: SessionGroupRecord) -> Int {
        let available = Set(sessions.map(\.id))
        let roots = group.sessionIDs
            .filter { available.contains($0) }
            .map { chainRoot(for: $0) }
        return Set(roots).count
    }

    private func chainMatches(_ conversation: Conversation, _ chain: [String]) -> Bool {
        if chain.count <= 1 {
            return conversation.segments.isEmpty || conversation.chainIDs == chain
        }
        return conversation.chainIDs == chain && !conversation.segments.isEmpty
    }

    private func loadMergedConversation(
        id: String,
        chain: [String]
    ) {
        let summaries = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let archiveSnapshot = archive
        let cachedConversations = cache

        Task.detached(priority: .userInitiated) {
            var conversations: [String: Conversation] = [:]
            var pending: [SessionSummary] = []
            let loadOrder = [id] + chain.filter { $0 != id }

            for sessionID in loadOrder {
                guard let partSummary = summaries[sessionID] else { continue }
                if let cached = cachedConversations[sessionID], cached.segments.isEmpty {
                    conversations[sessionID] = cached
                } else {
                    pending.append(partSummary)
                }
            }

            await withTaskGroup(of: (String, Conversation?).self) { group in
                for partSummary in pending {
                    group.addTask {
                        let loaded = SessionChain.load(
                            summary: partSummary,
                            archive: archiveSnapshot
                        )
                        return (partSummary.id, loaded)
                    }
                }
                for await (sessionID, conversation) in group {
                    if let conversation {
                        conversations[sessionID] = conversation
                    }
                }
            }

            var parts: [SessionChainPart] = []
            for (index, sessionID) in chain.enumerated() {
                guard let partSummary = summaries[sessionID],
                      let conversation = conversations[sessionID] else { continue }

                var cutoff: Date?
                if index < chain.count - 1 {
                    let nextID = chain[index + 1]
                    let nextCheckpoint = archiveSnapshot.sessions
                        .first(where: { $0.id == nextID })?
                        .checkpoints?
                        .first(where: { $0.turnIndex == 0 })
                    cutoff = nextCheckpoint?.timestamp
                        ?? conversations[nextID]?.startedAt
                }
                parts.append(SessionChainPart(
                    summary: partSummary,
                    conversation: conversation,
                    cutoffDate: cutoff
                ))
            }

            let merged = SessionChain.merge(parts: parts, selectedID: id)
            let fallback = conversations[id]
            let segmentConversations = conversations

            await MainActor.run {
                for (sessionID, conversation) in segmentConversations
                where self.cache[sessionID] == nil {
                    self.cache[sessionID] = conversation
                }

                guard var result = merged ?? fallback else {
                    if self.selectedID == id, self.readingMode == .merged {
                        self.isLoading = false
                        self.conversation = nil
                        self.pendingFocus = nil
                    }
                    return
                }
                result.session.customTitle = self.aliases[id]
                self.mergedCache[id] = result

                guard self.selectedID == id, self.readingMode == .merged else {
                    return
                }
                self.isLoading = false
                self.conversation = result
                self.activatePendingFocus()
            }
        }
    }

    func openSearchSession(_ result: ContentSearchSessionResult) {
        activeSearchSessionID = result.sessionID
        guard let latest = result.latest else { return }
        openSearchHit(latest)
    }

    func openSearchHit(_ hit: ContentSearchHit) {
        let focus = SearchFocus(
            sessionID: hit.entry.sessionID,
            turnID: hit.entry.turnID,
            itemID: hit.entry.messageID
        )
        pendingFocus = focus
        activeSearchSessionID = searchScopeSessionID ?? chainRoot(for: hit.entry.sessionID)
        imageFocus = nil
        highlightedImageID = nil
        turnFocus = nil

        if selectedID == hit.entry.sessionID {
            if conversation != nil {
                activatePendingFocus()
            } else {
                select(hit.entry.sessionID)
            }
        } else {
            select(hit.entry.sessionID)
        }
    }

    func exitSearchSession() {
        activeSearchSessionID = nil
        pendingFocus = nil
        searchFocus = nil
        highlightedItemID = nil
    }

    /// When a session outline is open, searching is restricted to that raw
    /// session's content until the outline/search scope is cleared.
    func setSearchScope(_ id: String?) {
        guard searchScopeSessionID != id else { return }
        searchScopeSessionID = id
        activeSearchSessionID = nil
        pendingFocus = nil
        searchFocus = nil
        highlightedItemID = nil
        scheduleSearch()
    }

    func focusImage(itemID: String, sessionID: String) {
        searchFocus = nil
        highlightedItemID = nil
        turnFocus = nil
        highlightedImageID = itemID
        imageFocus = ImageFocus(sessionID: sessionID, itemID: itemID)
    }

    func setActiveTurn(_ turnID: String?) {
        if let activeTurnLockUntil, Date() < activeTurnLockUntil {
            return
        }
        guard activeTurnID != turnID else { return }
        activeTurnID = turnID
    }

    func lockActiveTurn(_ turnID: String) {
        activeTurnID = turnID
        activeTurnLockUntil = Date().addingTimeInterval(0.9)
    }

    func focusTurn(_ turnID: String) {
        guard let selectedID else { return }
        lockActiveTurn(turnID)
        searchFocus = nil
        highlightedItemID = nil
        imageFocus = nil
        highlightedImageID = nil
        turnFocus = TurnFocus(sessionID: selectedID, turnID: turnID)
    }

    func reloadSelected() {
        guard let selectedID else { return }
        cache.removeValue(forKey: selectedID)
        mergedCache.removeValue(forKey: selectedID)
        conversation = nil
        loadSelection(selectedID, mode: readingMode)
    }

    func hasArchivedCopy(_ id: String?) -> Bool {
        guard let id else { return false }
        return archive.sessions.contains { $0.id == id }
    }

    /// All segments connected by a parent/child link, including fork branches.
    /// Used for protection and delete warnings, not for the linear reading path.
    func archiveRelatedIDs(for id: String) -> Set<String> {
        var result: Set<String> = [id]
        var queue = [id]
        while let current = queue.popLast() {
            guard let lineage = lineages[current] else { continue }
            var next: [String] = []
            if let parentID = lineage.parentID { next.append(parentID) }
            next.append(contentsOf: lineage.children)
            for related in next where !result.contains(related) {
                result.insert(related)
                queue.append(related)
            }
        }
        return result
    }

    func isArchivePinned(_ id: String?) -> Bool {
        guard let id else { return false }
        return !pinnedArchiveIDs.isDisjoint(with: archiveRelatedIDs(for: id))
    }

    func toggleArchivePin(_ id: String) {
        let related = archiveRelatedIDs(for: id)
        let shouldPin = pinnedArchiveIDs.isDisjoint(with: related)
        for relatedID in related {
            ArchiveStore.setPinned(relatedID, pinned: shouldPin)
        }
        pinnedArchiveIDs = ArchiveStore.pinnedIDs()
    }

    func archiveDeleteMessage(for id: String?) -> String {
        guard let id else {
            return "只删除 CCJV 的归档副本，不会动原始 JSON。"
        }
        let related = archiveRelatedIDs(for: id).subtracting([id])
        guard !related.isEmpty else {
            return "只删除 CCJV 的归档副本，不会动原始 JSON。若原始文件已不存在，删除后这个会话将无法再查看。"
        }
        let names = related.prefix(3).map { relatedID in
            guard let summary = sessions.first(where: { $0.id == relatedID }) else {
                return "会话 \(relatedID.prefix(8))"
            }
            let title = summary.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty || title.hasPrefix("http://") || title.hasPrefix("https://") {
                return "会话 \(relatedID.prefix(8))"
            }
            return title
        }
        let suffix = related.count > 3 ? " 等 \(related.count) 段" : ""
        return "只删除 CCJV 的归档副本，不会动原始 JSON。此段与「\(names.joined(separator: "」「"))」\(suffix)有续接关系，删除后这条链会断开。"
    }

    // MARK: - Session names and groups

    func customName(for id: String) -> String? {
        aliases[id]
    }

    func renameSession(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            aliases.removeValue(forKey: id)
        } else {
            aliases[id] = String(trimmed.prefix(120))
        }
        saveWorkspace()

        var updated = sessions
        for index in updated.indices {
            updated[index].customTitle = aliases[updated[index].id]
        }
        sessions = updated

        if var cached = cache[id] {
            cached.session.customTitle = aliases[id]
            cache[id] = cached
            if selectedID == id, readingMode == .segment {
                conversation = cached
            }
        }
        if var mergedCached = mergedCache[id] {
            mergedCached.session.customTitle = aliases[id]
            mergedCache[id] = mergedCached
            if selectedID == id, readingMode == .merged {
                conversation = mergedCached
            }
        }
        if selectedID == id, var active = conversation, active.session.id == id {
            active.session.customTitle = aliases[id]
            conversation = active
        }
    }

    func group(forSessionID id: String) -> SessionGroupRecord? {
        customGroups.first { $0.sessionIDs.contains(id) }
    }

    func group(withID id: String) -> SessionGroupRecord? {
        customGroups.first { $0.id == id }
    }

    func sessions(in group: SessionGroupRecord) -> [SessionSummary] {
        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        return group.sessionIDs.compactMap { byID[$0] }
    }

    private func expandedGroupIDs(for ids: [String]) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        for id in ids {
            for linkedID in linkedSessionIDs(for: id) where seen.insert(linkedID).inserted {
                result.append(linkedID)
            }
        }
        return result
    }

    /// Existing groups may contain only one side of a continuation. Expand
    /// them once lineages are available, but keep unavailable ids so a
    /// temporarily missing archive does not silently lose group membership.
    private func normalizeGroupsForChains() {
        guard !customGroups.isEmpty else { return }
        var groups = customGroups
        var changed = false
        for index in groups.indices {
            let expanded = expandedGroupIDs(for: groups[index].sessionIDs)
            if expanded != groups[index].sessionIDs {
                groups[index].sessionIDs = expanded
                changed = true
            }
        }
        guard changed else { return }
        customGroups = groups
        saveWorkspace()
    }

    @discardableResult
    func createGroup(
        name: String,
        style: GroupBallStyle = .ocean,
        adding sessionIDs: [String] = []
    ) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmed.isEmpty ? "新分组" : String(trimmed.prefix(80))
        let id = UUID().uuidString
        var groups = customGroups
        let uniqueIDs = expandedGroupIDs(for: sessionIDs.filter { !$0.isEmpty })

        if !uniqueIDs.isEmpty {
            for index in groups.indices {
                groups[index].sessionIDs.removeAll { uniqueIDs.contains($0) }
            }
        }

        groups.append(
            SessionGroupRecord(
                id: id,
                name: displayName,
                sessionIDs: uniqueIDs,
                style: style,
                isCollapsed: uniqueIDs.isEmpty
            )
        )
        customGroups = groups
        saveWorkspace()
        return id
    }

    func renameGroup(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var groups = customGroups
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].name = String(trimmed.prefix(80))
        customGroups = groups
        saveWorkspace()
    }

    func updateGroupStyle(_ id: String, style: GroupBallStyle) {
        var groups = customGroups
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        guard groups[index].style != style else { return }
        groups[index].style = style
        customGroups = groups
        saveWorkspace()
    }

    func setGroupCollapsed(_ id: String, collapsed: Bool) {
        var groups = customGroups
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        guard groups[index].isCollapsed != collapsed else { return }
        groups[index].isCollapsed = collapsed
        customGroups = groups
        saveWorkspace()
    }

    func collapseAllGroups() {
        guard customGroups.contains(where: { !$0.isCollapsed }) else { return }
        var groups = customGroups
        for index in groups.indices {
            groups[index].isCollapsed = true
        }
        customGroups = groups
        saveWorkspace()
    }

    func expandAllGroups() {
        guard customGroups.contains(where: { $0.isCollapsed }) else { return }
        var groups = customGroups
        for index in groups.indices {
            groups[index].isCollapsed = false
        }
        customGroups = groups
        saveWorkspace()
    }

    func addSession(_ sessionID: String, toGroup groupID: String) {
        addSessions([sessionID], toGroup: groupID)
    }

    func addSessions(_ sessionIDs: [String], toGroup groupID: String) {
        let uniqueIDs = expandedGroupIDs(for: sessionIDs.filter { !$0.isEmpty })
        guard !uniqueIDs.isEmpty else { return }

        var groups = customGroups
        guard let target = groups.firstIndex(where: { $0.id == groupID }) else { return }
        for index in groups.indices where index != target {
            groups[index].sessionIDs.removeAll { uniqueIDs.contains($0) }
        }
        for sessionID in uniqueIDs where !groups[target].sessionIDs.contains(sessionID) {
            groups[target].sessionIDs.append(sessionID)
        }
        groups[target].isCollapsed = false
        customGroups = groups
        saveWorkspace()
    }

    func removeSessionsFromGroups(_ sessionIDs: [String]) {
        let targetIDs = Set(expandedGroupIDs(for: sessionIDs.filter { !$0.isEmpty }))
        guard !targetIDs.isEmpty else { return }
        var groups = customGroups
        var changed = false
        for index in groups.indices {
            let before = groups[index].sessionIDs.count
            groups[index].sessionIDs.removeAll { targetIDs.contains($0) }
            changed = changed || groups[index].sessionIDs.count != before
        }
        guard changed else { return }
        customGroups = groups
        saveWorkspace()
    }

    func removeSessionFromGroup(_ sessionID: String, groupID: String? = nil) {
        let targetIDs = Set(linkedSessionIDs(for: sessionID))
        var groups = customGroups
        var changed = false
        for index in groups.indices {
            if let groupID, groups[index].id != groupID { continue }
            let before = groups[index].sessionIDs.count
            groups[index].sessionIDs.removeAll { targetIDs.contains($0) }
            changed = changed || groups[index].sessionIDs.count != before
        }
        guard changed else { return }
        customGroups = groups
        saveWorkspace()
    }

    func toggleSessionMembership(_ sessionID: String, inGroup groupID: String) {
        guard let group = group(withID: groupID) else { return }
        if group.sessionIDs.contains(sessionID) {
            removeSessionFromGroup(sessionID, groupID: groupID)
        } else {
            addSession(sessionID, toGroup: groupID)
        }
    }

    func deleteGroup(_ id: String) {
        guard customGroups.contains(where: { $0.id == id }) else { return }
        customGroups.removeAll { $0.id == id }
        saveWorkspace()
    }

    private func saveWorkspace() {
        SessionWorkspaceStore.save(
            SessionWorkspace(
                aliases: aliases,
                groups: customGroups,
                brokenLinks: brokenLinks.sorted()
            )
        )
    }

    private func applyAliases(to sessions: inout [SessionSummary]) {
        for index in sessions.indices {
            sessions[index].customTitle = aliases[sessions[index].id]
        }
    }

    func deleteArchivedSession(_ id: String) {
        guard archive.sessions.contains(where: { $0.id == id }) else { return }
        archiveRevision = UUID()
        ArchiveStore.deleteSession(id, reason: "manual")
        archive.sessions.removeAll { $0.id == id }
        cache.removeValue(forKey: id)
        mergedCache.removeAll()

        if var raw = rawSessions.first(where: { $0.id == id }) {
            raw.customTitle = aliases[id]
            if let index = sessions.firstIndex(where: { $0.id == id }) {
                sessions[index] = raw
            }
            if selectedID == id {
                conversation = nil
                select(id)
            }
        } else {
            sessions.removeAll { $0.id == id }
            contentIndex.removeAll { $0.sessionID == id }
            if selectedID == id {
                conversation = nil
                selectedID = sessions.first?.id
                if let first = sessions.first {
                    select(first.id)
                } else {
                    isLoading = false
                }
            }
        }
        lineages = ArchiveLineage.build(sessions: archive.sessions, brokenLinks: brokenLinks)
        normalizeGroupsForChains()
        archiveUsageBytes = ArchiveStore.usageBytes()
        status = sessions.isEmpty ? "没有找到会话" : "\(sessions.count) 个会话"
        scheduleSearch()
    }

    func clearArchive() {
        let rawIDs = Set(rawSessions.map(\.id))
        let allIDs = rawIDs.union(archive.sessions.map(\.id))
        guard !allIDs.isEmpty else { return }
        archiveRevision = UUID()
        ArchiveStore.clear(suppressing: allIDs)
        let lostIDs = Set(archive.sessions.map(\.id)).subtracting(rawIDs)
        archive = ArchiveDocument()
        pinnedArchiveIDs = []
        lineages = [:]
        sessions.removeAll { !rawIDs.contains($0.id) }
        contentIndex.removeAll { lostIDs.contains($0.sessionID) }
        cache.removeAll()
        mergedCache.removeAll()
        if let selectedID, lostIDs.contains(selectedID) {
            conversation = nil
            self.selectedID = sessions.first?.id
            if let first = sessions.first {
                select(first.id)
            } else {
                isLoading = false
            }
        }
        archiveUsageBytes = ArchiveStore.usageBytes()
        status = sessions.isEmpty ? "没有找到会话" : "\(sessions.count) 个会话"
        scheduleSearch()
    }

    func applyArchiveLimit(_ bytes: Int64) {
        AppSettings.setArchiveLimit(bytes)
        archiveRevision = UUID()
        let quota = ArchiveStore.enforceQuotaWithReport(on: archive, maxBytes: bytes)
        let updated = quota.document
        let oldIDs = Set(archive.sessions.map(\.id))
        let evicted = oldIDs.subtracting(updated.sessions.map(\.id))
        archive = updated
        archiveHealth = ArchiveHealth(
            unreadableFiles: archiveHealth.unreadableFiles,
            failedWriteIDs: archiveHealth.failedWriteIDs,
            evictedIDs: quota.evictedIDs,
            overQuota: quota.overQuota
        )
        pinnedArchiveIDs = ArchiveStore.pinnedIDs()
        lineages = ArchiveLineage.build(sessions: updated.sessions, brokenLinks: brokenLinks)

        let rawIDs = Set(rawSessions.map(\.id))
        let lostIDs = evicted.subtracting(rawIDs)
        if !lostIDs.isEmpty {
            sessions.removeAll { lostIDs.contains($0.id) }
            contentIndex.removeAll { lostIDs.contains($0.sessionID) }
            cache = cache.filter { !lostIDs.contains($0.key) }
            mergedCache.removeAll()
        }
        for id in evicted where rawIDs.contains(id) {
            if let index = sessions.firstIndex(where: { $0.id == id }),
               var raw = rawSessions.first(where: { $0.id == id }) {
                raw.customTitle = aliases[id]
                sessions[index] = raw
            }
        }
        if let selectedID, lostIDs.contains(selectedID) {
            conversation = nil
            self.selectedID = sessions.first?.id
            if let first = sessions.first {
                select(first.id)
            } else {
                isLoading = false
            }
        }
        normalizeGroupsForChains()
        archiveUsageBytes = ArchiveStore.usageBytes()
        status = sessions.isEmpty ? "没有找到会话" : "\(sessions.count) 个会话"
        scheduleSearch()
    }

    func sessionDateLabel() -> String {
        conversation?.session.date.relativeDayLabel ?? "—"
    }

    private func activatePendingFocus() {
        guard let focus = pendingFocus, focus.sessionID == selectedID else {
            pendingFocus = nil
            return
        }

        // A merged chain intentionally cuts the parent at the fork point. If
        // the requested search hit lives after that point, fall back to the
        // complete segment instead of silently failing to scroll.
        if readingMode == .merged,
           chainIDs(for: focus.sessionID).count > 1,
           let conversation,
           !conversation.contains(turnID: focus.turnID, itemID: focus.itemID) {
            selectSegment(focus.sessionID)
            return
        }

        pendingFocus = nil
        highlightedItemID = focus.itemID
        searchFocus = focus
    }

    private func rebuildArchiveAndIndex(
        rawSessions: [SessionSummary],
        existingArchive: ArchiveDocument
    ) {
        indexTask?.cancel()
        let generation = UUID()
        indexGeneration = generation
        contentIndex = []
        contentIndexReady = false
        isIndexingContent = !rawSessions.isEmpty || !existingArchive.sessions.isEmpty
        searchHits = []
        searchSessions = []
        searchTotal = 0
        activeSearchSessionID = nil
        pendingFocus = nil
        searchFocus = nil
        highlightedItemID = nil
        imageFocus = nil
        highlightedImageID = nil
        turnFocus = nil
        lastSearchQuery = ""

        guard isIndexingContent else {
            contentIndexReady = true
            scheduleSearch()
            return
        }

        let snapshotBrokenLinks = brokenLinks
        indexTask = Task.detached(priority: .utility) {
            let syncResult = ArchiveStore.syncWithReport(
                rawSessions: rawSessions,
                existing: existingArchive,
                maxBytes: AppSettings.archiveLimitBytes
            )
            let updated = syncResult.document

            let finalEntries = ArchiveStore.searchEntries(
                for: updated,
                rawSessions: rawSessions
            )
            let usage = ArchiveStore.usageBytes()
            let lineages = ArchiveLineage.build(
                sessions: updated.sessions,
                brokenLinks: snapshotBrokenLinks
            )
            let pinned = ArchiveStore.pinnedIDs()

            await MainActor.run {
                guard self.indexGeneration == generation else { return }
                self.rawSessions = rawSessions
                self.archive = updated
                self.archiveUsageBytes = usage
                self.archiveHealth = ArchiveHealth(
                    unreadableFiles: self.archiveHealth.unreadableFiles,
                    failedWriteIDs: syncResult.failedWriteIDs,
                    evictedIDs: syncResult.evictedIDs,
                    overQuota: syncResult.overQuota
                )
                self.pinnedArchiveIDs = pinned
                if self.lineages != lineages {
                    self.mergedCache.removeAll()
                }
                self.lineages = lineages
                var merged = ArchiveStore.merge(raw: rawSessions, archive: updated)
                self.applyAliases(to: &merged)
                self.sessions = merged
                self.normalizeGroupsForChains()
                self.status = self.sessions.isEmpty ? "没有找到会话" : "\(self.sessions.count) 个会话"
                self.contentIndex = finalEntries
                self.contentIndexReady = true
                self.isIndexingContent = false

                if let id = self.selectedID,
                   let summary = self.sessions.first(where: { $0.id == id }),
                   summary.isArchived,
                   let archived = updated.sessions.first(where: { $0.id == id }) {
                    let conversation = ArchiveStore.conversation(
                        for: archived,
                        summary: summary
                    )
                    self.cache[id] = conversation
                    self.mergedCache.removeAll()
                    self.conversation = conversation
                    self.isLoading = false
                }

                self.scheduleSearch()
                if self.liveSyncPending {
                    self.scheduleLiveSyncIfIdle()
                }
            }
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if q != lastSearchQuery {
            lastSearchQuery = q
            activeSearchSessionID = nil
            pendingFocus = nil
            searchFocus = nil
            highlightedItemID = nil
        }

        guard !q.isEmpty else {
            searchHits = []
            searchSessions = []
            searchTotal = 0
            return
        }

        guard contentIndexReady else { return }

        searchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self else { return }
            let scope = self.searchScopeSessionID
            let entries = scope.map { value in
                self.contentIndex.filter { $0.sessionID == value }
            } ?? self.contentIndex
            let result = ContentSearchMatcher.search(q, in: entries)
            guard q == self.query.trimmingCharacters(in: .whitespacesAndNewlines),
                  scope == self.searchScopeSessionID else { return }

            let grouped: [ContentSearchSessionResult]
            if let scope {
                grouped = result.hits.isEmpty ? [] : [
                    ContentSearchSessionResult(
                        sessionID: scope,
                        chainIDs: [scope],
                        hits: result.hits
                    )
                ]
            } else {
                grouped = self.groupSearchHits(result.hits)
            }
            self.searchHits = result.hits
            self.searchSessions = grouped
            self.searchTotal = grouped.reduce(0) { $0 + $1.count }
        }
    }

    private func groupSearchHits(_ hits: [ContentSearchHit]) -> [ContentSearchSessionResult] {
        var buckets: [String: [ContentSearchHit]] = [:]
        var seenMessages: [String: Set<String>] = [:]

        for hit in hits {
            let root = chainRoot(for: hit.entry.sessionID)
            let messageKey = hit.entry.messageID
            if seenMessages[root, default: []].contains(messageKey) {
                continue
            }
            seenMessages[root, default: []].insert(messageKey)
            buckets[root, default: []].append(hit)
        }

        return buckets
            .map { root, hits in
                ContentSearchSessionResult(
                    sessionID: root,
                    chainIDs: linkedSessionIDs(for: root),
                    hits: hits
                )
            }
            .sorted {
                ($0.latest?.entry.timestamp ?? .distantPast) >
                    ($1.latest?.entry.timestamp ?? .distantPast)
            }
    }
}
