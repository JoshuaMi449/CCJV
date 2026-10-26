import SwiftUI
import AppKit

struct StorageSettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedLimit = AppSettings.archiveLimitBytes
    @State private var activeAlert: StorageAlert?
    @State private var pendingLimit: Int64?
    @State private var showingLimitOptions = false

    private let presets: [Int64] = [
        256 * 1024 * 1024,
        512 * 1024 * 1024,
        1024 * 1024 * 1024,
        2 * 1024 * 1024 * 1024,
        5 * 1024 * 1024 * 1024,
        0
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("存储与归档")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("只管理 Claude Recall 的归档副本")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Theme.muted)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Theme.subtleFill))
                }
                .buttonStyle(.plain)
                .focusable(false)
            }

            usageCard
            if model.archiveHealth.hasIssues {
                archiveHealthCard
            }
            limitRow
            actions

            Text("归档只保存你的提问、每轮最终回答、子代理最终回答，以及识别续接所需的消息 UUID 和上下文压缩边界；工具调用、命令、diff、代码块和图片不会保存。\n\nClaude Code 可能自动清理 30 天前的原始 JSON；已归档的会话不受影响，原始文件被清理后仍可查看，并可继续显示前后段续接关系。Claude Recall 每次打开和运行期间会自动更新归档，因此清理前至少打开过一次，才能留下归档副本。单个会话可在会话菜单里删除归档；可在同一菜单保留整条续接链，容量淘汰会按整条链处理，避免留下半条链。")
                .font(.system(size: 10.5, weight: .regular))
                .foregroundStyle(Theme.faint)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 520)
        .background(Theme.screen)
        .alert(item: $activeAlert) { alert in
            switch alert {
            case .clear:
                return Alert(
                    title: Text("清空全部归档？"),
                    message: Text("只删除 Claude Recall 的归档副本，不会动 ~/.claude 的原始 JSON。清空后现有会话不会自动重新归档，删除的内容不可恢复。"),
                    primaryButton: .destructive(Text("清空")) {
                        model.clearArchive()
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
            case .limit:
                return Alert(
                    title: Text("将删除最旧的归档"),
                    message: Text("新上限低于当前归档占用，会立即删除最旧的归档；如果原始文件已不存在，这些会话将无法再查看。"),
                    primaryButton: .destructive(Text("继续")) {
                        if let pendingLimit {
                            model.applyArchiveLimit(pendingLimit)
                        }
                        pendingLimit = nil
                    },
                    secondaryButton: .cancel(Text("取消")) {
                        pendingLimit = nil
                        selectedLimit = AppSettings.archiveLimitBytes
                    }
                )
            }
        }
    }

    private var usageCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("归档占用")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSoft)

                Spacer()

                Text("\(byteLabel(model.archiveUsageBytes)) / \(presetLabel(selectedLimit))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .monospacedDigit()
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.stroke)
                    Capsule()
                        .fill(Theme.orangeGradient)
                        .frame(width: max(6, proxy.size.width * usageFraction))
                }
            }
            .frame(height: 8)

            Text("仅统计归档文件夹；不含 ~/.claude/projects 的原始 JSON。")
                .font(.system(size: 9.5, weight: .regular))
                .foregroundStyle(Theme.faint)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.panelLift)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Theme.glassBorder, lineWidth: 1)
        }
    }

    private var archiveHealthCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.orange)
                Text("归档状态需要留意")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
            }

            if !model.archiveHealth.unreadableFiles.isEmpty {
                healthLine("\(model.archiveHealth.unreadableFiles.count) 个归档文件无法读取", detail: model.archiveHealth.unreadableFiles.prefix(2).joined(separator: "、"))
            }
            if !model.archiveHealth.failedWriteIDs.isEmpty {
                healthLine("\(model.archiveHealth.failedWriteIDs.count) 个会话归档写入失败", detail: "可能是磁盘空间或权限问题；原始文件仍在时下次同步会重试。")
            }
            if !model.archiveHealth.evictedIDs.isEmpty {
                healthLine("已因容量上限淘汰 \(model.archiveHealth.evictedIDs.count) 个会话", detail: "淘汰按整条续接链处理；原始文件仍在的会话不受影响。")
            }
            if model.archiveHealth.overQuota {
                healthLine("归档仍超过上限", detail: "保留链或不可分割的链阻止了进一步淘汰；请提高上限或手动删除归档。")
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.orange.opacity(0.07))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.orange.opacity(0.22), lineWidth: 1)
        }
    }

    private func healthLine(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.textSoft)
            Text(detail)
                .font(.system(size: 9.5, weight: .regular))
                .foregroundStyle(Theme.faint)
                .lineLimit(2)
        }
    }

    private var limitRow: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("归档上限")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("超出后自动删除最旧的归档")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(Theme.muted)
            }

            Spacer()

            Button {
                showingLimitOptions.toggle()
            } label: {
                HStack(spacing: 7) {
                    Text(presetLabel(selectedLimit))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 13)
                .frame(height: 34)
                .background(Capsule().fill(Theme.panelLift))
                .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
                .shadow(color: Theme.cardShadow, radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .focusEffectDisabled()
            .popover(isPresented: $showingLimitOptions, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(presets, id: \.self) { value in
                        Button {
                            selectedLimit = value
                            showingLimitOptions = false
                            requestLimit(value)
                        } label: {
                            HStack(spacing: 8) {
                                Text(presetLabel(value))
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(Theme.text)
                                Spacer()
                                if value == selectedLimit {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                            .padding(.horizontal, 10)
                            .frame(width: 160, height: 30, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                    }
                }
                .padding(6)
                .background(Theme.panelLift)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                NSWorkspace.shared.open(ArchiveStore.archiveFolderURL)
            } label: {
                Label("在 Finder 中显示", systemImage: "folder")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.textSoft)
                    .padding(.horizontal, 13)
                    .frame(height: 34)
                    .background(Capsule().fill(Theme.panelLift))
                    .overlay(Capsule().stroke(Theme.glassBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .focusEffectDisabled()

            Spacer()

            Button {
                activeAlert = .clear
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "trash")
                    Text("清空归档")
                }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.red)
                .padding(.horizontal, 13)
                .frame(height: 34)
                .background(Capsule().fill(Theme.red.opacity(0.08)))
                .overlay(Capsule().stroke(Theme.red.opacity(0.18), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .focusEffectDisabled()
        }
    }

    private var usageFraction: Double {
        guard selectedLimit > 0 else { return 0.04 }
        return min(1, max(0, Double(model.archiveUsageBytes) / Double(selectedLimit)))
    }

    private func presetLabel(_ value: Int64) -> String {
        switch value {
        case 0: return "不限"
        case 256 * 1024 * 1024: return "256 MB"
        case 512 * 1024 * 1024: return "512 MB"
        case 1024 * 1024 * 1024: return "1 GB"
        case 2 * 1024 * 1024 * 1024: return "2 GB"
        case 5 * 1024 * 1024 * 1024: return "5 GB"
        default: return byteLabel(value)
        }
    }

    private func requestLimit(_ value: Int64) {
        if value > 0, value < model.archiveUsageBytes {
            pendingLimit = value
            activeAlert = .limit
        } else {
            model.applyArchiveLimit(value)
        }
    }

    private func byteLabel(_ value: Int64) -> String {
        guard value > 0 else { return "0 B" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

private enum StorageAlert: Int, Identifiable {
    case clear
    case limit

    var id: Int { rawValue }
}
