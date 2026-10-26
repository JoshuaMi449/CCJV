import Foundation

struct SessionChainPart {
    let summary: SessionSummary
    let conversation: Conversation
    /// Turns starting after this boundary belong to a later segment/branch.
    let cutoffDate: Date?
}

enum SessionChain {
    /// Follow strong links in both directions. A fork with more than one child
    /// is ambiguous, so it is not merged as one linear reading path.
    static func chainIDs(for id: String, lineages: [String: SessionLineage]) -> [String] {
        var ancestors = [id]
        var visited: Set<String> = [id]
        var cursor = id

        while let info = lineages[cursor],
              info.isStrong,
              let parentID = info.parentID,
              !visited.contains(parentID) {
            ancestors.insert(parentID, at: 0)
            visited.insert(parentID)
            cursor = parentID
        }

        guard let root = ancestors.first else { return [id] }
        var linear = [root]
        cursor = root
        while true {
            let children = lineages[cursor]?.children.filter { childID in
                lineages[childID]?.isStrong == true
                    && lineages[childID]?.parentID == cursor
            } ?? []
            guard children.count == 1,
                  let childID = children.first,
                  !linear.contains(childID) else {
                break
            }
            linear.append(childID)
            cursor = childID
        }

        return linear.contains(id) ? linear : ancestors
    }

    static func load(summary: SessionSummary, archive: ArchiveDocument) -> Conversation? {
        if !summary.isArchived,
           FileManager.default.fileExists(atPath: summary.fileURL.path) {
            let parsed = SessionParser(url: summary.fileURL, summary: summary).parse()
            if !parsed.items.isEmpty {
                return parsed
            }
        }

        guard let archived = archive.sessions.first(where: { $0.id == summary.id }) else {
            return nil
        }
        var archivedSummary = summary
        archivedSummary.isArchived = true
        let archivedConversation = ArchiveStore.conversation(
            for: archived,
            summary: archivedSummary
        )
        return archivedConversation.items.isEmpty ? nil : archivedConversation
    }

    static func merge(parts: [SessionChainPart], selectedID: String) -> Conversation? {
        guard let selected = parts.first(where: { $0.summary.id == selectedID }) else {
            return nil
        }

        // Walk backwards so the active child's copy wins when a fork copied
        // messages into the new file.
        var seenTurnIDs = Set<String>()
        var kept: [(part: SessionChainPart, turns: [TurnGroup], omitted: Int)] = []
        for part in parts.reversed() {
            let filtered = part.conversation.turns.filter { turn in
                guard let cutoff = part.cutoffDate, let start = turnStart(turn) else {
                    return true
                }
                return start <= cutoff
            }
            let omittedTurnCount = max(0, part.conversation.turns.count - filtered.count)
            // A continuation file can start with metadata/system-only turns
            // before its first real user message. Do not put the chain divider
            // above those leftovers.
            let startIndex = filtered.firstIndex(where: { $0.user != nil }) ?? 0
            let visible = startIndex > 0 ? Array(filtered[startIndex...]) : filtered
            let unique = visible.filter { seenTurnIDs.insert($0.id).inserted }
            if !unique.isEmpty {
                kept.append((part: part, turns: unique, omitted: omittedTurnCount))
            }
        }
        kept.reverse()
        guard !kept.isEmpty else { return nil }
        let selectedIndex = kept.firstIndex(where: { $0.part.summary.id == selectedID }) ?? 0

        var turns: [TurnGroup] = []
        var items: [ConversationItem] = []
        var segments: [ConversationSegment] = []
        var segmentStarts: [String: ConversationSegment] = [:]
        var startedAt: Date?
        var endedAt: Date?

        for (index, item) in kept.enumerated() {
            let part = item.part
            let segmentTurns = item.turns
            let omittedTurnCount = item.omitted
            turns.append(contentsOf: segmentTurns)

            for turn in segmentTurns {
                if let user = turn.user { items.append(user) }
                items.append(contentsOf: turn.process)
                if let answer = turn.answer { items.append(answer) }
            }

            let firstTurn = segmentTurns.first
            let start = firstTurn.flatMap(turnStart)
                ?? part.conversation.startedAt
            let end = segmentTurns.compactMap(turnEnd).max()
                ?? part.conversation.endedAt
                ?? part.conversation.session.date

            if let start {
                startedAt = min(startedAt ?? start, start)
            }
            endedAt = max(endedAt ?? end, end)

            let summaryTitle = part.summary.displayTitle
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let parsedTitle = part.conversation.session.displayTitle
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let segmentTitle = summaryTitle.hasPrefix("http://") || summaryTitle.hasPrefix("https://")
                ? parsedTitle
                : summaryTitle

            let segment = ConversationSegment(
                id: part.summary.id,
                title: segmentTitle,
                sessionID: part.summary.id,
                startDate: start,
                endDate: end,
                turnCount: segmentTurns.count,
                omittedTurnCount: omittedTurnCount,
                isArchived: part.summary.isArchived,
                isCurrent: part.summary.id == selectedID,
                isPast: index < selectedIndex
            )
            segments.append(segment)
            if let firstTurn {
                segmentStarts[firstTurn.id] = segment
            }
        }

        guard !turns.isEmpty else { return nil }

        let branchCount = items.reduce(into: 0) { count, item in
            if case .branch = item { count += 1 }
        }
        let imageCount = items.reduce(into: 0) { count, item in
            if case .image = item { count += 1 }
        }

        var session = selected.summary
        session.turns = selected.summary.turns
        // The session index can pick up an early URL prompt before the parser
        // sees Claude Code's `ai-title` record. Prefer the parsed title from
        // the selected segment when it is more useful.
        if let selectedPart = parts.first(where: { $0.summary.id == selectedID }) {
            let parsedTitle = selectedPart.conversation.session.title
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !parsedTitle.isEmpty {
                session.title = parsedTitle
            }
        }

        return Conversation(
            session: session,
            items: items,
            turns: turns,
            branchCount: branchCount,
            imageCount: imageCount,
            eventCount: items.count,
            startedAt: startedAt,
            endedAt: endedAt,
            segments: segments,
            segmentStarts: segmentStarts,
            chainIDs: parts.map(\.summary.id)
        )
    }

    static func turnStart(_ turn: TurnGroup) -> Date? {
        if let user = turn.user, let date = timestamp(of: user) {
            return date
        }
        if let date = turn.process.compactMap({ timestamp(of: $0) }).first {
            return date
        }
        return timestamp(of: turn.answer)
    }

    static func turnEnd(_ turn: TurnGroup) -> Date? {
        var dates: [Date] = []
        if let date = timestamp(of: turn.user) { dates.append(date) }
        dates.append(contentsOf: turn.process.compactMap { timestamp(of: $0) })
        if let date = timestamp(of: turn.answer) { dates.append(date) }
        return dates.max()
    }

    private static func timestamp(of item: ConversationItem?) -> Date? {
        guard let item else { return nil }
        switch item {
        case .user(_, _, let timestamp): return timestamp
        case .assistant(_, _, _, let timestamp): return timestamp
        case .tool(_, _, let timestamp): return timestamp
        default: return nil
        }
    }
}
