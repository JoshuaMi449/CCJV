import Foundation

/// Continuation information derived from the local archive only. The raw
/// JSONL may already be gone; `messageUUIDs` and `checkpoints` are persisted
/// in ArchivedSession so these links keep working after Claude Code cleanup.
struct SessionLineage: Equatable {
    var parentID: String?
    var evidence: Int = 0
    var checkpointCount: Int = 0
    var isStrong: Bool = false
    var isAmbiguous: Bool = false
    var isContinuationSegment: Bool = false
    var children: [String] = []
}

/// Precomputed logical-chain lookups. `SessionChain.chainIDs` remains the
/// source of truth for which segments form one linear reading path; this
/// wrapper keeps every caller (selection, search, groups) using the same
/// chain and root for a given segment.
struct SessionChainGraph {
    private let chains: [String: [String]]
    private let roots: [String: String]

    init(lineages: [String: SessionLineage]) {
        var chains: [String: [String]] = [:]
        var roots: [String: String] = [:]

        for id in lineages.keys {
            let chain = SessionChain.chainIDs(for: id, lineages: lineages)
            chains[id] = chain
            let root = chain.first ?? id
            for member in chain {
                roots[member] = root
            }
        }

        self.chains = chains
        self.roots = roots
    }

    func chain(for id: String) -> [String] {
        chains[id] ?? [id]
    }

    func root(for id: String) -> String {
        roots[id] ?? chain(for: id).first ?? id
    }

    func strongChildren(of id: String, lineages: [String: SessionLineage]) -> [String] {
        (lineages[id]?.children ?? []).filter {
            lineages[$0]?.isStrong == true && lineages[$0]?.parentID == id
        }
    }
}

enum ArchiveLineage {
    static func build(
        sessions: [ArchivedSession],
        brokenLinks: Set<String> = []
    ) -> [String: SessionLineage] {
        var result: [String: SessionLineage] = [:]
        var owners: [String: Set<String>] = [:]

        for session in sessions {
            var uuids = Set(session.messageUUIDs ?? [])
            for message in session.messages {
                if let rawUUID = message.rawUUID {
                    uuids.insert(rawUUID)
                }
                // Older archives stored the user's raw uuid in its display id.
                if message.role == .user, message.id.hasPrefix("u-") {
                    uuids.insert(String(message.id.dropFirst(2)))
                }
            }
            for uuid in uuids {
                owners[uuid, default: []].insert(session.id)
            }

            var info = result[session.id] ?? SessionLineage()
            info.checkpointCount = session.checkpoints?.count ?? 0
            info.isContinuationSegment = session.checkpoints?.contains {
                $0.turnIndex == 0
            } ?? false
            result[session.id] = info
        }

        for session in sessions {
            guard var info = result[session.id],
                  let head = session.checkpoints?.first(where: { $0.turnIndex == 0 }) else {
                continue
            }

            var counts: [String: Int] = [:]
            var logicalParents = Set<String>()

            for uuid in head.preservedUUIDs {
                for owner in owners[uuid] ?? [] where owner != session.id {
                    counts[owner, default: 0] += 1
                }
            }
            if let logicalParentUUID = head.logicalParentUUID {
                for owner in owners[logicalParentUUID] ?? [] where owner != session.id {
                    counts[owner, default: 0] += 1
                    logicalParents.insert(owner)
                }
            }

            guard !counts.isEmpty else {
                result[session.id] = info
                continue
            }

            let bestCount = counts.values.max() ?? 0
            let best = counts
                .filter { $0.value == bestCount }
                .map(\.key)
                .sorted()

            if best.count > 1 {
                info.isAmbiguous = true
            } else if let parentID = best.first {
                info.parentID = parentID
                info.evidence = bestCount
                info.isStrong = bestCount >= 2 || logicalParents.contains(parentID)
            }
            result[session.id] = info
        }

        for id in brokenLinks {
            guard var info = result[id], info.parentID != nil else { continue }
            info.parentID = nil
            info.evidence = 0
            info.isStrong = false
            result[id] = info
        }

        for (id, info) in result {
            guard let parentID = info.parentID else { continue }
            if result[parentID]?.children.contains(id) == false {
                result[parentID]?.children.append(id)
            }
        }
        for id in result.keys {
            result[id]?.children.sort()
        }
        return result
    }
}
