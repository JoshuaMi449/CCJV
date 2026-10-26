import Foundation

/// 本地问答归档：只保存主会话的用户提问/最终回答，以及子代理的任务与最终报告。
/// 不保存工具输出、思考、中间回复或子代理过程。
struct ArchivedMessage: Codable, Identifiable {
    enum Role: String, Codable {
        case user
        case assistant
    }

    let id: String
    let turnID: String
    let role: Role
    let text: String
    let timestamp: Date?
    /// The raw JSONL record uuid, kept separately from the display id so a
    /// later session's compact boundary can still be matched to this archive
    /// after Claude Code removes the original file.
    var rawUUID: String? = nil
}

struct ArchivedCheckpoint: Codable {
    let timestamp: Date?
    let trigger: String?
    let preTokens: Int?
    let postTokens: Int?
    /// Number of archived human turns before this boundary. Zero means the
    /// boundary sits at the head of the session (a continuation/fork), not an
    /// ordinary in-session compaction.
    let turnIndex: Int
    let preservedUUIDs: [String]
    let allUUIDs: [String]
    let anchorUUID: String?
    let logicalParentUUID: String?
}

struct ArchivedSubagent: Codable, Identifiable {
    let id: String
    let toolUseID: String?
    let turnID: String?
    let agentType: String
    let title: String
    let prompt: String
    let report: String
    let status: String
    let startedAt: Date?
    let endedAt: Date?

    var duration: TimeInterval {
        guard let startedAt, let endedAt else { return 0 }
        return max(0, endedAt.timeIntervalSince(startedAt))
    }
}

struct ArchivedSession: Codable, Identifiable {
    let id: String
    let sourcePath: String
    var title: String
    var project: String
    var date: Date
    var mainSignature: String
    var subagentSignature: String
    var messages: [ArchivedMessage]
    var subagents: [ArchivedSubagent]

    // Optional so archives written by older versions still decode.
    var schema: Int? = nil
    /// Every raw record uuid, not just displayed messages. Compact boundaries
    /// reference user, assistant and system records, so keeping all uuids lets
    /// the lineage survive after the raw JSONL is cleaned up.
    var messageUUIDs: [String]? = nil
    var checkpoints: [ArchivedCheckpoint]? = nil
}

struct ArchiveDocument: Codable {
    static let currentVersion = 4
    var version = ArchiveDocument.currentVersion
    var sessions: [ArchivedSession] = []
}

struct ArchiveLoadResult {
    var document: ArchiveDocument
    var unreadableFiles: [String] = []
}

struct ArchiveSyncResult {
    var document: ArchiveDocument
    var failedWriteIDs: [String] = []
    var evictedIDs: [String] = []
    var overQuota = false
}

struct ArchiveHealth: Equatable {
    var unreadableFiles: [String] = []
    var failedWriteIDs: [String] = []
    var evictedIDs: [String] = []
    var overQuota = false

    var hasIssues: Bool {
        !unreadableFiles.isEmpty
            || !failedWriteIDs.isEmpty
            || !evictedIDs.isEmpty
            || overQuota
    }
}

private enum ArchiveSchema {
    /// 2 adds messageUUIDs/checkpoints and rawUUID on messages.
    static let current = 2
}

private struct ArchiveState: Codable {
    static let currentVersion = 4
    var version = ArchiveState.currentVersion
    var suppressed: [String: String] = [:]
    /// Optional so state files written before pinning still decode.
    var pinned: Set<String>? = nil
}

private struct ArchiveAssistantChunk {
    let id: String
    var text: String
    let timestamp: Date?
    let rawUUID: String?
}

private struct ArchiveAgentUse {
    let toolUseID: String
    let turnID: String
    let prompt: String
    let agentType: String
    let title: String
}

private struct ArchiveMainScan {
    var messages: [ArchivedMessage] = []
    var agentUses: [String: ArchiveAgentUse] = [:]
    var userTurns: [(timestamp: Date, turnID: String)] = []
    var messageUUIDs = Set<String>()
    var checkpoints: [ArchivedCheckpoint] = []
}

private struct ArchiveAgentScan {
    var firstUserText: String?
    var report: String = ""
    var startedAt: Date?
    var endedAt: Date?
}

private struct ArchiveTurnDraft {
    let userID: String
    let turnID: String
    let userTimestamp: Date?
    var assistants: [ArchiveAssistantChunk] = []
}

enum ArchiveStore {
    static var directoryOverride: URL?

    static var directoryURL: URL {
        if let directoryOverride { return directoryOverride }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Claude Recall", isDirectory: true)
    }

    static var archiveFolderURL: URL {
        directoryURL.appendingPathComponent("Archive", isDirectory: true)
    }

    static var stateURL: URL {
        archiveFolderURL.appendingPathComponent("state.json")
    }

    static var legacyArchiveURL: URL {
        directoryURL.appendingPathComponent("archive.json")
    }

    static func sessionFileURL(for id: String) -> URL {
        let safe = id
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return archiveFolderURL.appendingPathComponent("\(safe).json")
    }

    // MARK: - Document

    static func load() -> ArchiveDocument {
        loadWithReport().document
    }

    static func loadWithReport() -> ArchiveLoadResult {
        ensureFolders()
        migrateLegacyIfNeeded()

        let state = loadState()
        let decoder = makeDecoder()
        let fm = FileManager.default
        var sessions: [ArchivedSession] = []
        var unreadable: [String] = []

        if let files = try? fm.contentsOfDirectory(
            at: archiveFolderURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for file in files where file.pathExtension == "json"
                && file.lastPathComponent != "state.json" {
                guard let data = try? Data(contentsOf: file),
                      let session = try? decoder.decode(ArchivedSession.self, from: data) else {
                    unreadable.append(file.lastPathComponent)
                    continue
                }
                if state.suppressed[session.id] != nil {
                    try? fm.removeItem(at: file)
                    continue
                }
                sessions.append(session)
            }
        }

        sessions.sort {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id < $1.id
        }
        return ArchiveLoadResult(
            document: ArchiveDocument(sessions: sessions),
            unreadableFiles: unreadable.sorted()
        )
    }

    static func pinnedIDs() -> Set<String> {
        loadState().pinned ?? []
    }

    static func setPinned(_ id: String, pinned: Bool) {
        var state = loadState()
        var ids = state.pinned ?? []
        if pinned {
            ids.insert(id)
        } else {
            ids.remove(id)
        }
        state.pinned = ids
        saveState(state)
    }

    static func usageBytes() -> Int64 {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: archiveFolderURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for file in files {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    private static func ensureFolders() {
        let fm = FileManager.default
        try? fm.createDirectory(
            at: archiveFolderURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: archiveFolderURL.path)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func writeFile(_ data: Data, to url: URL) -> Bool {
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            return true
        } catch {
            return false
        }
    }

    private static func writeSessionFile(_ session: ArchivedSession) -> Bool {
        guard let data = try? makeEncoder().encode(session) else { return false }
        return writeFile(data, to: sessionFileURL(for: session.id))
    }

    // MARK: - State

    private static func loadState() -> ArchiveState {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? makeDecoder().decode(ArchiveState.self, from: data) else {
            return ArchiveState()
        }
        return state
    }

    private static func saveState(_ state: ArchiveState) {
        ensureFolders()
        var state = state
        state.version = ArchiveState.currentVersion
        guard let data = try? makeEncoder().encode(state) else { return }
        _ = writeFile(data, to: stateURL)
    }

    // MARK: - Migration

    private static func migrateLegacyIfNeeded() {
        let fm = FileManager.default
        if fm.fileExists(atPath: stateURL.path) {
            if fm.fileExists(atPath: legacyArchiveURL.path) {
                try? fm.removeItem(at: legacyArchiveURL)
            }
            return
        }

        guard fm.fileExists(atPath: legacyArchiveURL.path),
              let data = try? Data(contentsOf: legacyArchiveURL),
              let legacy = try? makeDecoder().decode(ArchiveDocument.self, from: data) else {
            return
        }

        var written = 0
        for session in legacy.sessions {
            if writeSessionFile(stripped(session)) {
                written += 1
            }
        }
        guard written == legacy.sessions.count else { return }
        saveState(ArchiveState())
        try? fm.removeItem(at: legacyArchiveURL)
    }

    // MARK: - Sync

    static func sync(
        rawSessions: [SessionSummary],
        existing: ArchiveDocument,
        maxBytes: Int64
    ) -> ArchiveDocument {
        syncWithReport(rawSessions: rawSessions, existing: existing, maxBytes: maxBytes).document
    }

    static func syncWithReport(
        rawSessions: [SessionSummary],
        existing: ArchiveDocument,
        maxBytes: Int64
    ) -> ArchiveSyncResult {
        ensureFolders()
        migrateLegacyIfNeeded()
        var state = loadState()
        var byID: [String: ArchivedSession] = [:]
        var failedWriteIDs: [String] = []

        for session in existing.sessions {
            if state.suppressed[session.id] != nil {
                try? FileManager.default.removeItem(at: sessionFileURL(for: session.id))
                continue
            }
            byID[session.id] = session
        }

        for session in rawSessions {
            if state.suppressed[session.id] != nil { continue }
            let mainSignature = mainSignature(session)
            let subagentSignature = subagentSignature(session)
            if let old = byID[session.id],
               old.mainSignature == mainSignature,
               old.subagentSignature == subagentSignature,
               (old.schema ?? 0) >= ArchiveSchema.current {
                continue
            }
            guard let built = build(
                session: session,
                mainSignature: mainSignature,
                subagentSignature: subagentSignature
            ) else { continue }
            if writeSessionFile(built) {
                byID[session.id] = built
            } else {
                failedWriteIDs.append(session.id)
            }
        }

        let eviction = evictIfNeeded(&byID, maxBytes: maxBytes, state: &state)
        saveState(state)
        return ArchiveSyncResult(
            document: sortedDocument(byID),
            failedWriteIDs: failedWriteIDs.sorted(),
            evictedIDs: eviction.evicted.sorted(),
            overQuota: eviction.overQuota
        )
    }

    static func enforceQuota(on document: ArchiveDocument, maxBytes: Int64) -> ArchiveDocument {
        enforceQuotaWithReport(on: document, maxBytes: maxBytes).document
    }

    static func enforceQuotaWithReport(
        on document: ArchiveDocument,
        maxBytes: Int64
    ) -> ArchiveSyncResult {
        ensureFolders()
        migrateLegacyIfNeeded()
        var state = loadState()
        var byID: [String: ArchivedSession] = [:]
        for session in document.sessions {
            if state.suppressed[session.id] != nil {
                try? FileManager.default.removeItem(at: sessionFileURL(for: session.id))
                continue
            }
            byID[session.id] = session
        }
        let eviction = evictIfNeeded(&byID, maxBytes: maxBytes, state: &state)
        saveState(state)
        return ArchiveSyncResult(
            document: sortedDocument(byID),
            evictedIDs: eviction.evicted.sorted(),
            overQuota: eviction.overQuota
        )
    }

    private static func sortedDocument(_ byID: [String: ArchivedSession]) -> ArchiveDocument {
        ArchiveDocument(sessions: byID.values.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id < $1.id
        })
    }

    static func deleteSession(_ id: String, reason: String) {
        ensureFolders()
        var state = loadState()
        state.suppressed[id] = reason
        saveState(state)
        try? FileManager.default.removeItem(at: sessionFileURL(for: id))
    }

    static func clear(suppressing ids: Set<String>) {
        ensureFolders()
        var state = loadState()
        for id in ids {
            state.suppressed[id] = "cleared"
        }
        state.pinned = []
        saveState(state)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: archiveFolderURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for file in files where file.lastPathComponent != "state.json" {
            try? fm.removeItem(at: file)
        }
    }

    private static func evictIfNeeded(
        _ byID: inout [String: ArchivedSession],
        maxBytes: Int64,
        state: inout ArchiveState
    ) -> (evicted: [String], overQuota: Bool) {
        guard maxBytes > 0 else { return ([], false) }
        var usage = usageBytes()
        guard usage > maxBytes else { return ([], false) }

        // Evict whole continuation components, never half a chain. This keeps
        // the archive's lineage readable after capacity pressure.
        var parent: [String: String] = [:]
        for id in byID.keys { parent[id] = id }

        func root(_ value: String) -> String {
            var current = value
            while let next = parent[current], next != current {
                current = next
            }
            return current
        }

        func union(_ lhs: String, _ rhs: String) {
            let left = root(lhs)
            let right = root(rhs)
            if left != right { parent[right] = left }
        }

        let lineages = ArchiveLineage.build(sessions: Array(byID.values))
        for (id, lineage) in lineages {
            if let parentID = lineage.parentID, byID[parentID] != nil {
                union(id, parentID)
            }
        }

        var components: [String: [ArchivedSession]] = [:]
        for session in byID.values {
            components[root(session.id), default: []].append(session)
        }
        let ordered = components.values.sorted { lhs, rhs in
            let left = lhs.map(\.date).min() ?? .distantPast
            let right = rhs.map(\.date).min() ?? .distantPast
            if left != right { return left < right }
            return (lhs.first?.id ?? "") < (rhs.first?.id ?? "")
        }

        let pinned = state.pinned ?? []
        var evicted: [String] = []
        for component in ordered {
            guard usage > maxBytes else { break }
            if component.contains(where: { pinned.contains($0.id) }) {
                continue
            }
            for session in component {
                let url = sessionFileURL(for: session.id)
                let number = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
                let size = number?.int64Value ?? 0
                try? FileManager.default.removeItem(at: url)
                byID.removeValue(forKey: session.id)
                state.suppressed[session.id] = "evicted"
                evicted.append(session.id)
                usage = max(0, usage - size)
            }
        }

        return (evicted, usage > maxBytes)
    }

    // MARK: - Sessions

    static func merge(raw: [SessionSummary], archive: ArchiveDocument) -> [SessionSummary] {
        let rawIDs = Set(raw.map(\.id))
        var merged = raw
        for archived in archive.sessions where !rawIDs.contains(archived.id) {
            merged.append(summary(for: archived))
        }
        return merged.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id < $1.id
        }
    }

    static func summary(for archived: ArchivedSession) -> SessionSummary {
        let userMessages = archived.messages.filter { $0.role == .user }
        let previewText = userMessages.first?.text
            ?? archived.subagents.first?.report
            ?? ""
        let lastMessageDate = archived.messages.compactMap { $0.timestamp }.max()
        return SessionSummary(
            id: archived.id,
            title: archived.title.isEmpty ? "已归档会话" : archived.title,
            project: archived.project,
            preview: String(flatten(previewText).prefix(80)),
            date: lastMessageDate ?? archived.date,
            turns: userMessages.count,
            fileURL: URL(fileURLWithPath: archived.sourcePath),
            subagentCount: archived.subagents.count,
            fileSize: 0,
            isArchived: true
        )
    }

    static func conversation(for archived: ArchivedSession, summary: SessionSummary) -> Conversation {
        var items: [ConversationItem] = []
        var branchesByTurn: [String: [ArchivedSubagent]] = [:]
        for subagent in archived.subagents {
            guard let turnID = subagent.turnID, !turnID.isEmpty else { continue }
            branchesByTurn[turnID, default: []].append(subagent)
        }

        var attached = Set<String>()
        for message in archived.messages {
            switch message.role {
            case .user:
                items.append(.user(
                    id: rawItemID(message.id, prefix: "u-"),
                    text: message.text,
                    timestamp: message.timestamp
                ))
                let branches = (branchesByTurn[message.turnID] ?? []).sorted {
                    ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast)
                }
                for subagent in branches {
                    items.append(branchItem(subagent, parentID: archived.id))
                    attached.insert(subagent.id)
                }
            case .assistant:
                items.append(.assistant(
                    id: rawItemID(message.id, prefix: "a-"),
                    text: message.text,
                    model: "Claude",
                    timestamp: message.timestamp
                ))
            }
        }

        for subagent in archived.subagents where !attached.contains(subagent.id) {
            items.append(branchItem(subagent, parentID: archived.id))
        }

        let startedAt = archived.messages.compactMap { $0.timestamp }.min() ?? archived.date
        return Conversation(
            session: summary,
            items: items,
            turns: Conversation.groupTurns(items),
            branchCount: archived.subagents.count,
            imageCount: 0,
            eventCount: items.count,
            startedAt: startedAt
        )
    }

    private static func rawItemID(_ id: String, prefix: String) -> String {
        id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : id
    }

    private static func branchItem(_ subagent: ArchivedSubagent, parentID: String) -> ConversationItem {
        let node = BranchNode(
            id: subagent.id,
            parentId: parentID,
            toolUseId: subagent.toolUseID ?? "",
            agentType: subagent.agentType,
            title: subagent.title.isEmpty ? "子代理" : subagent.title,
            prompt: subagent.prompt,
            fileURL: nil,
            status: subagent.status
        )
        node.report = subagent.report.isEmpty ? nil : subagent.report
        node.isLoaded = true
        node.isArchived = true
        node.steps = 0
        node.duration = subagent.duration
        return .branch(id: subagent.id, node: node)
    }

    static func searchEntries(for sessions: [ArchivedSession]) -> [ContentSearchEntry] {
        var result: [ContentSearchEntry] = []
        for session in sessions {
            for message in session.messages {
                result.append(ContentSearchEntry(
                    id: "arc-\(session.id)-\(message.id)",
                    sessionID: session.id,
                    turnID: message.turnID,
                    messageID: message.id,
                    role: message.role == .user ? .user : .assistant,
                    text: message.text,
                    timestamp: message.timestamp
                ))
            }
        }
        return result
    }

    static func searchEntries(
        for archive: ArchiveDocument,
        rawSessions: [SessionSummary]
    ) -> [ContentSearchEntry] {
        var archivedByID: [String: ArchivedSession] = [:]
        for session in archive.sessions {
            archivedByID[session.id] = session
        }
        var entries = searchEntries(for: archive.sessions)
        let fallback = rawSessions.filter { session in
            guard let archived = archivedByID[session.id] else { return true }
            return archived.messages.isEmpty
        }
        if !fallback.isEmpty {
            entries.append(contentsOf: ContentSearchIndexer.build(sessions: fallback))
        }
        return entries
    }

    // MARK: - Signatures

    private static func mainSignature(_ session: SessionSummary) -> String {
        // Keep using the file's mtime for the archive signature even though
        // SessionSummary.date now means "last conversation message". Using
        // the display date here would invalidate every existing archive.
        let modifiedAt = (try? session.fileURL.resourceValues(
            forKeys: [.contentModificationDateKey]
        ))?.contentModificationDate?.timeIntervalSince1970
        return "\(session.fileSize)-\(modifiedAt ?? session.date.timeIntervalSince1970)"
    }

    private static func subagentSignature(_ session: SessionSummary) -> String {
        let dir = subagentsDirectory(for: session.fileURL)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return "0-0-0"
        }

        var count = 0
        var bytes: Int64 = 0
        var latest: TimeInterval = 0
        for file in files {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            count += 1
            bytes += Int64(values?.fileSize ?? 0)
            latest = max(latest, values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }
        return "\(count)-\(bytes)-\(latest)"
    }

    private static func subagentsDirectory(for sessionFile: URL) -> URL {
        sessionFile.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
    }

    // MARK: - Build

    private static func build(
        session: SessionSummary,
        mainSignature: String,
        subagentSignature: String
    ) -> ArchivedSession? {
        let main = scanMain(session: session)
        let subagents = scanSubagents(
            session: session,
            agentUses: main.agentUses,
            timeline: main.userTurns
        )
        guard !main.messages.isEmpty || !subagents.isEmpty else { return nil }

        return ArchivedSession(
            id: session.id,
            sourcePath: session.fileURL.path,
            title: session.title,
            project: session.project,
            date: session.date,
            mainSignature: mainSignature,
            subagentSignature: subagentSignature,
            messages: main.messages,
            subagents: subagents,
            schema: ArchiveSchema.current,
            messageUUIDs: main.messageUUIDs.sorted(),
            checkpoints: main.checkpoints
        )
    }

    private static func scanMain(session: SessionSummary) -> ArchiveMainScan {
        var scan = ArchiveMainScan()
        var current: ArchiveTurnDraft?
        var currentTurnID: String?
        var seenUsers = Set<String>()
        var seenAnswers = Set<String>()
        var humanTurnCount = 0

        func appendAnswer(_ turn: ArchiveTurnDraft) {
            guard let answer = chooseAnswer(turn.assistants),
                  !seenAnswers.contains(answer.id) else { return }
            seenAnswers.insert(answer.id)
            scan.messages.append(ArchivedMessage(
                id: "a-\(answer.id)",
                turnID: turn.turnID,
                role: .assistant,
                text: stripCodeBlocks(answer.text),
                timestamp: answer.timestamp ?? turn.userTimestamp,
                rawUUID: answer.rawUUID
            ))
        }

        func flush() {
            guard let turn = current else { return }
            current = nil
            appendAnswer(turn)
        }

        guard let reader = try? LineReader(url: session.fileURL) else { return scan }
        reader.forEachLine { line in
            guard let object = JSONL.object(line) else { return true }

            if let uuid = object["uuid"] as? String {
                scan.messageUUIDs.insert(uuid)
            }
            if (object["type"] as? String) == "system",
               (object["subtype"] as? String) == "compact_boundary" {
                scan.checkpoints.append(
                    checkpoint(from: object, turnIndex: humanTurnCount)
                )
            }

            guard let type = object["type"] as? String else { return true }

            if type == "user" {
                if let origin = object["origin"] as? [String: Any],
                   (origin["kind"] as? String) == "task-notification" {
                    return true
                }
                guard let message = object["message"] as? [String: Any],
                      JSONL.isHuman(object),
                      let raw = humanText(message) else { return true }
                guard !JSONL.isCommandWrapper(raw) else { return true }
                let cleaned = JSONL.cleanUserText(raw)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty, !isNoise(cleaned) else { return true }

                let userID = object["uuid"] as? String ?? UUID().uuidString
                guard !seenUsers.contains(userID) else { return true }
                seenUsers.insert(userID)

                flush()
                let turnID = "u-\(userID)"
                let timestamp = JSONL.date(object["timestamp"])
                scan.messages.append(ArchivedMessage(
                    id: "u-\(userID)",
                    turnID: turnID,
                    role: .user,
                    text: stripCodeBlocks(cleaned),
                    timestamp: timestamp,
                    rawUUID: object["uuid"] as? String
                ))
                humanTurnCount += 1
                if let timestamp {
                    scan.userTurns.append((timestamp: timestamp, turnID: turnID))
                }
                current = ArchiveTurnDraft(
                    userID: userID,
                    turnID: turnID,
                    userTimestamp: timestamp
                )
                currentTurnID = turnID
            } else if type == "assistant" {
                guard let message = object["message"] as? [String: Any],
                      let blocks = message["content"] as? [[String: Any]] else { return true }

                for block in blocks where (block["type"] as? String) == "tool_use" {
                    let name = block["name"] as? String ?? ""
                    guard name == "Agent" || name == "Task",
                          let toolUseID = block["id"] as? String else { continue }
                    let input = block["input"] as? [String: Any] ?? [:]
                    scan.agentUses[toolUseID] = ArchiveAgentUse(
                        toolUseID: toolUseID,
                        turnID: currentTurnID ?? "turn-unknown",
                        prompt: input["prompt"] as? String ?? "",
                        agentType: input["subagent_type"] as? String ?? "Agent",
                        title: input["description"] as? String ?? "子代理"
                    )
                }

                guard var turn = current,
                      let text = assistantText(message) else { return true }
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { return true }

                let messageID = message["id"] as? String
                    ?? object["uuid"] as? String
                    ?? UUID().uuidString
                if let index = turn.assistants.firstIndex(where: { $0.id == messageID }) {
                    let separator = turn.assistants[index].text.hasSuffix("\n") ? "" : "\n\n"
                    turn.assistants[index].text += separator + cleaned
                } else {
                    turn.assistants.append(ArchiveAssistantChunk(
                        id: messageID,
                        text: cleaned,
                        timestamp: JSONL.date(object["timestamp"]),
                        rawUUID: object["uuid"] as? String
                    ))
                }
                current = turn
            }
            return true
        }
        flush()
        return scan
    }

    private static func checkpoint(from object: [String: Any], turnIndex: Int) -> ArchivedCheckpoint {
        let metadata = object["compactMetadata"] as? [String: Any] ?? [:]
        let preserved = metadata["preservedMessages"] as? [String: Any] ?? [:]
        let segment = metadata["preservedSegment"] as? [String: Any] ?? [:]
        let preservedUUIDs = preserved["uuids"] as? [String] ?? []
        let allUUIDs = preserved["allUuids"] as? [String] ?? preservedUUIDs
        let anchor = (preserved["anchorUuid"] as? String)
            ?? (segment["anchorUuid"] as? String)

        return ArchivedCheckpoint(
            timestamp: JSONL.date(object["timestamp"]),
            trigger: metadata["trigger"] as? String,
            preTokens: metadata["preTokens"] as? Int,
            postTokens: metadata["postTokens"] as? Int,
            turnIndex: turnIndex,
            preservedUUIDs: preservedUUIDs,
            allUUIDs: allUUIDs,
            anchorUUID: anchor,
            logicalParentUUID: object["logicalParentUuid"] as? String
        )
    }

    private static func scanSubagents(
        session: SessionSummary,
        agentUses: [String: ArchiveAgentUse],
        timeline: [(timestamp: Date, turnID: String)]
    ) -> [ArchivedSubagent] {
        let dir = subagentsDirectory(for: session.fileURL)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var result: [ArchivedSubagent] = []
        for url in files where url.pathExtension == "jsonl"
            && url.lastPathComponent.hasPrefix("agent-") {
            let agentID = String(
                url.deletingPathExtension().lastPathComponent
                    .dropFirst("agent-".count)
            )
            guard !agentID.isEmpty else { continue }

            let metaURL = URL(fileURLWithPath: url.deletingPathExtension().path + ".meta.json")
            var meta: [String: Any] = [:]
            if let data = try? Data(contentsOf: metaURL),
               let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                meta = object
            }
            let toolUseID = meta["toolUseId"] as? String
            let use = toolUseID.flatMap { agentUses[$0] }

            let agentScan = scanAgentFile(url)
            guard !agentScan.report.isEmpty else { continue }

            let fallbackTurn = agentScan.startedAt.flatMap { started in
                timeline.last(where: { $0.timestamp <= started })?.turnID
            }

            result.append(ArchivedSubagent(
                id: agentID,
                toolUseID: toolUseID,
                turnID: use?.turnID ?? fallbackTurn,
                agentType: use?.agentType ?? meta["agentType"] as? String ?? "Agent",
                title: use?.title ?? meta["description"] as? String ?? "子代理",
                prompt: stripCodeBlocks(use?.prompt ?? agentScan.firstUserText ?? ""),
                report: stripCodeBlocks(agentScan.report),
                status: "已归档",
                startedAt: agentScan.startedAt,
                endedAt: agentScan.endedAt
            ))
        }

        return result.sorted {
            ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast)
        }
    }

    private static func scanAgentFile(_ url: URL) -> ArchiveAgentScan {
        var scan = ArchiveAgentScan()
        var chunks: [ArchiveAssistantChunk] = []
        var indexes: [String: Int] = [:]

        guard let reader = try? LineReader(url: url) else { return scan }
        reader.forEachLine { line in
            guard let object = JSONL.object(line) else { return true }
            let timestamp = JSONL.date(object["timestamp"])
            if let timestamp {
                if scan.startedAt == nil { scan.startedAt = timestamp }
                scan.endedAt = timestamp
            }

            guard let type = object["type"] as? String,
                  let message = object["message"] as? [String: Any] else { return true }

            if type == "user" {
                if scan.firstUserText == nil,
                   let text = JSONL.messageText(message),
                   !JSONL.isCommandWrapper(text) {
                    scan.firstUserText = text
                }
            } else if type == "assistant", let text = assistantText(message) {
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { return true }
                let messageID = message["id"] as? String
                    ?? object["uuid"] as? String
                    ?? UUID().uuidString
                if let index = indexes[messageID] {
                    let separator = chunks[index].text.hasSuffix("\n") ? "" : "\n\n"
                    chunks[index].text += separator + cleaned
                } else {
                    indexes[messageID] = chunks.count
                    chunks.append(ArchiveAssistantChunk(
                        id: messageID,
                        text: cleaned,
                        timestamp: timestamp,
                        rawUUID: object["uuid"] as? String
                    ))
                }
            }
            return true
        }

        scan.report = chooseAnswer(chunks)?.text ?? ""
        return scan
    }

    // MARK: - Helpers

    private static func humanText(_ message: [String: Any]) -> String? {
        if let blocks = message["content"] as? [[String: Any]] {
            let text = blocks.compactMap { block -> String? in
                guard (block["type"] as? String) == "text" else { return nil }
                return block["text"] as? String
            }.joined(separator: "\n")
            return text.isEmpty ? nil : text
        }
        return message["content"] as? String
    }

    private static func assistantText(_ message: [String: Any]) -> String? {
        guard let blocks = message["content"] as? [[String: Any]] else { return nil }
        let text = blocks.compactMap { block -> String? in
            guard (block["type"] as? String) == "text" else { return nil }
            return block["text"] as? String
        }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    private static func chooseAnswer(_ chunks: [ArchiveAssistantChunk]) -> ArchiveAssistantChunk? {
        guard let last = chunks.last else { return nil }
        if last.text.trimmingCharacters(in: .whitespacesAndNewlines).count < 16,
           let earlier = chunks.dropLast().last(where: {
               $0.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 40
           }) {
            return earlier
        }
        return last
    }

    private static func isNoise(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("[Request interrupted by user")
    }

    private static func stripped(_ session: ArchivedSession) -> ArchivedSession {
        var copy = session
        copy.messages = session.messages.map { message in
            ArchivedMessage(
                id: message.id,
                turnID: message.turnID,
                role: message.role,
                text: stripCodeBlocks(message.text),
                timestamp: message.timestamp,
                rawUUID: message.rawUUID
            )
        }
        copy.subagents = session.subagents.map { subagent in
            ArchivedSubagent(
                id: subagent.id,
                toolUseID: subagent.toolUseID,
                turnID: subagent.turnID,
                agentType: subagent.agentType,
                title: subagent.title,
                prompt: stripCodeBlocks(subagent.prompt),
                report: stripCodeBlocks(subagent.report),
                status: subagent.status,
                startedAt: subagent.startedAt,
                endedAt: subagent.endedAt
            )
        }
        return copy
    }

    private static func stripCodeBlocks(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var output: [String] = []
        var inFence = false

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inFence {
                    inFence = false
                    output.append("[代码块已省略]")
                } else {
                    inFence = true
                }
                continue
            }
            if !inFence {
                output.append(line)
            }
        }
        if inFence {
            output.append("[代码块已省略]")
        }
        return output.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func flatten(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
