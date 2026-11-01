import Foundation

/// What opening a damaged KDBX file changed. Names fields, never their values.
public struct KDBXRecovery: Equatable, Sendable {
    public struct Location: Equatable, Hashable, Sendable {
        public var entryTitle: String
        public var fieldKey: String
        public var inHistory: Bool

        public init(entryTitle: String, fieldKey: String, inHistory: Bool) {
            self.entryTitle = entryTitle
            self.fieldKey = fieldKey
            self.inHistory = inHistory
        }
    }

    public var escapedCharacters = 0
    public var removedCharacters = 0
    public var removedRepeats = 0
    /// Replaying the old writer on the repaired text gives back the damaged bytes. Strong evidence, not proof:
    /// the old writer could map two different texts to the same bytes.
    public var repairedFields: [Location] = []
    /// Readable again, but the replay did not give back the damaged bytes.
    public var uncertainFields: [Location] = []
    /// Text that still looks like XML markup. It may be genuine.
    public var suspectFields: [Location] = []
    /// Protected values that are not valid UTF-8, which is what a shifted decryption stream produces.
    public var unreadableProtectedFields: [Location] = []
    /// Repaired text outside entry fields, such as group notes or metadata.
    public var otherRepairedTexts = 0

    /// For the person who opened the file. Lives in memory only: titles and field names never go to disk.
    public var summary: String {
        var sections: [String] = []
        if !unreadableProtectedFields.isEmpty {
            sections.append("These protected fields look wrong. Restore them from an older copy:\n" + Self.list(unreadableProtectedFields))
        }
        if !uncertainFields.isEmpty {
            sections.append("Compare these with an older copy, the text may differ:\n" + Self.list(uncertainFields))
        }
        if !repairedFields.isEmpty {
            sections.append("Repaired text:\n" + Self.list(repairedFields))
        }
        if otherRepairedTexts > 0 {
            sections.append("Also repaired \(otherRepairedTexts) text value(s) in group notes or metadata.")
        }
        if !suspectFields.isEmpty {
            sections.append("Text that still contains markup like &amp; or &#13; (it may be genuine):\n" + Self.list(suspectFields))
        }
        return sections.joined(separator: "\n\n")
    }

    private static func list(_ locations: [Location]) -> String {
        let limit = 15
        var lines = locations.prefix(limit).map { "\($0.entryTitle) / \($0.fieldKey)\($0.inHistory ? " (history)" : "")" }
        if locations.count > limit { lines.append("and \(locations.count - limit) more") }
        return lines.joined(separator: "\n")
    }
}

/// Reverses what the old writer did to text holding a `#` or `&#13;` together with a named reference
/// (XMLDocument with `.nodePreserveCharacterReferences`). It runs only after the password and every HMAC block
/// checked out and the XML parser refused the plaintext, so it never guesses at encrypted bytes.
///
/// The old writer did this to such a text node:
/// - A named reference after a `#` was written as `&`, the source text from that `#` on, then the reference:
///   `a#b&amp;c` became `a#b&#b&amp;c`. This is the `CharRef: invalid decimal value` failure.
/// - Named references with no `#` before them could be written decoded: `A&amp;B&#13;C` became `A&B&#13;C`.
/// - A whitespace-only run after `&#13;` moved to the end of the text.
enum KDBXXMLRepair {
    struct Result {
        var xml: Data
        var recovery: KDBXRecovery
        /// Decoded text of each leaf the repair changed, for locating it in the parsed document.
        var changedTexts: Set<String>
        /// The subset of `changedTexts` the replay could not prove.
        var uncertainTexts: Set<String>
    }

    /// The parse options the old writer used. Kept only to replay it and prove a repair.
    static let legacyXMLOptions: XMLNode.Options = [.nodePreserveAll, .nodeLoadExternalEntitiesNever]

    /// Elements that hold only text. Everything up to the matching close tag is content, even a raw `<`.
    private static let textElements: Set<String> = [
        "Value", "Key", "Name", "Notes", "Tags", "DatabaseName", "DatabaseDescription", "DefaultUserName",
        "Window", "KeystrokeSequence", "Sequence", "DefaultSequence", "DefaultAutoTypeSequence",
        "ForegroundColor", "BackgroundColor", "OverrideURL", "Color", "Generator"
    ]

    static func repair(_ xml: Data) -> Result {
        let bytes = [UInt8](xml)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count + 256)
        var recovery = KDBXRecovery()
        var changedTexts = Set<String>()
        var uncertainTexts = Set<String>()
        func repairInto(_ inner: [UInt8]) {
            let repaired = repairedText(inner, recovery: &recovery)
            output += repaired
            guard repaired != inner, let text = decodedText(repaired) else { return }
            changedTexts.insert(text)
            if !replaysToDamage(repaired, damaged: inner) {
                uncertainTexts.insert(text)
            }
        }
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte != ascii("<") {
                let end = bytes[index...].firstIndex(of: ascii("<")) ?? bytes.count
                repairInto(Array(bytes[index..<end]))
                index = end
                continue
            }
            if let end = skippedMarkupEnd(bytes, from: index) {
                output += bytes[index..<end]
                index = end
                continue
            }
            guard let tag = openTag(bytes, at: index) else {
                let end = tagEnd(bytes, from: index) ?? bytes.count
                output += bytes[index..<end]
                index = end
                continue
            }
            output += bytes[index..<tag.end]
            index = tag.end
            guard textElements.contains(tag.name), !tag.selfClosing,
                  let close = matchingClose(of: tag.name, in: bytes, from: index) else { continue }
            let inner = Array(bytes[index..<close])
            if tag.protected || contains(Array("<![CDATA[".utf8), in: inner) {
                output += inner
            } else {
                repairInto(inner)
            }
            index = close
        }
        return Result(xml: Data(output), recovery: recovery, changedTexts: changedTexts, uncertainTexts: uncertainTexts)
    }

    /// A CRLF note with a blank line reads `&#13;\n&#13;\n` in the source. The old writer moved those whitespace runs
    /// to the end of the text. Two texts can damage to the same bytes here. CRLF is what KeePassXC writes, so it wins.
    private static func repairedText(_ inner: [UInt8], recovery: inout KDBXRecovery) -> [UInt8] {
        let repaired = repairText(inner, recovery: &recovery)
        if let blankLines = restoringBlankLines(repaired), replaysToDamage(blankLines, damaged: inner) {
            return blankLines
        }
        return repaired
    }

    private static func restoringBlankLines(_ text: [UInt8]) -> [UInt8]? {
        let reference = Array("&#13;".utf8)
        var positions: [Int] = []
        var index = 0
        while let found = find(reference, in: text, from: index) {
            let next = found + reference.count
            if next + reference.count <= text.count, Array(text[next..<(next + reference.count)]) == reference {
                positions.append(next)
            }
            index = next
        }
        guard !positions.isEmpty else { return nil }
        let trailing = text.reversed().prefix { $0 == ascii("\n") }.count
        guard trailing >= positions.count else { return nil }
        var result = Array(text.dropLast(positions.count))
        for position in positions.reversed() {
            result.insert(ascii("\n"), at: position)
        }
        return result
    }

    // MARK: Text

    /// Walks the damaged text left to right, rebuilding the source. `rebuilt` always parses: every `&` it keeps
    /// starts a valid reference, and every other `&`, `<`, and `>` is escaped.
    static func repairText(_ text: [UInt8], recovery: inout KDBXRecovery) -> [UInt8] {
        var rebuilt: [UInt8] = []
        rebuilt.reserveCapacity(text.count)
        var movedWhitespace: [UInt8] = []
        var index = 0
        while index < text.count {
            let byte = text[index]
            switch byte {
            case ascii("&"):
                if let repeated = repeatedSource(in: text, at: index, rebuilt: rebuilt) {
                    rebuilt += repeated.kept
                    movedWhitespace += repeated.whitespace
                    index = repeated.end
                    recovery.removedRepeats += 1
                    continue
                }
                if let reference = reference(in: text, at: index) {
                    rebuilt += text[index..<(index + reference.length)]
                    index += reference.length
                    continue
                }
                rebuilt += Array("&amp;".utf8)
                recovery.escapedCharacters += 1
            case ascii("<"):
                rebuilt += Array("&lt;".utf8)
                recovery.escapedCharacters += 1
            case ascii(">"):
                rebuilt += Array("&gt;".utf8)
            default:
                if let length = invalidCharacterLength(text, at: index) {
                    index += length
                    recovery.removedCharacters += 1
                    continue
                }
                rebuilt.append(byte)
            }
            index += 1
        }
        if !movedWhitespace.isEmpty, rebuilt.suffix(movedWhitespace.count).elementsEqual(movedWhitespace) {
            rebuilt.removeLast(movedWhitespace.count)
        }
        return rebuilt
    }

    /// Matches `&`, the source text from the last `#` on, then the reference it stood in front of.
    private static func repeatedSource(
        in text: [UInt8],
        at index: Int,
        rebuilt: [UInt8]
    ) -> (kept: [UInt8], whitespace: [UInt8], end: Int)? {
        guard let hash = rebuilt.lastIndex(of: ascii("#")) else { return nil }
        let tail = rebuilt[hash...]
        let tailEnd = index + 1 + tail.count
        guard tailEnd < text.count, text[(index + 1)..<tailEnd].elementsEqual(tail) else { return nil }
        var named = tailEnd
        while named < text.count, [ascii(" "), ascii("\n"), ascii("\t")].contains(text[named]) {
            named += 1
        }
        guard named < text.count, text[named] == ascii("&"),
              let found = reference(in: text, at: named), !found.isCharacter else { return nil }
        let whitespace = Array(text[tailEnd..<named])
        return (whitespace + Array(text[named..<(named + found.length)]), whitespace, named + found.length)
    }

    /// Runs the old parse-and-write on the repaired text. Equal bytes prove the repair found the source.
    private static func replaysToDamage(_ repaired: [UInt8], damaged: [UInt8]) -> Bool {
        var ignored = KDBXRecovery()
        let expected = stripInvalidCharacters(damaged, recovery: &ignored)
        let wrapped = Data("<V>".utf8) + Data(repaired) + Data("</V>".utf8)
        guard let document = try? XMLDocument(data: wrapped, options: legacyXMLOptions) else { return false }
        let written = [UInt8](document.xmlData(options: .nodePreserveAll))
        guard let open = find(Array("<V>".utf8), in: written, from: 0),
              let close = find(Array("</V>".utf8), in: written, from: open) else { return false }
        return Array(written[(open + 3)..<close]) == expected
    }

    private static func stripInvalidCharacters(_ text: [UInt8], recovery: inout KDBXRecovery) -> [UInt8] {
        var output: [UInt8] = []
        var index = 0
        while index < text.count {
            if let length = invalidCharacterLength(text, at: index) {
                index += length
                recovery.removedCharacters += 1
                continue
            }
            output.append(text[index])
            index += 1
        }
        return output
    }

    private struct Reference {
        var length: Int
        var isCharacter: Bool
    }

    /// A reference XML accepts, or nil for a bare `&`.
    private static func reference(in text: [UInt8], at index: Int) -> Reference? {
        guard let semicolon = text[index...].prefix(12).firstIndex(of: ascii(";")) else { return nil }
        let name = String(decoding: text[(index + 1)..<semicolon], as: UTF8.self)
        let length = semicolon - index + 1
        if ["amp", "lt", "gt", "quot", "apos"].contains(name) {
            return Reference(length: length, isCharacter: false)
        }
        guard name.hasPrefix("#") else { return nil }
        let digits = name.dropFirst()
        let value: UInt32?
        if digits.hasPrefix("x") {
            value = digits.count > 1 ? UInt32(digits.dropFirst(), radix: 16) : nil
        } else {
            value = digits.allSatisfy(\.isNumber) ? UInt32(digits) : nil
        }
        guard let value, isValidXMLScalar(value) else { return nil }
        return Reference(length: length, isCharacter: true)
    }

    private static func invalidCharacterLength(_ text: [UInt8], at index: Int) -> Int? {
        let byte = text[index]
        if byte < 0x20 {
            return [0x09, 0x0A, 0x0D].contains(byte) ? nil : 1
        }
        // U+FFFE and U+FFFF, the only UTF-8 three-byte forms XML rejects outside surrogates.
        if byte == 0xEF, index + 2 < text.count, text[index + 1] == 0xBF, text[index + 2] == 0xBE || text[index + 2] == 0xBF {
            return 3
        }
        return nil
    }

    private static func decodedText(_ inner: [UInt8]) -> String? {
        let wrapped = Data("<V>".utf8) + Data(inner) + Data("</V>".utf8)
        return (try? parseKDBXDocument(wrapped))?.rootElement()?.stringValue
    }

    // MARK: Markup

    private struct OpenTag {
        var name: String
        var end: Int
        var selfClosing: Bool
        var protected: Bool
    }

    private static func openTag(_ bytes: [UInt8], at index: Int) -> OpenTag? {
        guard index + 1 < bytes.count, bytes[index + 1] != ascii("/"), let end = tagEnd(bytes, from: index) else { return nil }
        var nameEnd = index + 1
        while nameEnd < end, ![ascii(" "), ascii("\t"), ascii("\n"), ascii("\r"), ascii("/"), ascii(">")].contains(bytes[nameEnd]) {
            nameEnd += 1
        }
        let attributes = String(decoding: bytes[nameEnd..<end], as: UTF8.self).lowercased()
        return OpenTag(
            name: String(decoding: bytes[(index + 1)..<nameEnd], as: UTF8.self),
            end: end,
            selfClosing: bytes[end - 2] == ascii("/"),
            protected: attributes.replacingOccurrences(of: " ", with: "").contains("protected=\"true\"")
                || attributes.replacingOccurrences(of: " ", with: "").contains("protected='true'")
        )
    }

    /// The index just past the `>` that closes a tag, ignoring any `>` inside a quoted attribute.
    private static func tagEnd(_ bytes: [UInt8], from index: Int) -> Int? {
        var quote: UInt8?
        var position = index + 1
        while position < bytes.count {
            let byte = bytes[position]
            if let open = quote {
                if byte == open { quote = nil }
            } else if byte == ascii("\"") || byte == ascii("'") {
                quote = byte
            } else if byte == ascii(">") {
                return position + 1
            }
            position += 1
        }
        return nil
    }

    /// The close tag that balances any same-named tags inside. A note quoting `<Value>…</Value>` is one text.
    private static func matchingClose(of name: String, in bytes: [UInt8], from start: Int) -> Int? {
        let opening = Array("<\(name)".utf8)
        let closing = Array("</\(name)".utf8)
        guard let first = find(closing, in: bytes, from: start) else { return nil }
        var depth = 1
        var close = first
        var scan = start
        while true {
            while let open = find(opening, in: bytes, from: scan), open < close {
                scan = open + opening.count
                guard scan < bytes.count, [ascii(" "), ascii(">"), ascii("\t"), ascii("\n"), ascii("/")].contains(bytes[scan]) else { continue }
                if let end = tagEnd(bytes, from: open), bytes[end - 2] != ascii("/") {
                    depth += 1
                }
            }
            depth -= 1
            if depth == 0 { return close }
            guard let next = find(closing, in: bytes, from: close + closing.count) else { return first }
            close = next
        }
    }

    private static func skippedMarkupEnd(_ bytes: [UInt8], from index: Int) -> Int? {
        for (open, close) in [("<!--", "-->"), ("<![CDATA[", "]]>"), ("<?", "?>"), ("<!", ">")] {
            let opening = Array(open.utf8)
            guard index + opening.count <= bytes.count, Array(bytes[index..<(index + opening.count)]) == opening else { continue }
            let closing = Array(close.utf8)
            guard let found = find(closing, in: bytes, from: index + opening.count) else { return bytes.count }
            return found + closing.count
        }
        return nil
    }

    private static func find(_ needle: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard !needle.isEmpty, bytes.count >= needle.count, start <= bytes.count - needle.count else { return nil }
        var index = start
        let last = bytes.count - needle.count
        while index <= last {
            if bytes[index] == needle[0], Array(bytes[index..<(index + needle.count)]) == needle { return index }
            index += 1
        }
        return nil
    }

    private static func contains(_ needle: [UInt8], in bytes: [UInt8]) -> Bool {
        find(needle, in: bytes, from: 0) != nil
    }
}

private func ascii(_ character: Unicode.Scalar) -> UInt8 {
    UInt8(ascii: character)
}

// MARK: XML character rules

/// The XML 1.0 `Char` production.
func isValidXMLScalar(_ value: UInt32) -> Bool {
    switch value {
    case 0x09, 0x0A, 0x0D, 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF: return true
    default: return false
    }
}

/// XML cannot carry these at all. KeePassXC drops them on write too (`stripInvalidXml10Chars`).
func removingInvalidXMLCharacters(_ text: String) -> String {
    guard text.unicodeScalars.contains(where: { !isValidXMLScalar($0.value) }) else { return text }
    var scalars = String.UnicodeScalarView()
    scalars.append(contentsOf: text.unicodeScalars.filter { isValidXMLScalar($0.value) })
    return String(scalars)
}

/// A raw CR reads back as LF, because XML normalizes line ends. KeePassXC writes `&#13;`, so this does too.
/// Only text is rewritten: XMLDocument can keep a raw CR inside a tag (`<Value\r/>`), where a reference is illegal.
func escapingCarriageReturns(_ xml: Data) -> Data {
    guard xml.contains(0x0D) else { return xml }
    var output = Data(capacity: xml.count + 64)
    var insideTag = false
    for byte in xml {
        if byte == UInt8(ascii: "<") {
            insideTag = true
        } else if byte == UInt8(ascii: ">") {
            insideTag = false
        }
        if byte == 0x0D, !insideTag {
            output.append(contentsOf: Array("&#13;".utf8))
        } else {
            output.append(byte)
        }
    }
    return output
}

/// XML parsing drops a text node of only whitespace, so a save stores it as empty and the model agrees.
func storedXMLText(_ text: String) -> String {
    let cleaned = removingInvalidXMLCharacters(text)
    let onlyWhitespace = cleaned.unicodeScalars.allSatisfy { [0x20, 0x09, 0x0A, 0x0D].contains($0.value) }
    return onlyWhitespace ? "" : cleaned
}
