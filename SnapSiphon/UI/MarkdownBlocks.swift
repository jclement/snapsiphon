import SwiftUI

/// Minimal block-level markdown renderer. SwiftUI's `Text(markdown:)` only
/// handles inline styling — bullets and numbered lists come out as run-on
/// text with no hanging indent. This view parses paragraphs, `- ` bullets,
/// and `1. ` numbered items into rows whose wrapped lines indent under the
/// CONTENT, not the marker; inline markdown (bold, code, links) still renders
/// via AttributedString.
struct MarkdownBlocks: View {
    let markdown: String

    private enum Block: Identifiable {
        case paragraph(String)
        case bullet(String)
        case numbered(Int, String)
        var id: String {
            switch self {
            case .paragraph(let t): return "p:\(t)"
            case .bullet(let t): return "b:\(t)"
            case .numbered(let n, let t): return "n:\(n):\(t)"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Self.parse(markdown)) { block in
                switch block {
                case .paragraph(let text):
                    inline(text)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(Theme.teal)
                        inline(text)
                    }
                case .numbered(let n, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(n).").monospacedDigit().foregroundStyle(Theme.teal)
                        inline(text)
                    }
                }
            }
        }
    }

    private func inline(_ text: String) -> some View {
        Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Lines → blocks. Consecutive plain lines merge into one paragraph;
    /// a list item's continuation lines (indented) merge into the item.
    private static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph = []
            }
        }
        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("- ") || line.hasPrefix("• ") {
                flush()
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else if let dot = line.firstIndex(of: "."),
                      let n = Int(line[line.startIndex..<dot]),
                      line.index(after: dot) < line.endIndex,
                      line[line.index(after: dot)] == " " {
                flush()
                blocks.append(.numbered(n, String(line[line.index(dot, offsetBy: 2)...])))
            } else if rawLine.hasPrefix("  "), let last = blocks.last, paragraph.isEmpty {
                // Indented continuation of the previous list item.
                switch last {
                case .bullet(let t): blocks[blocks.count - 1] = .bullet(t + " " + line)
                case .numbered(let n, let t): blocks[blocks.count - 1] = .numbered(n, t + " " + line)
                case .paragraph: paragraph.append(line)
                }
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }
}

/// The bundled help document (`Help.md`), split into `## `-titled sections so
/// each renders as its own card. Editing the markdown file is the whole
/// maintenance story — no view code changes.
enum HelpDoc {
    static func sections() -> [(title: String, body: String)] {
        guard let url = Bundle.main.url(forResource: "Help", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var sections: [(String, String)] = []
        var title: String? = nil
        var body: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                if let t = title { sections.append((t, body.joined(separator: "\n"))) }
                title = String(line.dropFirst(3))
                body = []
            } else if line.hasPrefix("# ") {
                continue                    // document title — the header shows it
            } else if title != nil {
                body.append(String(line))
            }
        }
        if let t = title { sections.append((t, body.joined(separator: "\n"))) }
        return sections
    }
}
