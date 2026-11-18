import Foundation
import PasswordPieBridge

// What the `passwordpie` command-line tool and the app say to each other over `agent.sock`. The transport is the browser
// bridge's (framing, peer check); the messages are their own. See docs/AGENTS.md, "Messages".
// Nothing here is a credential: a request carries references and a command line, never a value, and never a claim about
// who the agent is or which project it is in. The app works those out itself from the peer.

public enum AgentConstants {
    public static let socketName = "agent.sock"
    /// The command-line tool's signing identifier. The app's agent socket serves only this, signed by our team.
    public static let cliIdentifier = "com.passwordpie.cli"
    /// The name the tool is installed under, inside the app and on the PATH.
    public static let toolName = "passwordpie"
    /// Where the tool sits in the bundle. Not `Contents/MacOS`: on a case-insensitive volume `passwordpie` would be the
    /// app's own `PasswordPie` executable.
    public static let toolPathInBundle = "Contents/Helpers/passwordpie"
    public static let protocolVersion = 1
    /// How long a request waits for the owner to unlock, by default and at most (`--wait`).
    public static let defaultWaitSeconds = 60
    public static let maxWaitSeconds = 600
    /// How long the approval window waits before answering `timeout`.
    public static let approvalSeconds: TimeInterval = 120
    /// Values shorter than this are not masked in a command's output: they would match too much ordinary text.
    public static let minimumMaskedLength = 6
    public static let concealed = "[concealed by PasswordPie]"
    /// The last words of every refusal. An agent that is stuck otherwise asks the owner to paste the secret into the chat.
    public static let pasteWarning = "Do not ask the owner to paste the value into the conversation."
    /// The preference that turns agent access on. Off unless the owner turns it on in Preferences > Agents.
    public static let enabledKey = "agentAccessEnabled"

    /// `~/Library/Group Containers/<group>/agent.sock`, beside the browser's `bridge.sock`.
    public static func defaultSocketPath() throws -> String {
        let bridge = try BridgeSocket.defaultPath()
        return (bridge as NSString).deletingLastPathComponent + "/" + socketName
    }
}

/// How a value reaches the command, or the agent.
public enum AgentDelivery: String, Codable, Sendable, CaseIterable {
    /// An environment variable of the command.
    case env
    /// A short-lived file; the environment variable holds its path.
    case file
    /// The command's standard input, written then closed.
    case stdin
    /// The value itself, to the agent (`passwordpie read`, or a run with masking off). Asks every time.
    case shown
    /// Filled into the item's sign-in form in the owner's browser (`passwordpie login`). The agent gets no value.
    case fill
}

public enum AgentRequestKind: String, Codable, Sendable {
    case hello
    /// Run a command with values (`passwordpie run`).
    case use
    /// One raw value (`passwordpie read`).
    case read
    case list
    case status
    /// Log in on a website in the owner's browser (`passwordpie login`): the extension fills the form.
    case login
}

public struct AgentSecretRequest: Codable, Equatable, Sendable {
    /// The environment variable, for `env` and `file`.
    public var name: String?
    public var ref: String
    public var delivery: AgentDelivery

    public init(name: String?, ref: String, delivery: AgentDelivery) {
        self.name = name
        self.ref = ref
        self.delivery = delivery
    }

    enum CodingKeys: String, CodingKey {
        case name, ref
        case delivery = "as"
    }
}

public struct AgentRequest: Codable, Equatable, Sendable {
    public var type: AgentRequestKind
    public var id: Int
    public var version: Int?
    public var client: String?
    public var cliVersion: String?
    public var secrets: [AgentSecretRequest]?
    /// The resolved path of what the command runs, and the command as typed. Shown in the prompt, never trusted.
    public var program: String?
    public var argv: [String]?
    /// The agent's own words. Shown as its claim.
    public var reason: String?
    /// False for `run --no-masking`, which is then a raw read.
    public var masking: Bool?
    /// Seconds to wait for an unlock.
    public var wait: Int?
    public var query: String?
    /// `login`: the page to log in on. Without a reference, the shared items for its site are offered.
    public var url: String?
    /// `login`: press the form's own button after filling it.
    public var submit: Bool?
    /// `login`: `chrome` or `safari`. Without it, the app picks the browser whose extension is connected.
    public var browser: String?

    public init(type: AgentRequestKind, id: Int) {
        self.type = type
        self.id = id
    }

    /// True when the agent can end up with the value itself: it asks every time, with the "shown to the agent" wording.
    public var isRaw: Bool {
        type == .read || masking == false || (secrets ?? []).contains { $0.delivery == .shown }
    }
}

/// One value in an answer. `value` is UTF-8 text; a value that is not (an attachment) comes as `base64`.
public struct AgentSecretValue: Codable, Equatable, Sendable {
    public var name: String?
    public var ref: String
    public var value: String?
    public var base64: String?
    /// The owner unticked this one in the prompt: it is not delivered.
    public var declined: Bool?

    public init(name: String?, ref: String, bytes: Data?) {
        self.name = name
        self.ref = ref
        if let bytes {
            if let text = String(data: bytes, encoding: .utf8), Data(text.utf8) == bytes {
                value = text
            } else {
                base64 = bytes.base64EncodedString()
            }
        } else {
            declined = true
        }
    }

    public var bytes: Data? {
        if let value { return Data(value.utf8) }
        if let base64 { return Data(base64Encoded: base64) }
        return nil
    }
}

/// One shared item in a `list` answer. Never a value.
public struct AgentListedItem: Codable, Equatable, Sendable {
    public var ref: String
    public var idRef: String
    public var title: String
    public var folder: String
    public var fields: [String]
    public var attachments: [String]
    /// A standing permission covers this agent and project for it.
    public var covered: Bool

    public init(ref: String, idRef: String, title: String, folder: String, fields: [String], attachments: [String], covered: Bool) {
        self.ref = ref
        self.idRef = idRef
        self.title = title
        self.folder = folder
        self.fields = fields
        self.attachments = attachments
        self.covered = covered
    }
}

public struct AgentStatusInfo: Codable, Equatable, Sendable {
    public var locked: Bool
    public var access: Bool
    public var agent: String
    public var project: String
    /// The standing permissions that apply to this agent and project, described.
    public var grants: [String]

    public init(locked: Bool, access: Bool, agent: String, project: String, grants: [String]) {
        self.locked = locked
        self.access = access
        self.agent = agent
        self.project = project
        self.grants = grants
    }
}

public struct AgentResponse: Codable, Equatable, Sendable {
    /// The request's type, or "error".
    public var type: String
    public var id: Int
    public var version: Int?
    public var locked: Bool?
    public var access: Bool?
    public var secrets: [AgentSecretValue]?
    /// How a `use` or `read` was allowed: "once", or a standing permission's description.
    public var by: String?
    public var items: [AgentListedItem]?
    public var status: AgentStatusInfo?
    /// For an error: its name (`AgentErrorCode`).
    public var code: String?
    /// For an error: the reference it is about, as the agent typed it.
    public var ref: String?
    /// For `ambiguous`: the `pp://id/` references of the matching shared items.
    public var refs: [String]?
    /// For `usage`: what was wrong, when the app found it.
    public var detail: String?
    /// For `login`: how it went, and the item's overview. Never a value.
    public var login: AgentLoginAnswer?

    public init(type: String, id: Int) {
        self.type = type
        self.id = id
    }

    public static func error(_ code: AgentErrorCode, id: Int, ref: String? = nil, refs: [String]? = nil) -> AgentResponse {
        var response = AgentResponse(type: "error", id: id)
        response.code = code.rawValue
        response.ref = ref
        response.refs = refs
        return response
    }

    public var errorCode: AgentErrorCode? {
        guard type == "error" else { return nil }
        return code.flatMap(AgentErrorCode.init(rawValue:)) ?? .appUnavailable
    }
}

public enum AgentCoding {
    public static func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data("{}".utf8)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}
