import Foundation

struct ContentSearchEntry: Identifiable {
    enum Role: String {
        case user
        case assistant

        var label: String {
            switch self {
            case .user: return "你"
            case .assistant: return "Claude"
            }
        }
    }

    let id: String
    let sessionID: String
    let turnID: String
    let messageID: String
    let role: Role
    let text: String
    let timestamp: Date?
}

struct ContentSearchHit: Identifiable {
    let entry: ContentSearchEntry
    let before: String
    let matched: String
    let after: String
    let matchCount: Int

    var id: String { entry.id }
}

struct ContentSearchResult {
    let hits: [ContentSearchHit]
    let total: Int
}

struct ContentSearchSessionResult: Identifiable {
    /// The chain root, not necessarily the segment that produced every hit.
    let sessionID: String
    /// All strong-linked segments in this logical family, for display.
    let chainIDs: [String]
    let hits: [ContentSearchHit]

    var id: String { sessionID }
    var count: Int { hits.count }
    var latest: ContentSearchHit? { hits.first }
}

struct SearchFocus: Equatable {
    let id = UUID()
    let sessionID: String
    let turnID: String
    let itemID: String
}

enum ContentSearchIndexer {
    private struct AssistantChunk {
        let id: String
        var text: String
        let timestamp: Date?
    }

    private struct TurnDraft {
        let userID: String
        let userText: String
        let userTimestamp: Date?
        var assistants: [AssistantChunk] = []
    }

    static func build(sessions: [SessionSummary]) -> [ContentSearchEntry] {
        var allEntries: [ContentSearchEntry] = []
        for session in sessions {
            allEntries.append(contentsOf: entries(for: session))
        }
        return allEntries
    }

    private static func entries(for session: SessionSummary) -> [ContentSearchEntry] {
        var result: [ContentSearchEntry] = []
        var current: TurnDraft?
        var seenUsers = Set<String>()
        var seenAssistants = Set<String>()

        func flush() {
            guard let turn = current else { return }
            current = nil

            if !seenUsers.contains(turn.userID) {
                seenUsers.insert(turn.userID)
                result.append(ContentSearchEntry(
                    id: "\(session.id)-u-\(turn.userID)",
                    sessionID: session.id,
                    turnID: "u-\(turn.userID)",
                    messageID: "u-\(turn.userID)",
                    role: .user,
                    text: turn.userText,
                    timestamp: turn.userTimestamp
                ))
            }

            guard let answer = chooseAnswer(turn.assistants),
                  !seenAssistants.contains(answer.id) else { return }
            seenAssistants.insert(answer.id)
            result.append(ContentSearchEntry(
                id: "\(session.id)-a-\(answer.id)",
                sessionID: session.id,
                turnID: "u-\(turn.userID)",
                messageID: "a-\(answer.id)",
                role: .assistant,
                text: answer.text,
                timestamp: answer.timestamp ?? turn.userTimestamp
            ))
        }

        guard let reader = try? LineReader(url: session.fileURL) else { return result }
        reader.forEachLine { line in
            guard let object = JSONL.object(line),
                  let type = object["type"] as? String else { return true }

            if type == "user" {
                if let origin = object["origin"] as? [String: Any],
                   (origin["kind"] as? String) == "task-notification" {
                    return true
                }
                guard let message = object["message"] as? [String: Any],
                      JSONL.isHuman(object) else { return true }

                let raw = humanText(message)
                guard !raw.isEmpty, !JSONL.isCommandWrapper(raw) else { return true }
                let cleaned = JSONL.cleanUserText(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty, !isNoise(cleaned) else { return true }

                flush()
                current = TurnDraft(
                    userID: object["uuid"] as? String ?? UUID().uuidString,
                    userText: cleaned,
                    userTimestamp: JSONL.date(object["timestamp"])
                )
            } else if type == "assistant" {
                guard var turn = current,
                      let message = object["message"] as? [String: Any],
                      let messageID = message["id"] as? String,
                      let text = assistantText(message) else { return true }

                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { return true }

                if let index = turn.assistants.firstIndex(where: { $0.id == messageID }) {
                    let separator = turn.assistants[index].text.hasSuffix("\n") ? "" : "\n\n"
                    turn.assistants[index].text += separator + cleaned
                } else {
                    turn.assistants.append(AssistantChunk(
                        id: messageID,
                        text: cleaned,
                        timestamp: JSONL.date(object["timestamp"])
                    ))
                }
                current = turn
            }
            return true
        }

        flush()
        return result
    }

    private static func humanText(_ message: [String: Any]) -> String {
        if let blocks = message["content"] as? [[String: Any]] {
            return blocks.compactMap { block -> String? in
                guard (block["type"] as? String) == "text" else { return nil }
                return block["text"] as? String
            }.joined(separator: "\n")
        }
        return (message["content"] as? String) ?? ""
    }

    private static func assistantText(_ message: [String: Any]) -> String? {
        guard let blocks = message["content"] as? [[String: Any]] else { return nil }
        let text = blocks.compactMap { block -> String? in
            guard (block["type"] as? String) == "text" else { return nil }
            return block["text"] as? String
        }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    private static func chooseAnswer(_ chunks: [AssistantChunk]) -> AssistantChunk? {
        guard let last = chunks.last else { return nil }
        let lastText = last.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if lastText.count < 16,
           let earlier = chunks.dropLast().last(where: {
               $0.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 40
           }) {
            return earlier
        }
        return last
    }

    private static func isNoise(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("[Request interrupted by user")
    }
}

enum ContentSearchMatcher {
    static func search(_ query: String, in entries: [ContentSearchEntry]) -> ContentSearchResult {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return ContentSearchResult(hits: [], total: 0) }

        var hits: [ContentSearchHit] = []
        for entry in entries {
            guard entry.text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil else { continue }
            hits.append(makeHit(entry: entry, query: q))
        }

        hits.sort { lhs, rhs in
            let l = lhs.entry.timestamp ?? .distantPast
            let r = rhs.entry.timestamp ?? .distantPast
            if l != r { return l > r }
            return lhs.entry.id < rhs.entry.id
        }

        return ContentSearchResult(hits: hits, total: hits.count)
    }

    private static func makeHit(entry: ContentSearchEntry, query: String) -> ContentSearchHit {
        let flattened = entry.text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")

        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var matchCount = 0
        var firstRange: Range<String.Index>?
        var searchStart = flattened.startIndex

        while searchStart < flattened.endIndex,
              let range = flattened.range(of: query, options: options, range: searchStart..<flattened.endIndex) {
            matchCount += 1
            if firstRange == nil { firstRange = range }
            if range.isEmpty { break }
            searchStart = range.upperBound
        }

        guard let first = firstRange else {
            return ContentSearchHit(
                entry: entry,
                before: "",
                matched: "",
                after: String(flattened.prefix(80)),
                matchCount: 0
            )
        }

        let beforeStart = flattened.index(first.lowerBound, offsetBy: -34, limitedBy: flattened.startIndex)
            ?? flattened.startIndex
        let afterEnd = flattened.index(first.upperBound, offsetBy: 54, limitedBy: flattened.endIndex)
            ?? flattened.endIndex

        var before = String(flattened[beforeStart..<first.lowerBound])
        var after = String(flattened[first.upperBound..<afterEnd])

        if beforeStart > flattened.startIndex {
            if let space = before.firstIndex(of: " ") {
                before = String(before[before.index(after: space)...])
            }
            before = "…" + plainSnippet(before)
        } else {
            before = plainSnippet(before)
        }
        if afterEnd < flattened.endIndex {
            if let space = after.lastIndex(of: " ") {
                after = String(after[..<space])
            }
            after = plainSnippet(after) + "…"
        } else {
            after = plainSnippet(after)
        }

        return ContentSearchHit(
            entry: entry,
            before: before,
            matched: String(flattened[first]),
            after: after,
            matchCount: matchCount
        )
    }

    private static func plainSnippet(_ text: String) -> String {
        text
            .replacingOccurrences(of: "```", with: " ")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "##", with: "")
            .replacingOccurrences(of: "  ", with: " ")
    }
}
