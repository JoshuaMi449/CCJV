import Foundation
import Combine
import SwiftUI

struct SessionSummary: Identifiable, Hashable {
    let id: String
    var title: String
    var project: String
    var preview: String
    var date: Date
    var turns: Int
    var fileURL: URL
    var subagentCount: Int
    var fileSize: Int64
    var isArchived: Bool = false
    var customTitle: String? = nil

    var displayTitle: String {
        if let customTitle {
            let trimmed = customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return title
    }
}

enum ToolStatus {
    case running
    case ok
    case error

    var label: String {
        switch self {
        case .running: return "运行中"
        case .ok: return "完成"
        case .error: return "失败"
        }
    }
}

struct ImageRef: Identifiable {
    let id: String
    let mediaType: String
    let base64: String
}

struct ToolFact: Identifiable {
    let id = UUID()
    let label: String
    let value: String
}

struct ToolInfo {
    var name: String
    var summary: String
    var detail: String
    var status: ToolStatus
    var command: String?
    var path: String?
    var diff: String?
    var facts: [ToolFact]
}

final class BranchNode: ObservableObject, Identifiable {
    let id: String
    let parentId: String?
    let toolUseId: String
    let agentType: String
    let title: String
    let prompt: String
    let fileURL: URL?
    @Published var status: String

    @Published var items: [ConversationItem] = []
    @Published var report: String?
    @Published var isLoaded = false
    @Published var isLoading = false
    @Published var loadError: String?
    @Published var steps = 0
    @Published var duration: TimeInterval = 0
    var isArchived = false

    init(
        id: String,
        parentId: String?,
        toolUseId: String,
        agentType: String,
        title: String,
        prompt: String,
        fileURL: URL?,
        status: String
    ) {
        self.id = id
        self.parentId = parentId
        self.toolUseId = toolUseId
        self.agentType = agentType
        self.title = title
        self.prompt = prompt
        self.fileURL = fileURL
        self.status = status
    }
}

enum ConversationItem: Identifiable {
    case user(id: String, text: String, timestamp: Date?)
    case assistant(id: String, text: String, model: String, timestamp: Date?)
    case tool(id: String, info: ToolInfo, timestamp: Date?)
    case branch(id: String, node: BranchNode)
    case compaction(id: String, pre: Int, post: Int)
    case image(id: String, ref: ImageRef)
    case system(id: String, text: String)

    var id: String {
        switch self {
        case .user(let id, _, _): return "u-\(id)"
        case .assistant(let id, _, _, _): return "a-\(id)"
        case .tool(let id, _, _): return "t-\(id)"
        case .branch(let id, _): return "b-\(id)"
        case .compaction(let id, _, _): return "c-\(id)"
        case .image(let id, _): return "i-\(id)"
        case .system(let id, _): return "s-\(id)"
        }
    }
}

struct TurnGroup: Identifiable {
    let id: String
    let user: ConversationItem?
    let process: [ConversationItem]
    let answer: ConversationItem?

    var branchCount: Int {
        process.reduce(into: 0) { count, item in
            if case .branch = item { count += 1 }
        }
    }

    var imageCount: Int {
        process.reduce(into: 0) { count, item in
            if case .image = item { count += 1 }
        }
    }

    var interimReplyCount: Int {
        process.reduce(into: 0) { count, item in
            if case .assistant = item { count += 1 }
        }
    }

    var branches: [BranchNode] {
        process.compactMap { item in
            if case .branch(_, let node) = item { return node }
            return nil
        }
    }

    var isRunning: Bool {
        branches.contains { $0.status == "已启动" || $0.status == "运行中" }
    }
}

enum ReadingMode: Equatable {
    /// The default chain reading view. A single segment is shown when there is
    /// no strong chain.
    case merged
    /// One raw session file on its own, including turns after a fork point.
    case segment
}

struct ConversationSegment: Identifiable {
    let id: String
    let title: String
    let sessionID: String
    let startDate: Date?
    let endDate: Date?
    let turnCount: Int
    /// Turns in the raw segment that start after the next segment's fork point
    /// and therefore are not part of this linear chain.
    let omittedTurnCount: Int
    let isArchived: Bool
    let isCurrent: Bool
    let isPast: Bool

    var roleLabel: String {
        if isCurrent { return "本段" }
        return isPast ? "前段" : "后续段"
    }
}

struct Conversation {
    var session: SessionSummary
    var items: [ConversationItem]
    var turns: [TurnGroup]
    var branchCount: Int
    var imageCount: Int
    var eventCount: Int
    var startedAt: Date?
    var endedAt: Date? = nil
    var segments: [ConversationSegment] = []
    /// Maps the first turn of a segment to that segment, so the transcript can
    /// put a chain divider exactly at the seam.
    var segmentStarts: [String: ConversationSegment] = [:]
    /// The full logical chain, including segments whose turns were all duplicates.
    var chainIDs: [String] = []
}

struct ImageFocus: Equatable {
    let id = UUID()
    let sessionID: String
    let itemID: String
}

struct TurnFocus: Equatable {
    let id = UUID()
    let sessionID: String
    let turnID: String
}

extension Conversation {
    var images: [ImageRef] {
        items.compactMap { item in
            if case .image(_, let ref) = item { return ref }
            return nil
        }
    }

    func contains(turnID: String, itemID: String) -> Bool {
        turns.contains { $0.id == turnID } || items.contains { $0.id == itemID }
    }

    static func groupTurns(_ items: [ConversationItem]) -> [TurnGroup] {
        struct Builder {
            var user: ConversationItem?
            var items: [ConversationItem] = []
        }

        var builders: [Builder] = []

        for item in items {
            if case .user = item {
                builders.append(Builder(user: item))
            } else {
                if builders.isEmpty {
                    builders.append(Builder(user: nil))
                }
                builders[builders.count - 1].items.append(item)
            }
        }

        func assistantText(_ item: ConversationItem) -> String? {
            if case .assistant(_, let text, _, _) = item {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }

        return builders.enumerated().map { index, builder in
            var process = builder.items
            var answer: ConversationItem?

            let assistants = builder.items.enumerated().filter { _, item in
                if case .assistant = item { return true }
                return false
            }

            let notifications = builder.items.indices.filter { index in
                if case .system = builder.items[index] { return true }
                return false
            }
            let answerBeforeNotification = notifications.reversed().compactMap { notification -> (offset: Int, element: ConversationItem)? in
                guard assistants.contains(where: { $0.offset > notification }) else { return nil }
                guard let candidate = assistants.last(where: {
                    $0.offset < notification
                        && AnswerSelection.isSubstantive(assistantText($0.element) ?? "")
                }) else { return nil }
                return candidate
            }.first
            let notificationFollowUp = assistants.last.flatMap { assistantText($0.element) }

            if let earlier = answerBeforeNotification,
               let followUp = notificationFollowUp,
               AnswerSelection.isNotificationFollowUp(followUp) {
                // A short background-notification reply must not replace the
                // substantive answer to the human question.
                answer = earlier.element
                process.removeAll { $0.id == earlier.element.id }
            } else if let last = assistants.last {
                let lastText = assistantText(last.element)
                let earlierSubstantial = assistants.dropLast().last { _, item in
                    (assistantText(item)?.count ?? 0) >= 40
                }

                if (lastText?.count ?? 0) < 16, let earlierSubstantial {
                    answer = earlierSubstantial.element
                    process.removeAll { $0.id == earlierSubstantial.element.id }
                } else {
                    answer = last.element
                    process.removeAll { $0.id == last.element.id }
                }
            }

            let id = builder.user?.id ?? "turn-\(index)"
            return TurnGroup(
                id: id,
                user: builder.user,
                process: process,
                answer: answer
            )
        }
    }
}

extension Date {
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M 月 d 日 · EEEE"
        return f
    }()

    private static let shortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M 月 d 日"
        return f
    }()

    var timeLabel: String { Self.timeFormatter.string(from: self) }
    var dayLabel: String { Self.dayFormatter.string(from: self) }
    var shortDateLabel: String { Self.shortFormatter.string(from: self) }

    var relativeDayLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return "今天 \(timeLabel)" }
        if cal.isDateInYesterday(self) { return "昨天" }
        return shortDateLabel
    }
}
