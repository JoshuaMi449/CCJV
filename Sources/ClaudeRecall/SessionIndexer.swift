import Foundation

enum SessionIndexer {
    static func scan() -> [SessionSummary] {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)

        guard let projectDirs = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [SessionSummary] = []

        for projectDir in projectDirs {
            let isDirectory = (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory else { continue }

            guard let files = try? fm.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                if let summary = quickSummary(file: file, project: projectDir.lastPathComponent) {
                    results.append(summary)
                }
            }
        }

        // A copied/restored project directory can contain the same session
        // UUID twice. Keep one deterministic copy instead of letting a
        // Dictionary(uniqueKeysWithValues:) crash the app.
        var byID: [String: SessionSummary] = [:]
        for result in results {
            if let existing = byID[result.id] {
                if result.date > existing.date
                    || (result.date == existing.date && result.fileURL.path < existing.fileURL.path) {
                    byID[result.id] = result
                }
            } else {
                byID[result.id] = result
            }
        }
        return byID.values.sorted { $0.date > $1.date }
    }

    /// The file's modification date is not a reliable conversation date:
    /// Claude Code can append metadata to an old session and bump the mtime
    /// long after the last message. Read backwards for the last real message.
    private static func lastConversationTimestamp(file: URL, size: Int64) -> Date? {
        guard size > 0, let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        var window: Int64 = 256 * 1024
        let maxWindow: Int64 = 8 * 1024 * 1024
        while true {
            let start = max(0, size - window)
            guard (try? handle.seek(toOffset: UInt64(start))) != nil,
                  let data = try? handle.read(upToCount: Int(min(window, size - start))),
                  !data.isEmpty else { return nil }

            var text = String(decoding: data, as: UTF8.self)
            if start > 0, let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }

            for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
                guard let object = JSONL.object(Data(line.utf8)) else { continue }
                let type = object["type"] as? String
                guard type == "user" || type == "assistant" else { continue }
                if let date = JSONL.date(object["timestamp"]) {
                    return date
                }
            }

            if start == 0 || window >= maxWindow { break }
            window = min(window * 2, maxWindow)
        }
        return nil
    }

    private static func quickSummary(file: URL, project: String) -> SessionSummary? {
        let fm = FileManager.default
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modifiedAt = values?.contentModificationDate ?? Date.distantPast
        let size = Int64(values?.fileSize ?? 0)
        let date = lastConversationTimestamp(file: file, size: size) ?? modifiedAt

        var title = ""
        var preview = ""
        var humanCount = 0
        var lines = 0

        if let reader = try? LineReader(url: file) {
            reader.forEachLine { line in
                lines += 1
                if lines > 240 { return false }
                guard let object = JSONL.object(line) else { return true }

                if (object["type"] as? String) == "ai-title",
                   let aiTitle = object["aiTitle"] as? String,
                   !aiTitle.isEmpty {
                    title = aiTitle
                    return true
                }

                guard (object["type"] as? String) == "user",
                      let message = object["message"] as? [String: Any],
                      JSONL.isHuman(object),
                      let text = JSONL.messageText(message),
                      !JSONL.isCommandWrapper(text) else {
                    return true
                }

                let cleaned = JSONL.cleanUserText(text)
                guard !cleaned.isEmpty else { return true }
                humanCount += 1
                if preview.isEmpty {
                    preview = cleaned
                        .replacingOccurrences(of: "\n", with: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return true
            }
        }

        let sessionId = file.deletingPathExtension().lastPathComponent
        let subagents = file.deletingPathExtension()
            .appendingPathComponent("subagents", isDirectory: true)
        let subagentCount = (try? fm.contentsOfDirectory(atPath: subagents.path))?
            .filter { $0.hasSuffix(".jsonl") }
            .count ?? 0

        let cleanPreview = String(preview.prefix(80))
        if title.isEmpty {
            if preview.isEmpty {
                title = "未命名会话"
            } else {
                let shortened = String(preview.prefix(28))
                title = preview.count > shortened.count ? shortened + "…" : shortened
            }
        }

        return SessionSummary(
            id: sessionId,
            title: title,
            project: project,
            preview: cleanPreview,
            date: date,
            turns: humanCount,
            fileURL: file,
            subagentCount: subagentCount,
            fileSize: size
        )
    }
}
