import Foundation
import SwiftUI

enum GroupBallStyle: String, Codable, CaseIterable, Identifiable {
    case ocean
    case sunset
    case forest
    case violet
    case graphite
    case rose

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ocean: return "海蓝"
        case .sunset: return "落日"
        case .forest: return "苔绿"
        case .violet: return "鸢尾"
        case .graphite: return "石墨"
        case .rose: return "玫瑰"
        }
    }

    var colors: [Color] {
        switch self {
        case .ocean:
            return [Color(hex: 0xA8CBFF), Color(hex: 0x6EA8FF), Color(hex: 0x2358C8)]
        case .sunset:
            return [Color(hex: 0xFFCD8A), Color(hex: 0xFF9A52), Color(hex: 0xE2501D)]
        case .forest:
            return [Color(hex: 0xA7EFD2), Color(hex: 0x45D6A0), Color(hex: 0x0F7A5A)]
        case .violet:
            return [Color(hex: 0xDCC8FF), Color(hex: 0xB68CFF), Color(hex: 0x6A35D8)]
        case .graphite:
            return [Color(hex: 0xC4D0DD), Color(hex: 0x7E90A3), Color(hex: 0x384552)]
        case .rose:
            return [Color(hex: 0xFFC9DB), Color(hex: 0xFF86AE), Color(hex: 0xD63B72)]
        }
    }

    var gradient: LinearGradient {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct SessionGroupRecord: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var sessionIDs: [String]
    var style: GroupBallStyle
    var isCollapsed: Bool
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        name: String,
        sessionIDs: [String] = [],
        style: GroupBallStyle = .ocean,
        isCollapsed: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.sessionIDs = sessionIDs
        self.style = style
        self.isCollapsed = isCollapsed
        self.createdAt = createdAt
    }
}

struct SessionWorkspace: Codable {
    var version: Int = 1
    var aliases: [String: String] = [:]
    var groups: [SessionGroupRecord] = []
    /// Continuation edges the user explicitly turned off. Optional so older
    /// workspace files still decode.
    var brokenLinks: [String]? = nil
}

enum SessionWorkspaceStore {
    static var folderURL: URL {
        ArchiveStore.directoryURL.appendingPathComponent("Workspace", isDirectory: true)
    }

    static var fileURL: URL {
        folderURL.appendingPathComponent("workspace.json")
    }

    static func load() -> SessionWorkspace {
        guard let data = try? Data(contentsOf: fileURL) else {
            return SessionWorkspace()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let workspace = try? decoder.decode(SessionWorkspace.self, from: data) {
            return workspace
        }
        let backup = folderURL.appendingPathComponent(
            "workspace.corrupt-\(Int(Date().timeIntervalSince1970)).json"
        )
        try? FileManager.default.moveItem(at: fileURL, to: backup)
        NSLog("CCJV: workspace.json was unreadable; preserved a copy at %@", backup.path)
        return SessionWorkspace()
    }

    static func save(_ workspace: SessionWorkspace) {
        let fm = FileManager.default
        try? fm.createDirectory(
            at: folderURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(workspace) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            return
        }
    }
}
