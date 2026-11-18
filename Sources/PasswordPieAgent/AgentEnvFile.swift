import Foundation

/// `.env.pp`: a project names the secrets it needs, in a file safe to commit. Each line is `NAME=value`:
/// `NAME=pp://…` sets the variable to the value, `NAME=file:pp://…` writes the value to a short-lived file and sets the
/// variable to its path, anything else is set literally. `#` starts a comment. No shell expansion; one pair of surrounding
/// quotes is stripped. See docs/AGENTS.md, ".env.pp".
public enum AgentEnvFile {
    public enum Line: Equatable, Sendable {
        case secret(name: String, ref: String, delivery: AgentDelivery)
        case literal(name: String, value: String)
    }

    public struct Problem: Error, Equatable, CustomStringConvertible {
        public var line: Int
        public var reason: String

        public var description: String { "line \(line): \(reason)" }
    }

    public static func parse(_ text: String) throws -> [Line] {
        var lines: [Line] = []
        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var line = String(rawLine)
            if line.hasSuffix("\r") { line.removeLast() }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            var body = trimmed
            if body.hasPrefix("export ") { body = String(body.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces) }
            guard let equals = body.firstIndex(of: "=") else {
                throw Problem(line: index + 1, reason: "expected NAME=value")
            }
            let name = body[..<equals].trimmingCharacters(in: .whitespaces)
            guard isVariableName(name) else {
                throw Problem(line: index + 1, reason: "\"\(name)\" is not a variable name")
            }
            var value = body[body.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            if value.hasPrefix("file:" + AgentReference.scheme) {
                let ref = String(value.dropFirst("file:".count))
                try check(ref, line: index + 1)
                lines.append(.secret(name: name, ref: ref, delivery: .file))
            } else if value.hasPrefix(AgentReference.scheme) {
                try check(value, line: index + 1)
                lines.append(.secret(name: name, ref: value, delivery: .env))
            } else {
                lines.append(.literal(name: name, value: value))
            }
        }
        return lines
    }

    private static func check(_ ref: String, line: Int) throws {
        do {
            _ = try AgentReference(ref)
        } catch {
            throw Problem(line: line, reason: "\(ref) is not a valid reference")
        }
    }

    /// Letters, digits and `_`, not starting with a digit.
    public static func isVariableName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, !CharacterSet.decimalDigits.contains(first) else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_")
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
