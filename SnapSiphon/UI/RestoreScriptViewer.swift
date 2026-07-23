import SwiftUI

/// Full-screen sheet showing the generated restore script with lightweight
/// Python syntax highlighting, so the user can read exactly what they're about
/// to copy (it contains live secrets) before it ever leaves the app.
struct RestoreScriptViewer: View {
    let script: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    /// The script written to a temp file so the share sheet offers it as a
    /// real `restore.py` (AirDrop, Save to Files, mail attachment) instead of
    /// a wall of text. Removed again when the sheet closes.
    @State private var shareURL: URL?

    private func makeShareFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("restore.py")
        try? script.data(using: .utf8)?.write(to: url, options: .completeFileProtection)
        shareURL = url
    }

    private func removeShareFile() {
        if let shareURL { try? FileManager.default.removeItem(at: shareURL) }
        shareURL = nil
    }

    var body: some View {
        NavigationStack {
            ScrollView([.vertical, .horizontal], showsIndicators: true) {
                Text(PythonHighlighter.highlight(script))
                    .font(Theme.mono(11))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(14)
            }
            .background(Theme.canvas.ignoresSafeArea())
            .navigationTitle("restore.py · \(Format.bytes(Int64(script.utf8.count)))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if let shareURL {
                        ShareLink(item: shareURL,
                                  preview: SharePreview("restore.py", image: Image(systemName: "cross.case.fill"))) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .tint(Theme.teal)
                    }
                    Button {
                        UIPasteboard.general.string = script
                        copied = true
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            copied = false
                        }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .tint(copied ? .green : Theme.teal)
                }
            }
            .onAppear(perform: makeShareFile)
            .onDisappear(perform: removeShareFile)
        }
        .preferredColorScheme(.dark)
    }
}

/// A deliberately small line-based Python highlighter — comments, strings,
/// docstrings, keywords, numbers. Good enough to make a 200-line script
/// readable; not a parser.
enum PythonHighlighter {
    private static let keywords: Set<String> = [
        "import", "from", "def", "class", "return", "if", "elif", "else", "for",
        "while", "in", "not", "and", "or", "is", "try", "except", "finally",
        "raise", "with", "as", "pass", "break", "continue", "lambda",
        "None", "True", "False", "print",
    ]

    private static let baseColor = Theme.textPrimary
    private static let commentColor = Color(red: 0.45, green: 0.55, blue: 0.48)
    private static let stringColor = Color.orange.opacity(0.9)
    private static let keywordColor = Theme.violet
    private static let numberColor = Theme.teal

    private static let tokenRegex = try! NSRegularExpression(
        pattern: #""(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\b\d[\w.]*\b|\b[A-Za-z_]\w*\b"#)

    static func highlight(_ source: String) -> AttributedString {
        var out = AttributedString()
        var inDocstring = false
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, lineSub) in lines.enumerated() {
            if i > 0 { out += AttributedString("\n") }
            let line = String(lineSub)
            let delimiters = line.components(separatedBy: "\"\"\"").count - 1
            if inDocstring {
                out += colored(line, commentColor)
                if delimiters % 2 == 1 { inDocstring = false }
            } else if delimiters > 0 {
                out += colored(line, commentColor)
                if delimiters % 2 == 1 { inDocstring = true }
            } else {
                out += highlightCode(line)
            }
        }
        return out
    }

    private static func highlightCode(_ line: String) -> AttributedString {
        // Split off a trailing comment (a # not inside a quote).
        var quote: Character? = nil
        var commentIndex: String.Index? = nil
        var idx = line.startIndex
        while idx < line.endIndex {
            let ch = line[idx]
            if let q = quote {
                if ch == "\\" { idx = line.index(after: idx) }
                else if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "#" {
                commentIndex = idx
                break
            }
            if idx < line.endIndex { idx = line.index(after: idx) }
        }
        let code = commentIndex.map { String(line[..<$0]) } ?? line
        let comment = commentIndex.map { String(line[$0...]) }

        var out = AttributedString()
        let ns = code as NSString
        var cursor = 0
        for match in tokenRegex.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor {
                out += colored(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), baseColor)
            }
            let token = ns.substring(with: match.range)
            let color: Color
            if token.hasPrefix("\"") || token.hasPrefix("'") { color = stringColor }
            else if token.first?.isNumber == true { color = numberColor }
            else if keywords.contains(token) { color = keywordColor }
            else { color = baseColor }
            out += colored(token, color)
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            out += colored(ns.substring(from: cursor), baseColor)
        }
        if let comment { out += colored(comment, commentColor) }
        return out
    }

    private static func colored(_ s: String, _ c: Color) -> AttributedString {
        var a = AttributedString(s)
        a.foregroundColor = c
        return a
    }
}
