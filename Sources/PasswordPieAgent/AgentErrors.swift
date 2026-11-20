import Foundation

/// PasswordPie's own exit codes, so a script and an agent can tell the answers apart. A `run` whose command started exits
/// with the command's code instead. See docs/AGENTS.md, "Exit codes".
public enum AgentErrorCode: String, Codable, Sendable, CaseIterable {
    case usage = "usage"
    case notAvailable = "not-available"
    case ambiguous = "ambiguous"
    case denied = "denied"
    case timeout = "timeout"
    case locked = "locked"
    case appUnavailable = "app-unavailable"
    case accessOff = "access-off"
    case tooManyRequests = "too-many-requests"
    case premiumRequired = "premium-required"
    /// `save`: nobody saved or rejected it yet. An answer, not a refusal: the proposal waits.
    case pending = "pending"

    public var exitCode: Int32 {
        switch self {
        case .usage: return 64
        case .notAvailable: return 65
        case .ambiguous: return 66
        case .denied: return 67
        case .timeout: return 68
        case .locked: return 69
        case .appUnavailable: return 70
        case .accessOff: return 71
        case .tooManyRequests: return 72
        case .premiumRequired: return 73
        case .pending: return AgentConstants.pendingExitCode
        }
    }
}

/// The one line a refusal prints on standard error, for the agent to relay. Each says what to do next and ends with
/// `AgentConstants.pasteWarning`. Built from the code and what the agent itself sent, so an item that is not shared and
/// one that does not exist read the same, byte for byte.
public enum AgentRefusal {
    public static func line(_ code: AgentErrorCode, ref: String? = nil, refs: [String] = [], detail: String? = nil) -> String {
        "PasswordPie: " + oneLine(sentence(code, ref: ref, refs: refs, detail: detail, mcp: false)) + " " + AgentConstants.pasteWarning
    }

    /// The text of an MCP tool error: it starts with the code's name, as the command-line tool's exit codes are named, then
    /// says what to do in the MCP tools' terms, and ends with `AgentConstants.mcpGuidance`.
    public static func mcp(_ code: AgentErrorCode, ref: String? = nil, refs: [String] = [], detail: String? = nil) -> String {
        "\(code.rawValue): PasswordPie: " + oneLine(sentence(code, ref: ref, refs: refs, detail: detail, mcp: true)) + " " + AgentConstants.mcpGuidance
    }

    /// What the agent typed can hold line breaks and other control characters: percent-encoded, so the line stays one.
    static func oneLine(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            if scalar.properties.generalCategory == .control {
                for byte in String(scalar).utf8 { out += String(format: "%%%02X", byte) }
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private static func sentence(_ code: AgentErrorCode, ref: String?, refs: [String], detail: String?, mcp: Bool) -> String {
        switch code {
        case .usage:
            return (detail ?? "The command was not understood.") + (mcp ? " Check the tool's input schema." : " Run `passwordpie help` for the syntax.")
        case .notAvailable:
            let what = ref.map { "Nothing shared with agents matches \($0)." } ?? "Nothing shared with agents matches that reference."
            let check = mcp ? "Check the name with passwordpie_list" : "Check the name with `passwordpie list`"
            return what + " \(check); if the item exists, ask the owner to choose Share with Agents on it (or its folder) in PasswordPie."
        case .ambiguous:
            let list = refs.isEmpty ? "" : " Matching items: " + refs.joined(separator: ", ") + "."
            return "More than one shared item matches \(ref ?? "that reference")." + list + " Use one of the pp://id/ references instead."
        case .denied:
            return "The owner denied this request. Do not ask again for the same thing unless the owner tells you to."
        case .timeout:
            return "Nobody answered the approval prompt in 2 minutes. Tell the owner a PasswordPie approval is waiting, then try again."
        case .locked:
            if let detail { return "PasswordPie is locked. " + detail + " Tell the owner to unlock it, then try again." }
            return mcp
                ? "PasswordPie is locked. Tell the owner to unlock it, then try again."
                : "PasswordPie is locked. Tell the owner to unlock it, then try again (or use --wait SECONDS, up to 600)."
        case .appUnavailable:
            return (detail ?? "PasswordPie did not answer.") + " Make sure PasswordPie (the direct download from passwordpie.com) is installed and running."
        case .accessOff:
            return "Agent access is off. Ask the owner to turn it on in PasswordPie > Preferences > Agents."
        case .tooManyRequests:
            return "Too many requests from this agent session were denied. Wait 10 minutes before asking again, and tell the owner why you need the secret."
        case .premiumRequired:
            return "This needs PasswordPie Premium. Ask the owner; Allow Once still works without it."
        case .pending:
            let status = mcp ? "passwordpie_status" : "`passwordpie status`"
            return (detail ?? "The save waits for the owner.") + " PasswordPie keeps the value until the owner saves or rejects it in Preferences > Agents; you do not need a copy, and cannot use it before then. \(status) shows whether it was saved."
        }
    }
}
