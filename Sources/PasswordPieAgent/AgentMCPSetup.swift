import Foundation

/// The configuration lines the Agents pane shows for adding `passwordpie mcp` to an agent. The owner copies them; the app
/// never edits another program's configuration. See docs/AGENTS.md, "MCP server".
public enum AgentMCPSetup {
    public struct Host: Equatable, Sendable, Identifiable {
        public var name: String
        /// Where the text goes: "In Terminal", or the configuration file.
        public var place: String
        public var text: String

        public var id: String { name }
    }

    /// The server's name in each agent's configuration.
    public static let serverName = "passwordpie"

    /// `tool` is the absolute path of the `passwordpie` binary.
    public static func hosts(tool: String) -> [Host] {
        let quoted = shellQuoted(tool)
        return [
            Host(
                name: "Claude Code",
                place: "In Terminal",
                text: "claude mcp add --scope user \(serverName) -- \(quoted) mcp"
            ),
            Host(
                name: "Codex",
                place: "In ~/.codex/config.toml",
                text: "[mcp_servers.\(serverName)]\ncommand = \(tomlString(tool))\nargs = [\"mcp\"]"
            ),
            Host(
                name: "Cursor",
                place: "In ~/.cursor/mcp.json, inside \"mcpServers\"",
                text: "\"\(serverName)\": { \"command\": \(jsonString(tool)), \"args\": [\"mcp\"] }"
            ),
        ]
    }

    /// A path as a shell word: as it is when it is plain, else in single quotes.
    public static func shellQuoted(_ text: String) -> String {
        let plain = !text.isEmpty && text.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-_./=:@%+,".unicodeScalars.contains($0)
        }
        return plain ? text : "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func jsonString(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        return String(decoding: data.dropFirst().dropLast(), as: UTF8.self)
    }

    /// A TOML basic string; the escapes are JSON's.
    static func tomlString(_ text: String) -> String { jsonString(text) }
}
