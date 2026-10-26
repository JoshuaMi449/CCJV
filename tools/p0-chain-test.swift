import Foundation

@main
struct P0ChainTests {
    static func main() throws {
        var failures = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                failures += 1
                print("FAIL: \(message)")
            }
        }

        func summary(id: String, title: String = "会话") -> SessionSummary {
            SessionSummary(
                id: id,
                title: title,
                project: "test",
                preview: "",
                date: Date(timeIntervalSince1970: 0),
                turns: 0,
                fileURL: URL(fileURLWithPath: "/tmp/\(id).jsonl"),
                subagentCount: 0,
                fileSize: 0
            )
        }

        func archived(
            id: String,
            uuids: [String],
            checkpoint: ArchivedCheckpoint? = nil
        ) -> ArchivedSession {
            ArchivedSession(
                id: id,
                sourcePath: "/tmp/\(id).jsonl",
                title: id,
                project: "test",
                date: Date(timeIntervalSince1970: 0),
                mainSignature: "main",
                subagentSignature: "sub",
                messages: [],
                subagents: [],
                schema: 2,
                messageUUIDs: uuids,
                checkpoints: checkpoint.map { [$0] }
            )
        }

        func conversation(id: String, users: [(String, TimeInterval)]) -> Conversation {
            var items: [ConversationItem] = []
            for (uuid, time) in users {
                items.append(.user(
                    id: uuid,
                    text: uuid,
                    timestamp: Date(timeIntervalSince1970: time)
                ))
            }
            let dates = items.compactMap { item -> Date? in
                if case .user(_, _, let timestamp) = item { return timestamp }
                return nil
            }
            return Conversation(
                session: summary(id: id),
                items: items,
                turns: Conversation.groupTurns(items),
                branchCount: 0,
                imageCount: 0,
                eventCount: items.count,
                startedAt: dates.min(),
                endedAt: dates.max()
            )
        }

        let checkpoint = ArchivedCheckpoint(
            timestamp: Date(timeIntervalSince1970: 10),
            trigger: "manual",
            preTokens: nil,
            postTokens: nil,
            turnIndex: 0,
            preservedUUIDs: ["u1", "u2"],
            allUUIDs: ["u1", "u2"],
            anchorUUID: "u1",
            logicalParentUUID: nil
        )
        let parent = archived(id: "parent", uuids: ["u1", "u2"])
        let child = archived(id: "child", uuids: [], checkpoint: checkpoint)
        let child2 = archived(id: "child2", uuids: [], checkpoint: checkpoint)
        let lineages = ArchiveLineage.build(sessions: [parent, child, child2])

        expect(lineages["child"]?.parentID == "parent", "child parent")
        expect(lineages["child"]?.evidence == 2, "child evidence")
        expect(lineages["child"]?.isStrong == true, "child strong")

        let graph = SessionChainGraph(lineages: lineages)
        expect(graph.chain(for: "child") == ["parent", "child"], "child linear chain")
        expect(graph.chain(for: "parent") == ["parent"], "parent with two children stays solo")
        expect(graph.root(for: "child") == "parent", "child root")
        expect(graph.strongChildren(of: "parent", lineages: lineages).count == 2, "two strong children")

        let broken = ArchiveLineage.build(
            sessions: [parent, child, child2],
            brokenLinks: ["child"]
        )
        let brokenGraph = SessionChainGraph(lineages: broken)
        expect(broken["child"]?.parentID == nil, "manual broken link removes parent")
        expect(brokenGraph.chain(for: "child") == ["child"], "broken child stays solo")
        expect(brokenGraph.strongChildren(of: "parent", lineages: broken).count == 1, "broken child removed from parent children")

        let parentPart = SessionChainPart(
            summary: summary(id: "parent"),
            conversation: conversation(id: "parent", users: [("u1", 1), ("u2", 2), ("u3", 10)]),
            cutoffDate: Date(timeIntervalSince1970: 5)
        )
        let childPart = SessionChainPart(
            summary: summary(id: "child"),
            conversation: conversation(id: "child", users: [("u2", 20), ("u4", 30)]),
            cutoffDate: nil
        )
        let merged = SessionChain.merge(parts: [parentPart, childPart], selectedID: "child")
        expect(merged?.turns.map(\.id) == ["u-u1", "u-u2", "u-u4"], "merge dedupe/order")
        expect(merged?.segments.count == 2, "merge segment count")
        expect(merged?.segments.first?.turnCount == 1, "parent segment turn count")
        expect(merged?.segments.first?.omittedTurnCount == 1, "parent omitted count")
        expect(merged?.segments.last?.roleLabel == "本段", "child role")
        expect(merged?.contains(turnID: "u-u2", itemID: "u-u2") == true, "contains child turn")
        expect(merged?.contains(turnID: "u-u3", itemID: "u-u3") == false, "does not contain omitted turn")

        func question(_ id: String, _ minY: CGFloat, _ maxY: CGFloat) -> UserQuestionFrame {
            UserQuestionFrame(turnID: id, minY: minY, maxY: maxY)
        }

        let q1 = question("q1", 100, 160)
        let q2 = question("q2", 500, 560)
        let q3 = question("q3", 580, 640)
        let initial = QuestionSelection.resolve(
            frames: [q1, q2, q3],
            activeID: nil,
            direction: .down,
            previousVisibleIDs: [],
            viewportHeight: 600
        )
        expect(initial.activeID == "q1", "initial visible question")
        expect(initial.visibleIDs == ["q1", "q2", "q3"], "visible question ids")

        let down = QuestionSelection.resolve(
            frames: [q1, q2, q3],
            activeID: "q1",
            direction: .down,
            previousVisibleIDs: ["q1", "q2"],
            viewportHeight: 600
        )
        expect(down.activeID == "q3", "down switches to newly visible lower question")

        let emptyVisible = QuestionSelection.resolve(
            frames: [question("q1", 700, 760), question("q2", -100, -40)],
            activeID: "q3",
            direction: .down,
            previousVisibleIDs: ["q1", "q2"],
            viewportHeight: 600
        )
        expect(emptyVisible.activeID == "q3", "no visible question keeps last highlight")
        expect(emptyVisible.visibleIDs.isEmpty, "no visible question ids")

        let up = QuestionSelection.resolve(
            frames: [question("q1", 20, 80), question("q2", 100, 160), q3],
            activeID: "q3",
            direction: .up,
            previousVisibleIDs: [],
            viewportHeight: 600
        )
        expect(up.activeID == "q1", "up switches to earliest newly visible question")

        let downJump = QuestionSelection.resolve(
            frames: [question("q4", 300, 360), question("q5", 500, 560)],
            activeID: "q3",
            direction: .down,
            previousVisibleIDs: [],
            viewportHeight: 600
        )
        expect(downJump.activeID == "q5", "down jump chooses latest visible question")

        let noStaleClear = QuestionSelection.resolve(
            frames: [],
            activeID: "q2",
            direction: .down,
            previousVisibleIDs: ["q1"],
            viewportHeight: 600
        )
        expect(noStaleClear.activeID == "q2", "empty frames do not clear active question")

        // Archive health + whole-chain capacity protection.
        let root = URL(fileURLWithPath: "/tmp/recall-p0-tools-archive")
        try? FileManager.default.removeItem(at: root)
        let archiveDir = root.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)
        ArchiveStore.directoryOverride = root
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for session in [parent, child, child2] {
            let data = try encoder.encode(session)
            try data.write(to: archiveDir.appendingPathComponent("\(session.id).json"))
        }
        try Data("not-json".utf8).write(to: archiveDir.appendingPathComponent("broken.json"))

        let loaded = ArchiveStore.loadWithReport()
        expect(loaded.document.sessions.count == 3, "archive load count")
        expect(loaded.unreadableFiles == ["broken.json"], "archive unreadable report")

        ArchiveStore.setPinned("parent", pinned: true)
        let pinnedQuota = ArchiveStore.enforceQuotaWithReport(on: loaded.document, maxBytes: 100)
        let pinnedIDs = Set(pinnedQuota.document.sessions.map(\.id))
        expect(pinnedIDs.contains("parent") && pinnedIDs.contains("child"), "pinned chain kept together")
        expect(pinnedQuota.overQuota, "pinned chain reports over quota")

        ArchiveStore.setPinned("parent", pinned: false)
        let freeQuota = ArchiveStore.enforceQuotaWithReport(on: pinnedQuota.document, maxBytes: 100)
        let freeIDs = Set(freeQuota.document.sessions.map(\.id))
        expect(!freeIDs.contains("parent") && !freeIDs.contains("child"), "unpinned chain evicted together")

        if failures == 0 {
            print("P0 chain/archive tests passed")
        } else {
            print("P0 tests failed: \(failures)")
            exit(1)
        }
    }
}
