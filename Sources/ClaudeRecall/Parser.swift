import Foundation

// MARK: - Low-level helpers

final class LineReader {
    private let handle: FileHandle
    private var buffer = Data()
    private let chunkSize = 1 << 20

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
    }

    deinit {
        try? handle.close()
    }

    @discardableResult
    func forEachLine(_ body: (Data) -> Bool) -> Bool {
        let newline = Data([0x0A])
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: chunkSize)
            } catch {
                return false
            }
            guard let chunk, !chunk.isEmpty else { break }
            buffer.append(chunk)

            while let range = buffer.range(of: newline) {
                let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex...range.lowerBound)
                guard !lineData.isEmpty else { continue }
                if !body(lineData) { return false }
            }
        }

        if !buffer.isEmpty {
            let lineData = buffer
            buffer = Data()
            return body(lineData)
        }
        return true
    }
}

enum JSONL {
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return isoFractional.date(from: string) ?? isoPlain.date(from: string)
    }

    static func isHuman(_ object: [String: Any]) -> Bool {
        if object["isCompactSummary"] as? Bool == true { return false }
        // Skill/harness injections carry the full injected prompt as a user
        // record. They are not questions typed by the person.
        if object["isMeta"] as? Bool == true { return false }
        if let origin = object["origin"] as? [String: Any],
           let kind = origin["kind"] as? String {
            return kind == "human"
        }
        if let source = object["promptSource"] as? String {
            return ["typed", "queued", "suggestion_accepted"].contains(source)
        }
        return true
    }

    static func isCommandWrapper(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            "<command-name>", "<command-message>", "<command-args>",
            "<local-command-caveat>", "<local-command-stdout>", "<local-command-stderr>",
            "<bash-input>", "<bash-stdout>", "<bash-stderr>",
            "<system-reminder>", "<task-notification>",
            "<user-prompt-submit-hook>", "<ide_opened_file>"
        ]
        return prefixes.contains { trimmed.hasPrefix($0) }
    }

    static func cleanUserText(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("[Image")
                    && !trimmed.hasPrefix("<system-reminder>")
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func messageText(_ message: [String: Any]) -> String? {
        if let text = message["content"] as? String {
            return text
        }
        if let blocks = message["content"] as? [[String: Any]] {
            let texts = blocks.compactMap { block -> String? in
                guard (block["type"] as? String) == "text" else { return nil }
                return block["text"] as? String
            }
            let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    static func textContent(_ content: Any?) -> String {
        if let text = content as? String { return text }
        if let blocks = content as? [[String: Any]] {
            let texts = blocks.compactMap { block -> String? in
                guard (block["type"] as? String) == "text" else { return nil }
                return block["text"] as? String
            }
            return texts.joined(separator: "\n")
        }
        return ""
    }
}

enum ToolFormat {
    static func basename(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    static func path(input: [String: Any]) -> String? {
        (input["file_path"] as? String) ?? (input["path"] as? String)
    }

    static func inputFacts(name: String, input: [String: Any]) -> [ToolFact] {
        var facts: [ToolFact] = []
        if let path = path(input: input) {
            facts.append(ToolFact(label: "文件", value: path))
        }

        switch name {
        case "Read":
            if let offset = input["offset"] as? Int, let limit = input["limit"] as? Int {
                facts.append(ToolFact(label: "范围", value: "\(offset)–\(offset + limit)"))
            }
        case "Bash":
            if let command = input["command"] as? String {
                facts.append(ToolFact(label: "命令", value: command))
            }
        case "Grep":
            if let pattern = input["pattern"] as? String {
                facts.append(ToolFact(label: "模式", value: pattern))
            }
        case "Glob":
            if let pattern = input["pattern"] as? String {
                facts.append(ToolFact(label: "模式", value: pattern))
            }
        case "Agent", "Task":
            if let description = input["description"] as? String {
                facts.append(ToolFact(label: "子代理", value: description))
            }
            if let type = input["subagent_type"] as? String {
                facts.append(ToolFact(label: "类型", value: type))
            }
        default:
            break
        }
        return facts
    }

    static func resultFacts(
        name: String,
        content: Any?,
        toolUseResult: [String: Any]?
    ) -> [ToolFact] {
        var facts: [ToolFact] = []

        if name == "Edit" || name == "Write" || name == "MultiEdit" {
            if let patch = toolUseResult?["structuredPatch"] as? [[String: Any]] {
                var added = 0
                var deleted = 0
                for hunk in patch {
                    guard let lines = hunk["lines"] as? [String] else { continue }
                    for line in lines {
                        if line.hasPrefix("+") && !line.hasPrefix("+++") { added += 1 }
                        if line.hasPrefix("-") && !line.hasPrefix("---") { deleted += 1 }
                    }
                }
                if added + deleted > 0 {
                    facts.append(ToolFact(label: "变更", value: "+\(added) −\(deleted)"))
                }
                if !patch.isEmpty {
                    facts.append(ToolFact(label: "修改块", value: "\(patch.count)"))
                }
            }
            return facts
        }

        if name == "Read" {
            if let file = toolUseResult?["file"] as? [String: Any],
               let lines = file["numLines"] as? Int {
                let start = file["startLine"] as? Int ?? 0
                facts.append(ToolFact(label: "行数", value: "\(lines) 行（\(start)–\(start + lines)）"))
            }
            return facts
        }

        if name == "Bash" {
            if let exit = toolUseResult?["exitCode"] as? Int {
                facts.append(ToolFact(label: "退出码", value: "\(exit)"))
            }
            if let stderr = toolUseResult?["stderr"] as? String, !stderr.isEmpty {
                facts.append(ToolFact(label: "stderr", value: String(stderr.prefix(1200))))
            }
            if let stdout = toolUseResult?["stdout"] as? String, !stdout.isEmpty {
                let lines = stdout.split(separator: "\n", omittingEmptySubsequences: false)
                let preview = lines.prefix(10).joined(separator: "\n")
                facts.append(ToolFact(label: "输出", value: String(preview.prefix(1200))))
            }
            if facts.isEmpty {
                let text = JSONL.textContent(content)
                if !text.isEmpty {
                    facts.append(ToolFact(label: "结果", value: String(text.prefix(800))))
                }
            }
            return facts
        }

        if name == "Agent" || name == "Task" {
            let text = JSONL.textContent(content)
            if let first = text.split(separator: "\n").first {
                facts.append(ToolFact(label: "状态", value: String(first.prefix(160))))
            }
            return facts
        }

        let text = JSONL.textContent(content)
        if !text.isEmpty {
            facts.append(ToolFact(label: "结果", value: String(text.prefix(800))))
        }
        return facts
    }

    static func diff(from toolUseResult: [String: Any]?) -> String? {
        guard let patches = toolUseResult?["structuredPatch"] as? [[String: Any]],
              !patches.isEmpty else { return nil }

        var lines: [String] = []
        for hunk in patches {
            let oldStart = hunk["oldStart"] as? Int ?? 0
            let newStart = hunk["newStart"] as? Int ?? 0
            lines.append("@@ -\(oldStart) +\(newStart) @@")
            if let body = hunk["lines"] as? [String] {
                lines.append(contentsOf: body)
            }
            if lines.count > 320 { break }
        }
        return Array(lines.prefix(320)).joined(separator: "\n")
    }

    static func questionPrompts(input: [String: Any]) -> [QuestionPrompt] {
        guard let questions = input["questions"] as? [[String: Any]] else { return [] }
        return questions.enumerated().map { index, raw in
            let options = (raw["options"] as? [[String: Any]] ?? []).enumerated().map { offset, option in
                QuestionOption(
                    id: "\(index)-\(offset)",
                    label: option["label"] as? String ?? "",
                    description: option["description"] as? String ?? "",
                    preview: option["preview"] as? String
                )
            }
            return QuestionPrompt(
                id: String(index),
                question: raw["question"] as? String ?? "",
                header: raw["header"] as? String ?? "",
                multiSelect: raw["multiSelect"] as? Bool ?? false,
                options: options
            )
        }
    }

    static func questionAnswers(toolUseResult: [String: Any]?) -> [String: QuestionAnswer] {
        guard let result = toolUseResult,
              let rawAnswers = result["answers"] as? [String: String] else { return [:] }
        let annotations = result["annotations"] as? [String: Any] ?? [:]
        return rawAnswers.reduce(into: [:]) { answers, pair in
            let annotation = annotations[pair.key] as? [String: Any]
            answers[pair.key] = QuestionAnswer(
                choice: pair.value,
                notes: annotation?["notes"] as? String
            )
        }
    }

    static func inputSummary(name: String, input: [String: Any]) -> String {
        let path = (input["file_path"] as? String) ?? (input["path"] as? String)
        switch name {
        case "Edit", "Write", "MultiEdit":
            return "编辑 \(path.map(basename) ?? "文件")"
        case "Read":
            var summary = "Read \(path.map(basename) ?? "文件")"
            if let offset = input["offset"] as? Int, let limit = input["limit"] as? Int {
                summary += " · \(offset)–\(offset + limit)"
            }
            return summary
        case "Bash":
            let command = (input["command"] as? String ?? "").split(separator: "\n").first.map(String.init) ?? "命令"
            return command.count > 44 ? String(command.prefix(44)) + "…" : command
        case "Grep":
            return "Grep \(input["pattern"] as? String ?? "…")"
        case "Glob":
            return "Glob \(input["pattern"] as? String ?? "…")"
        case "Agent", "Task":
            return "子代理 · \(input["description"] as? String ?? "委派任务")"
        case "WebFetch":
            return "抓取 \(URL(string: input["url"] as? String ?? "")?.host ?? "网页")"
        case "WebSearch":
            return "搜索 \(input["query"] as? String ?? "…")"
        case "TodoWrite":
            return "更新任务清单"
        case "AskUserQuestion":
            let prompts = questionPrompts(input: input)
            if let first = prompts.first, !first.header.isEmpty {
                return prompts.count > 1 ? "\(first.header) 等 \(prompts.count) 个问题" : first.header
            }
            return "向你提问"
        default:
            return name
        }
    }

    static func resultDetail(name: String, content: Any?, toolUseResult: [String: Any]?) -> String {
        if name == "AskUserQuestion" {
            return questionAnswers(toolUseResult: toolUseResult).isEmpty ? "等待回答" : "已回答"
        }

        if name == "Edit" || name == "Write" || name == "MultiEdit" {
            if let patch = toolUseResult?["structuredPatch"] as? [[String: Any]] {
                var added = 0
                var deleted = 0
                for hunk in patch {
                    guard let lines = hunk["lines"] as? [String] else { continue }
                    for line in lines {
                        if line.hasPrefix("+") && !line.hasPrefix("+++") { added += 1 }
                        if line.hasPrefix("-") && !line.hasPrefix("---") { deleted += 1 }
                    }
                }
                if added + deleted > 0 {
                    return "+\(added) −\(deleted) · 已应用"
                }
            }
            return "已应用"
        }

        if name == "Read" {
            if let file = toolUseResult?["file"] as? [String: Any] {
                let lines = file["numLines"] as? Int ?? 0
                let start = file["startLine"] as? Int ?? 0
                if lines > 0 { return "\(start)–\(start + lines) 行" }
            }
            return "已读取"
        }

        if name == "Bash" {
            if toolUseResult?["interrupted"] as? Bool == true { return "已中断" }
            if let stderr = toolUseResult?["stderr"] as? String, !stderr.isEmpty {
                let first = stderr.split(separator: "\n").first.map(String.init) ?? stderr
                return "stderr · \(first.prefix(70))"
            }
            if let exit = toolUseResult?["exitCode"] as? Int {
                return "exit \(exit)"
            }
            return "完成"
        }

        if name == "Agent" || name == "Task" {
            return "子代理已启动"
        }

        let text = JSONL.textContent(content)
        let first = text.split(separator: "\n").first.map(String.init) ?? text
        return first.isEmpty ? "完成" : String(first.prefix(90))
    }

    static func tag(_ name: String, in text: String) -> String? {
        let open = "<\(name)>"
        let close = "</\(name)>"
        guard let start = text.range(of: open),
              let end = text.range(of: close, range: start.upperBound..<text.endIndex) else {
            return nil
        }
        let value = text[start.upperBound..<end.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func agentId(from toolUseResult: [String: Any]?, content: Any?) -> String? {
        if let id = toolUseResult?["agentId"] as? String, !id.isEmpty { return id }
        let text = JSONL.textContent(content)
        let pattern = #"agentId:\s*([a-f0-9]{8,})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }
}

// MARK: - Session parser

final class SessionParser {
    private let url: URL
    private let sessionDir: URL
    private let subagentsDir: URL
    private var summary: SessionSummary

    private var items: [ConversationItem] = []
    private var toolIndices: [String: Int] = [:]
    private var assistantIndices: [String: Int] = [:]
    private var pendingAgents: [String: (name: String, input: [String: Any])] = [:]

    private var humanCount = 0
    private var branchCount = 0
    private var imageCount = 0
    private var eventCount = 0
    private var firstTimestamp: Date?

    init(url: URL, summary: SessionSummary) {
        self.url = url
        self.summary = summary
        self.sessionDir = url.deletingPathExtension()
        self.subagentsDir = sessionDir.appendingPathComponent("subagents")
    }

    func parse() -> Conversation {
        if let reader = try? LineReader(url: url) {
            reader.forEachLine { line in
                guard let object = JSONL.object(line) else { return true }
                eventCount += 1
                handle(object)
                return true
            }
        }

        if summary.title.isEmpty {
            if let firstUser = items.first(where: {
                if case .user = $0 { return true }
                return false
            }), case .user(_, let text, _) = firstUser {
                summary.title = String(text.prefix(28))
            } else {
                summary.title = "未命名会话"
            }
        }

        summary.turns = humanCount

        return Conversation(
            session: summary,
            items: items,
            turns: Conversation.groupTurns(items),
            branchCount: branchCount,
            imageCount: imageCount,
            eventCount: eventCount,
            startedAt: firstTimestamp
        )
    }

    private func handle(_ object: [String: Any]) {
        guard let type = object["type"] as? String else { return }
        switch type {
        case "user":
            handleUser(object)
        case "assistant":
            handleAssistant(object)
        case "system":
            handleSystem(object)
        case "ai-title":
            if let title = object["aiTitle"] as? String, !title.isEmpty {
                summary.title = title
            }
        default:
            break
        }
    }

    private func handleUser(_ object: [String: Any]) {
        if let origin = object["origin"] as? [String: Any],
           (origin["kind"] as? String) == "task-notification" {
            updateTaskNotification(object)
            return
        }

        guard let message = object["message"] as? [String: Any] else { return }

        if let blocks = message["content"] as? [[String: Any]] {
            for block in blocks {
                switch block["type"] as? String {
                case "tool_result":
                    handleToolResult(object, block)
                case "image":
                    appendImage(block)
                default:
                    break
                }
            }

            guard JSONL.isHuman(object) else { return }
            let texts = blocks.compactMap { block -> String? in
                guard (block["type"] as? String) == "text" else { return nil }
                return block["text"] as? String
            }
            let text = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty && !JSONL.isCommandWrapper(text) {
                appendUser(text, object)
            }
            return
        }

        if let text = message["content"] as? String {
            if object["isCompactSummary"] as? Bool == true { return }
            guard JSONL.isHuman(object), !JSONL.isCommandWrapper(text) else { return }
            appendUser(text, object)
        }
    }

    private func updateTaskNotification(_ object: [String: Any]) {
        guard let message = object["message"] as? [String: Any] else { return }
        let text = JSONL.messageText(message) ?? ""
        let reportTitle: String = {
            guard let start = text.range(of: "<summary>"),
                  let end = text.range(of: "</summary>", range: start.upperBound..<text.endIndex) else {
                return "后台任务通知"
            }
            let summary = text[start.upperBound..<end.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return summary.isEmpty ? "后台任务通知" : "后台任务通知 · \(summary)"
        }()
        items.append(.system(
            id: object["uuid"] as? String ?? UUID().uuidString,
            text: reportTitle
        ))

        let taskID = ToolFormat.tag("task-id", in: text)
        let toolUseID = ToolFormat.tag("tool-use-id", in: text)
        let status = ToolFormat.tag("status", in: text)
        let agentId = ToolFormat.agentId(from: nil, content: text)
        for item in items {
            guard case .branch(_, let node) = item else { continue }
            guard node.id == agentId
                || node.id == taskID
                || node.toolUseId == toolUseID else { continue }
            node.status = status == "failed" ? "失败" : "已完成"
        }
    }

    private func appendUser(_ text: String, _ object: [String: Any]) {
        let cleaned = JSONL.cleanUserText(text)
        guard !cleaned.isEmpty else { return }
        let timestamp = JSONL.date(object["timestamp"])
        firstTimestamp = firstTimestamp ?? timestamp
        items.append(.user(
            id: object["uuid"] as? String ?? UUID().uuidString,
            text: cleaned,
            timestamp: timestamp
        ))
        humanCount += 1
    }

    private func handleAssistant(_ object: [String: Any]) {
        guard let message = object["message"] as? [String: Any],
              let messageId = message["id"] as? String else { return }
        let model = message["model"] as? String ?? ""
        let timestamp = JSONL.date(object["timestamp"])
        firstTimestamp = firstTimestamp ?? timestamp

        guard let blocks = message["content"] as? [[String: Any]] else { return }
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                guard let text = block["text"] as? String, !text.isEmpty else { continue }
                if let index = assistantIndices[messageId], index < items.count,
                   case .assistant(let id, let oldText, let oldModel, let oldTimestamp) = items[index] {
                    let separator = oldText.hasSuffix("\n") ? "" : "\n\n"
                    items[index] = .assistant(
                        id: id,
                        text: oldText + separator + text,
                        model: oldModel,
                        timestamp: oldTimestamp
                    )
                } else {
                    items.append(.assistant(id: messageId, text: text, model: model, timestamp: timestamp))
                    assistantIndices[messageId] = items.count - 1
                }

            case "tool_use":
                let toolId = block["id"] as? String ?? UUID().uuidString
                let name = block["name"] as? String ?? "Tool"
                let input = block["input"] as? [String: Any] ?? [:]
                let summary = ToolFormat.inputSummary(name: name, input: input)
                let info = ToolInfo(
                    name: name,
                    summary: summary,
                    detail: "运行中…",
                    status: .running,
                    command: input["command"] as? String,
                    path: ToolFormat.path(input: input),
                    diff: nil,
                    facts: ToolFormat.inputFacts(name: name, input: input),
                    prompts: name == "AskUserQuestion" ? ToolFormat.questionPrompts(input: input) : []
                )
                items.append(.tool(id: toolId, info: info, timestamp: timestamp))
                toolIndices[toolId] = items.count - 1
                if name == "Agent" || name == "Task" {
                    pendingAgents[toolId] = (name, input)
                }

            case "image":
                appendImage(block)

            default:
                break
            }
        }
    }

    private func handleToolResult(_ object: [String: Any], _ block: [String: Any]) {
        guard let toolId = block["tool_use_id"] as? String,
              let index = toolIndices[toolId], index < items.count,
              case .tool(let id, let info, let timestamp) = items[index] else {
            return
        }

        let isError = block["is_error"] as? Bool ?? false
        let toolUseResult = object["toolUseResult"] as? [String: Any]
        let detail = ToolFormat.resultDetail(
            name: info.name,
            content: block["content"],
            toolUseResult: toolUseResult
        )

        var updated = info
        updated.detail = detail
        updated.status = isError ? .error : .ok
        updated.diff = ToolFormat.diff(from: toolUseResult)
        updated.facts = info.facts + ToolFormat.resultFacts(
            name: info.name,
            content: block["content"],
            toolUseResult: toolUseResult
        )
        if info.name == "AskUserQuestion" {
            updated.answers = ToolFormat.questionAnswers(toolUseResult: toolUseResult)
        }
        items[index] = .tool(id: id, info: updated, timestamp: timestamp)

        if let pending = pendingAgents.removeValue(forKey: toolId) {
            attachBranch(
                toolUseId: toolId,
                input: pending.input,
                resultContent: block["content"],
                toolUseResult: toolUseResult,
                timestamp: timestamp,
                isError: isError
            )
        }
    }

    private func attachBranch(
        toolUseId: String,
        input: [String: Any],
        resultContent: Any?,
        toolUseResult: [String: Any]?,
        timestamp: Date?,
        isError: Bool
    ) {
        guard let agentId = ToolFormat.agentId(from: toolUseResult, content: resultContent) else { return }

        let metaURL = subagentsDir.appendingPathComponent("agent-\(agentId).meta.json")
        var agentType = input["subagent_type"] as? String ?? "Agent"
        var title = input["description"] as? String ?? "子代理"
        var prompt = input["prompt"] as? String ?? ""

        if let data = try? Data(contentsOf: metaURL),
           let meta = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            agentType = meta["agentType"] as? String ?? agentType
            title = meta["description"] as? String ?? title
        }

        let branchURL = subagentsDir.appendingPathComponent("agent-\(agentId).jsonl")
        let exists = FileManager.default.fileExists(atPath: branchURL.path)
        if prompt.isEmpty, exists, let reader = try? LineReader(url: branchURL) {
            reader.forEachLine { line in
                guard let object = JSONL.object(line),
                      (object["type"] as? String) == "user",
                      let message = object["message"] as? [String: Any],
                      let text = JSONL.messageText(message) else { return true }
                prompt = text
                return false
            }
        }

        let async = JSONL.textContent(resultContent).contains("Async agent launched")
        let status = isError ? "失败" : (async ? "已启动" : "已完成")

        let node = BranchNode(
            id: agentId,
            parentId: nil,
            toolUseId: toolUseId,
            agentType: agentType,
            title: title,
            prompt: prompt,
            fileURL: exists ? branchURL : nil,
            status: status
        )

        items.append(.branch(id: agentId, node: node))
        branchCount += 1
    }

    private func appendImage(_ block: [String: Any]) {
        guard let source = block["source"] as? [String: Any],
              let data = source["data"] as? String, !data.isEmpty else { return }
        let mediaType = source["media_type"] as? String ?? "image/png"
        let id = "img-\(imageCount)-\(data.prefix(18))"
        items.append(.image(id: id, ref: ImageRef(id: id, mediaType: mediaType, base64: data)))
        imageCount += 1
    }

    private func handleSystem(_ object: [String: Any]) {
        guard let subtype = object["subtype"] as? String, subtype == "compact_boundary" else { return }
        let metadata = object["compactMetadata"] as? [String: Any]
        let pre = metadata?["preTokens"] as? Int ?? 0
        let post = metadata?["postTokens"] as? Int ?? 0
        items.append(.compaction(
            id: object["uuid"] as? String ?? UUID().uuidString,
            pre: pre,
            post: post
        ))
    }
}

// MARK: - Branch parser

struct ParsedBranch {
    var items: [ConversationItem]
    var report: String?
    var steps: Int
    var duration: TimeInterval
}

enum BranchParser {
    static func parse(url: URL, parentId: String, subagentsDir: URL) -> ParsedBranch {
        var items: [ConversationItem] = []
        var toolIndices: [String: Int] = [:]
        var assistantIndices: [String: Int] = [:]
        var pendingAgents: [String: (name: String, input: [String: Any])] = [:]
        var lastAssistantText: String?
        var firstTimestamp: Date?
        var lastTimestamp: Date?

        guard let reader = try? LineReader(url: url) else {
            return ParsedBranch(items: [], report: nil, steps: 0, duration: 0)
        }

        reader.forEachLine { line in
            guard let object = JSONL.object(line) else { return true }
            guard let type = object["type"] as? String else { return true }
            let timestamp = JSONL.date(object["timestamp"])
            if let timestamp {
                firstTimestamp = firstTimestamp ?? timestamp
                lastTimestamp = timestamp
            }

            switch type {
            case "assistant":
                guard let message = object["message"] as? [String: Any],
                      let messageId = message["id"] as? String else { return true }
                let model = message["model"] as? String ?? ""
                guard let blocks = message["content"] as? [[String: Any]] else { return true }

                for block in blocks {
                    switch block["type"] as? String {
                    case "text":
                        guard let text = block["text"] as? String, !text.isEmpty else { continue }
                        lastAssistantText = text
                        if let index = assistantIndices[messageId], index < items.count,
                           case .assistant(let id, let oldText, let oldModel, let oldTimestamp) = items[index] {
                            items[index] = .assistant(
                                id: id,
                                text: oldText + "\n\n" + text,
                                model: oldModel,
                                timestamp: oldTimestamp
                            )
                        } else {
                            items.append(.assistant(id: messageId, text: text, model: model, timestamp: timestamp))
                            assistantIndices[messageId] = items.count - 1
                        }

                    case "tool_use":
                        let toolId = block["id"] as? String ?? UUID().uuidString
                        let name = block["name"] as? String ?? "Tool"
                        let input = block["input"] as? [String: Any] ?? [:]
                        let info = ToolInfo(
                            name: name,
                            summary: ToolFormat.inputSummary(name: name, input: input),
                            detail: "运行中…",
                            status: .running,
                            command: input["command"] as? String,
                            path: ToolFormat.path(input: input),
                            diff: nil,
                            facts: ToolFormat.inputFacts(name: name, input: input),
                            prompts: name == "AskUserQuestion" ? ToolFormat.questionPrompts(input: input) : []
                        )
                        items.append(.tool(id: toolId, info: info, timestamp: timestamp))
                        toolIndices[toolId] = items.count - 1
                        if name == "Agent" || name == "Task" {
                            pendingAgents[toolId] = (name, input)
                        }

                    case "image":
                        if let source = block["source"] as? [String: Any],
                           let data = source["data"] as? String, !data.isEmpty {
                            let id = "img-\(items.count)-\(data.prefix(18))"
                            items.append(.image(id: id, ref: ImageRef(
                                id: id,
                                mediaType: source["media_type"] as? String ?? "image/png",
                                base64: data
                            )))
                        }

                    default:
                        break
                    }
                }

            case "user":
                guard let message = object["message"] as? [String: Any],
                      let blocks = message["content"] as? [[String: Any]] else { return true }

                for block in blocks where (block["type"] as? String) == "tool_result" {
                    guard let toolId = block["tool_use_id"] as? String,
                          let index = toolIndices[toolId], index < items.count,
                          case .tool(let id, let info, let oldTimestamp) = items[index] else {
                        continue
                    }
                    let isError = block["is_error"] as? Bool ?? false
                    let toolUseResult = object["toolUseResult"] as? [String: Any]
                    var updated = info
                    updated.detail = ToolFormat.resultDetail(
                        name: info.name,
                        content: block["content"],
                        toolUseResult: toolUseResult
                    )
                    updated.status = isError ? .error : .ok
                    updated.diff = ToolFormat.diff(from: toolUseResult)
                    updated.facts = info.facts + ToolFormat.resultFacts(
                        name: info.name,
                        content: block["content"],
                        toolUseResult: toolUseResult
                    )
                    items[index] = .tool(id: id, info: updated, timestamp: oldTimestamp)

                    if let pending = pendingAgents.removeValue(forKey: toolId),
                       let agentId = ToolFormat.agentId(from: toolUseResult, content: block["content"]) {
                        let branchURL = subagentsDir.appendingPathComponent("agent-\(agentId).jsonl")
                        let metaURL = subagentsDir.appendingPathComponent("agent-\(agentId).meta.json")
                        var agentType = pending.input["subagent_type"] as? String ?? "Agent"
                        var title = pending.input["description"] as? String ?? "子代理"
                        if let data = try? Data(contentsOf: metaURL),
                           let meta = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                            agentType = meta["agentType"] as? String ?? agentType
                            title = meta["description"] as? String ?? title
                        }
                        let async = JSONL.textContent(block["content"]).contains("Async agent launched")
                        let node = BranchNode(
                            id: agentId,
                            parentId: parentId,
                            toolUseId: toolId,
                            agentType: agentType,
                            title: title,
                            prompt: pending.input["prompt"] as? String ?? "",
                            fileURL: FileManager.default.fileExists(atPath: branchURL.path) ? branchURL : nil,
                            status: isError ? "失败" : (async ? "已启动" : "已完成")
                        )
                        items.append(.branch(id: agentId, node: node))
                    }
                }

            case "system":
                if (object["subtype"] as? String) == "compact_boundary" {
                    let metadata = object["compactMetadata"] as? [String: Any]
                    items.append(.compaction(
                        id: object["uuid"] as? String ?? UUID().uuidString,
                        pre: metadata?["preTokens"] as? Int ?? 0,
                        post: metadata?["postTokens"] as? Int ?? 0
                    ))
                }

            default:
                break
            }

            return true
        }

        let steps = items.reduce(into: 0) { count, item in
            if case .tool = item { count += 1 }
        }
        let duration = max(0, lastTimestamp?.timeIntervalSince(firstTimestamp ?? Date.distantPast) ?? 0)

        return ParsedBranch(
            items: items,
            report: lastAssistantText,
            steps: steps,
            duration: duration
        )
    }
}

enum BranchLoader {
    static func load(_ node: BranchNode) {
        guard !node.isLoaded, !node.isLoading, let url = node.fileURL else { return }
        node.isLoading = true
        let parentId = node.id
        let subagentsDir = url.deletingLastPathComponent()

        Task.detached(priority: .userInitiated) {
            let parsed = BranchParser.parse(url: url, parentId: parentId, subagentsDir: subagentsDir)
            await MainActor.run {
                node.items = parsed.items
                node.report = parsed.report
                node.steps = parsed.steps
                node.duration = parsed.duration
                node.isLoaded = true
                node.isLoading = false
                if parsed.items.isEmpty && parsed.report == nil {
                    node.loadError = "没有可读取的子代理内容"
                }
            }
        }
    }
}
