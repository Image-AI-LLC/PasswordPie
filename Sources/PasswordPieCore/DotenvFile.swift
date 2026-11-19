import Foundation

/// One dotenv file read as a dotenv library reads it: `NAME=value` lines, `#` comments, quotes. See docs/UX.md, "A folder
/// of .env files becomes items". Nothing is expanded: `$OTHER` stays as typed.
public enum DotenvFile {
    public struct Variable: Equatable, Sendable {
        public var name: String
        public var value: String
        /// The line the value starts on, from 1.
        public var line: Int
        /// The value has something in it that a shell running `source` on the file reads differently from a dotenv
        /// library: `$`, a backtick, a backslash, or without quotes a space, a quote or a shell operator.
        public var shellSensitive: Bool

        public init(name: String, value: String, line: Int, shellSensitive: Bool = false) {
            self.name = name
            self.value = value
            self.line = line
            self.shellSensitive = shellSensitive
        }
    }

    public struct Parsed: Equatable, Sendable {
        /// In the order the names first appear. A name set twice has its last value, as every reader gives it.
        public var variables: [Variable] = []
        /// The lines that start with `#`, without it.
        public var comments: [String] = []
        /// Lines that are neither a comment nor `NAME=value`, by number. Nothing is taken from them.
        public var unreadable: [Int] = []
        /// Names set more than once.
        public var repeated: [String] = []
    }

    public static func parse(_ text: String) -> Parsed {
        var reader = Reader(text)
        var parsed = Parsed()
        var order: [String] = []
        var found: [String: Variable] = [:]
        while !reader.atEnd {
            reader.skipBlanks()
            if reader.atEnd { break }
            if reader.takeLineEnd() { continue }
            let line = reader.line
            if reader.peek == "#" {
                reader.advance()
                var comment = reader.restOfLine()
                if comment.hasPrefix(" ") { comment.removeFirst() }
                parsed.comments.append(comment)
                continue
            }
            let lineStart = reader.mark
            guard let variable = reader.assignment() else {
                // Only this line is given up: a quote that never closes, or closes lines later before something that
                // is no comment, does not take the lines after it with it.
                reader.reset(to: lineStart)
                parsed.unreadable.append(line)
                reader.skipLine()
                continue
            }
            if found[variable.name] == nil {
                order.append(variable.name)
            } else if !parsed.repeated.contains(variable.name) {
                parsed.repeated.append(variable.name)
            }
            found[variable.name] = variable
        }
        parsed.variables = order.compactMap { found[$0] }
        return parsed
    }

    /// Letters, digits and `_`, not starting with a digit: what a shell and a process environment both take.
    public static func isVariableName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, isNameStart(first) else { return false }
        return name.unicodeScalars.allSatisfy(isNamePart)
    }

    fileprivate static func isNameStart(_ scalar: Unicode.Scalar) -> Bool {
        (scalar >= "A" && scalar <= "Z") || (scalar >= "a" && scalar <= "z") || scalar == "_"
    }

    fileprivate static func isNamePart(_ scalar: Unicode.Scalar) -> Bool {
        isNameStart(scalar) || (scalar >= "0" && scalar <= "9")
    }
}

/// Walks the file's scalars, counting lines. A `\r\n` is one line end.
private struct Reader {
    private let scalars: [Unicode.Scalar]
    private var index = 0
    private(set) var line = 1

    init(_ text: String) {
        var all = Array(text.unicodeScalars)
        // A byte order mark is not part of the first name.
        if all.first == "\u{FEFF}" { all.removeFirst() }
        scalars = all
    }

    var atEnd: Bool { index >= scalars.count }

    /// Where the reader is, to come back to.
    var mark: (index: Int, line: Int) { (index, line) }

    mutating func reset(to mark: (index: Int, line: Int)) {
        index = mark.index
        line = mark.line
    }
    var peek: Unicode.Scalar? { atEnd ? nil : scalars[index] }

    private var atLineEnd: Bool { atEnd || scalars[index] == "\n" || scalars[index] == "\r" }

    mutating func advance() {
        guard !atEnd else { return }
        if scalars[index] == "\n" { line += 1 }
        index += 1
    }

    mutating func skipBlanks() {
        while let next = peek, next == " " || next == "\t" { advance() }
    }

    /// Consumes one line end, when the reader is on it.
    mutating func takeLineEnd() -> Bool {
        guard let next = peek, next == "\n" || next == "\r" else { return false }
        advance()
        if next == "\r", peek == "\n" { advance() }
        return true
    }

    mutating func restOfLine() -> String {
        var text = String.UnicodeScalarView()
        while !atLineEnd {
            text.append(scalars[index])
            advance()
        }
        _ = takeLineEnd()
        return String(text)
    }

    mutating func skipLine() {
        _ = restOfLine()
    }

    /// `[export ]NAME=value`, with the reader on the first character of the line's text. Nil leaves the reader
    /// wherever it stopped: the caller goes back to the start of the line.
    mutating func assignment() -> DotenvFile.Variable? {
        let start = line
        var name = word()
        if name == "export", let next = peek, next == " " || next == "\t" {
            skipBlanks()
            name = word()
        }
        guard DotenvFile.isVariableName(name) else { return nil }
        skipBlanks()
        guard peek == "=" else { return nil }
        advance()
        let afterEquals = index
        skipBlanks()
        let spaced = index > afterEquals
        var variable = DotenvFile.Variable(name: name, value: "", line: start)
        switch peek {
        case "'":
            guard let raw = quoted("'") else { return nil }
            variable.value = Self.unescape(raw, escapes: ["\\": "\\", "'": "'"])
            variable.shellSensitive = raw.contains("\\")
            guard onlyACommentIsLeft() else { return nil }
        case "\"":
            guard let raw = quoted("\"") else { return nil }
            variable.value = Self.unescape(raw, escapes: Self.doubleQuoteEscapes)
            variable.shellSensitive = raw.contains { "$`\\".contains($0) }
            guard onlyACommentIsLeft() else { return nil }
        default:
            var raw = restOfLine()
            // ` #` starts a comment. A `#` right after the `=` and its spaces is one too, as in a shell.
            if spaced, raw.hasPrefix("#") {
                raw = ""
            } else if let comment = raw.range(of: #"[ \t]+#.*$"#, options: .regularExpression) {
                raw.removeSubrange(comment)
            }
            while let last = raw.unicodeScalars.last, last == " " || last == "\t" { raw.unicodeScalars.removeLast() }
            variable.value = raw
            variable.shellSensitive = raw.contains { " \t$`\\\"';&|<>()".contains($0) }
        }
        return variable
    }

    private mutating func word() -> String {
        var text = String.UnicodeScalarView()
        while let next = peek, DotenvFile.isNamePart(next) {
            text.append(next)
            advance()
        }
        return String(text)
    }

    /// The text between the quote the reader is on and the next one that is not escaped, over as many lines as it
    /// takes. Nil when the quote is never closed.
    private mutating func quoted(_ quote: Unicode.Scalar) -> String? {
        advance()
        var text = String.UnicodeScalarView()
        while let next = peek {
            if next == "\\", index + 1 < scalars.count {
                text.append(next)
                advance()
                text.append(scalars[index])
                advance()
                continue
            }
            if next == quote {
                advance()
                return String(text)
            }
            text.append(next)
            advance()
        }
        return nil
    }

    /// After a quoted value: spaces, then nothing or a comment.
    private mutating func onlyACommentIsLeft() -> Bool {
        skipBlanks()
        if atLineEnd {
            _ = takeLineEnd()
            return true
        }
        guard peek == "#" else { return false }
        skipLine()
        return true
    }

    static let doubleQuoteEscapes: [Unicode.Scalar: Unicode.Scalar] = [
        "\\": "\\", "'": "'", "\"": "\"", "a": "\u{07}", "b": "\u{08}", "f": "\u{0C}", "n": "\n", "r": "\r", "t": "\t", "v": "\u{0B}"
    ]

    /// A backslash before a character in `escapes` stands for what the table says. Any other backslash stays.
    static func unescape(_ raw: String, escapes: [Unicode.Scalar: Unicode.Scalar]) -> String {
        var out = String.UnicodeScalarView()
        var pending = false
        for scalar in raw.unicodeScalars {
            if pending {
                pending = false
                if let replacement = escapes[scalar] {
                    out.append(replacement)
                } else {
                    out.append("\\")
                    out.append(scalar)
                }
            } else if scalar == "\\" {
                pending = true
            } else {
                out.append(scalar)
            }
        }
        if pending { out.append("\\") }
        return String(out)
    }
}
