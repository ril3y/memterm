import Foundation

/// A file path or URL found under a right-click in the terminal.
public struct DetectedLink: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case url, path }
    public let kind: Kind
    /// The path or URL itself, without surrounding quotes or punctuation.
    public let text: String
    /// A compiler-style ":line" or ":line:col" that followed a path, split
    /// off so "Copy Path" copies a path the shell can open.
    public let lineSuffix: String?

    public init(kind: Kind, text: String, lineSuffix: String? = nil) {
        self.kind = kind
        self.text = text
        self.lineSuffix = lineSuffix
    }
}

/// One terminal cell's text, as the app reads it from SwiftTerm. `width` is
/// 2 for a wide character and 0 for the cell that follows it.
public struct TerminalCellText: Equatable, Sendable {
    public let character: Character
    public let width: Int

    public init(character: Character, width: Int) {
        self.character = character
        self.width = width
    }
}

/// Founder ask 2026-10-29: right-click a path or URL in a pane to copy it.
///
/// Three steps, all pure so they are unit-tested: turn the click point into
/// a cell, join the soft-wrapped rows around that cell into one logical line
/// (a long path wraps in a narrow pane), and find the token under the click.
public enum TerminalLinkDetect {

    // MARK: - Point to cell

    /// The cell under a point in the pane's own coordinates (AppKit: y grows
    /// upward, so row 0 is at the top). Clamped to the grid.
    public static func cell(atX x: Double, y: Double, viewHeight: Double,
                            cellWidth: Double, cellHeight: Double,
                            cols: Int, rows: Int) -> (col: Int, row: Int) {
        let col = Int((x / cellWidth).rounded(.down))
        let row = Int(((viewHeight - y) / cellHeight).rounded(.down))
        return (min(max(col, 0), max(cols - 1, 0)), min(max(row, 0), max(rows - 1, 0)))
    }

    // MARK: - Joining wrapped rows

    /// Joins the clicked row with the rows it soft-wraps into and out of.
    /// `wrapped[k]` is true when row k continues row k-1. Returns the joined
    /// characters and the index of the clicked cell's character in them.
    public static func logicalLine(rows: [[TerminalCellText]], wrapped: [Bool],
                                   clickRow: Int, clickCol: Int) -> (text: [Character], index: Int) {
        guard rows.indices.contains(clickRow) else { return ([], 0) }
        func isWrapped(_ row: Int) -> Bool { wrapped.indices.contains(row) && wrapped[row] }
        var start = clickRow
        while start > 0, isWrapped(start) { start -= 1 }
        var end = clickRow
        while end + 1 < rows.count, isWrapped(end + 1) { end += 1 }

        var text: [Character] = []
        var index = 0
        for row in start...end {
            for (col, cell) in rows[row].enumerated() {
                let isClick = row == clickRow && col == clickCol
                if cell.width == 0 {
                    // The second half of a wide character: it belongs to the
                    // character before it.
                    if isClick { index = max(text.count - 1, 0) }
                    continue
                }
                if isClick { index = text.count }
                text.append(cell.character == "\u{0}" ? " " : cell.character)
            }
        }
        return (text, index)
    }

    // MARK: - The token under the click

    private static let openers: Set<Character> = ["(", "[", "{", "<", "\"", "'", "`"]
    private static let closers: Set<Character> = [")", "]", "}", ">", "\"", "'", "`",
                                                  ",", ".", ";", ":", "!", "?"]

    /// The path or URL containing `text[index]`, or nil when the click is on
    /// whitespace or on a word that is neither.
    public static func link(in text: [Character], at index: Int) -> DetectedLink? {
        guard text.indices.contains(index), !text[index].isWhitespace else { return nil }
        var lower = index
        while lower > 0, !text[lower - 1].isWhitespace { lower -= 1 }
        var upper = index
        while upper + 1 < text.count, !text[upper + 1].isWhitespace { upper += 1 }
        var token = Array(text[lower...upper])

        while let first = token.first, openers.contains(first) { token.removeFirst() }
        while let last = token.last, closers.contains(last) {
            // Keep a closing bracket the token itself opened, as in
            // https://en.wikipedia.org/wiki/Foo_(bar).
            if let opener = matchingOpener[last],
               token.filter({ $0 == opener }).count >= token.filter({ $0 == last }).count {
                break
            }
            token.removeLast()
        }
        guard !token.isEmpty else { return nil }
        let word = String(token)

        if let url = url(in: word) { return DetectedLink(kind: .url, text: url) }
        return path(in: word)
    }

    private static let matchingOpener: [Character: Character] = [")": "(", "]": "[", "}": "{"]

    private static let schemeURL = try! NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9+.\-]*://\S+"#)
    private static let bareSchemes = ["mailto:", "tel:", "magnet:", "news:"]

    private static func url(in word: String) -> String? {
        let range = NSRange(word.startIndex..., in: word)
        if let match = schemeURL.firstMatch(in: word, range: range),
           let r = Range(match.range, in: word) {
            return String(word[r])
        }
        let lower = word.lowercased()
        if bareSchemes.contains(where: { lower.hasPrefix($0) && word.count > $0.count }) {
            return word
        }
        if lower.hasPrefix("www."), word.count > 4 { return word }
        return nil
    }

    private static let lineSuffix = try! NSRegularExpression(pattern: #"(?::\d+){1,2}$"#)

    private static func path(in word: String) -> DetectedLink? {
        var candidate = Substring(word)
        // "--config=/etc/x" or "path=~/a": the path starts after the "=".
        if let slash = candidate.firstIndex(of: "/"),
           let equals = candidate[..<slash].lastIndex(of: "=") {
            candidate = candidate[candidate.index(after: equals)...]
        }
        var path = String(candidate)
        var suffix: String?
        let range = NSRange(path.startIndex..., in: path)
        if let match = lineSuffix.firstMatch(in: path, range: range),
           let r = Range(match.range, in: path) {
            suffix = String(path[r])
            path = String(path[..<r.lowerBound])
        }
        guard path.contains("/"), path.contains(where: { $0 != "/" }) else { return nil }

        let rooted = path.hasPrefix("/") || path.hasPrefix("~/")
            || path.hasPrefix("./") || path.hasPrefix("../")
        if !rooted {
            // A bare "a/b" is too often prose ("and/or") or a fraction
            // ("3/4"); a relative path needs two slashes or a file extension.
            if path.allSatisfy({ $0.isNumber || $0 == "/" }) { return nil }
            let slashes = path.filter { $0 == "/" }.count
            let last = path.split(separator: "/").last ?? ""
            guard slashes >= 2 || last.dropFirst().contains(".") else { return nil }
        }
        return DetectedLink(kind: .path, text: path, lineSuffix: suffix)
    }
}
