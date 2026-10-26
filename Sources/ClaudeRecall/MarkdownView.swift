import SwiftUI

private struct MarkdownBlock: Identifiable {
    enum Kind {
        case paragraph(String)
        case heading(Int, String)
        case code(String, String)
        case listItem(String, String, Int)
        case rule
    }

    let id: Int
    let kind: Kind
}

extension AttributedString {
    mutating func highlightOccurrences(of query: String?) {
        let q = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !q.isEmpty else { return }

        let plain = String(characters)
        var searchStart = plain.startIndex

        while searchStart < plain.endIndex,
              let range = plain.range(
                  of: q,
                  options: [.caseInsensitive, .diacriticInsensitive],
                  range: searchStart..<plain.endIndex
              ) {
            let lower = plain.distance(from: plain.startIndex, to: range.lowerBound)
            let upper = plain.distance(from: plain.startIndex, to: range.upperBound)
            let start = index(startIndex, offsetByCharacters: lower)
            let end = index(startIndex, offsetByCharacters: upper)

            self[start..<end].foregroundColor = Theme.accent
            self[start..<end].backgroundColor = Theme.searchHighlight
            self[start..<end].inlinePresentationIntent = .stronglyEmphasized

            if range.isEmpty { break }
            searchStart = range.upperBound
        }
    }
}

struct MarkdownMessageView: View {
    let text: String
    var highlightQuery: String?

    private var blocks: [MarkdownBlock] {
        MarkdownParser.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block.kind {
        case .paragraph(let content):
            inlineText(content)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Theme.textSoft)
                .lineSpacing(6)
                .textSelection(.enabled)

        case .heading(let level, let content):
            inlineText(content)
                .font(.system(
                    size: level == 1 ? 20 : level == 2 ? 16.5 : 14.5,
                    weight: .semibold
                ))
                .foregroundStyle(Theme.text)
                .padding(.top, level <= 2 ? 4 : 2)
                .textSelection(.enabled)

        case .code(let language, let code):
            CodeBlockView(language: language, code: code, highlightQuery: highlightQuery)

        case .listItem(let marker, let content, let indent):
            HStack(alignment: .top, spacing: 7) {
                Text(marker)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(minWidth: 12, alignment: .trailing)
                inlineText(content)
                    .font(.system(size: 13.5, weight: .regular))
                    .foregroundStyle(Theme.textSoft)
                    .lineSpacing(5.5)
                    .textSelection(.enabled)
            }
            .padding(.leading, CGFloat(indent) * 12)

        case .rule:
            Rectangle()
                .fill(Theme.divider)
                .frame(height: 1)
                .padding(.vertical, 3)
        }
    }

    private func inlineText(_ string: String) -> Text {
        var attributed = (try? AttributedString(
            markdown: string,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(string)
        attributed.highlightOccurrences(of: highlightQuery)
        return Text(attributed)
    }
}

private struct CodeBlockView: View {
    let language: String
    let code: String
    var highlightQuery: String?
    @State private var expanded = false

    private var lineCount: Int {
        code.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    private var firstLine: String {
        code.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
    }

    private func highlighted(_ value: String) -> AttributedString {
        var attributed = AttributedString(value)
        attributed.highlightOccurrences(of: highlightQuery)
        return attributed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.orange)
                    Text(language.isEmpty ? "CODE" : language.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textSoft)
                    Spacer()
                    Text("\(lineCount) 行")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.faint)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.orange)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)

            if expanded {
                Rectangle().fill(Theme.stroke).frame(height: 1)
                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    Text(highlighted(code))
                        .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(Theme.textSoft)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 380)
            } else {
                Text(highlighted(firstLine.isEmpty ? " " : firstLine))
                    .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Theme.sunken)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Theme.stroke, lineWidth: 1)
        )
    }
}

private enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0
        var blockID = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let content = paragraph.joined(separator: "\n")
            blocks.append(MarkdownBlock(id: blockID, kind: .paragraph(content)))
            blockID += 1
            paragraph.removeAll()
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph()
                let language = String(trimmed.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix("```") { break }
                    code.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(MarkdownBlock(
                    id: blockID,
                    kind: .code(language, code.joined(separator: "\n"))
                ))
                blockID += 1
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(MarkdownBlock(id: blockID, kind: .rule))
                blockID += 1
                index += 1
                continue
            }

            let hashes = trimmed.prefix { $0 == "#" }.count
            if hashes > 0, hashes <= 6 {
                let rest = trimmed.dropFirst(hashes)
                if rest.hasPrefix(" ") {
                    flushParagraph()
                    let content = rest.trimmingCharacters(in: .whitespaces)
                    blocks.append(MarkdownBlock(id: blockID, kind: .heading(hashes, content)))
                    blockID += 1
                    index += 1
                    continue
                }
            }

            let indent = (line.prefix { $0 == " " }.count) / 2
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flushParagraph()
                blocks.append(MarkdownBlock(
                    id: blockID,
                    kind: .listItem("•", String(trimmed.dropFirst(2)), indent)
                ))
                blockID += 1
                index += 1
                continue
            }

            if let dot = trimmed.firstIndex(of: "."),
               let number = Int(trimmed[..<dot]),
               trimmed[trimmed.index(after: dot)...].hasPrefix(" ") {
                flushParagraph()
                let content = String(trimmed[trimmed.index(after: dot)...])
                    .trimmingCharacters(in: .whitespaces)
                blocks.append(MarkdownBlock(
                    id: blockID,
                    kind: .listItem("\(number).", content, indent)
                ))
                blockID += 1
                index += 1
                continue
            }

            paragraph.append(line)
            index += 1
        }

        flushParagraph()
        return blocks
    }
}
