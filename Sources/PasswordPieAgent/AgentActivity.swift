import Darwin
import Foundation

/// What became of a request, as Activity shows it.
public enum AgentOutcome: String, Codable, Sendable {
    case allowedOnce = "allowed once"
    case allowedByGrant = "allowed by grant"
    case shown = "shown to the agent"
    case listed = "listed"
    case denied = "denied"
    case timedOut = "timed out"
    case locked = "locked"
    case notAvailable = "not available"
    case ambiguous = "ambiguous"
    case tooManyRequests = "too many requests"
    case usage = "not understood"
    /// Agent access was turned off while the request waited.
    case accessOff = "agent access turned off"
    // `login`, each after the owner allowed it once (or before the prompt, for a site or tab that does not match).
    case filled = "filled"
    case submitted = "filled and sent"
    case noMatchingTab = "no matching tab"
    case siteMismatch = "site mismatch"
    case fillTimedOut = "no tab took the fill"
    case noFields = "no sign-in fields"
}

/// One line of the activity log. It holds no value, ever: names of items and fields, the command, the agent and its
/// process chain. See docs/AGENTS.md, "Activity".
public struct AgentActivityRecord: Codable, Equatable, Sendable {
    public struct Link: Codable, Equatable, Sendable {
        public var pid: Int32
        public var path: String
        public var signature: String

        public init(_ process: AgentProcess) {
            pid = process.pid
            path = process.path
            signature = process.signatureText
        }
    }

    public var time: Date
    /// `run`, `read`, `list` or `login`.
    public var kind: String
    public var outcome: AgentOutcome
    /// The standing permission that allowed it, described.
    public var grant: String?
    public var agent: String
    public var signature: String
    public var pid: Int32?
    public var project: String
    public var command: String?
    /// "Developer/App Store Connect API key › attachment AuthKey_ABC123.p8"; for a reference that found nothing, the
    /// reference as the agent typed it.
    public var items: [String]
    /// "env NOTARY_KEY_ID", "file NOTARY_KEY", "stdin", "shown", "fill Google Chrome github.com".
    public var delivery: [String]
    /// The agent's own words, kept as its claim.
    public var reason: String?
    /// The walked chain, nearest parent first.
    public var chain: [Link]

    public init(
        time: Date, kind: String, outcome: AgentOutcome, grant: String? = nil, caller: AgentCaller?, command: String?,
        items: [String], delivery: [String], reason: String?
    ) {
        self.time = time
        self.kind = kind
        self.outcome = outcome
        self.grant = grant
        agent = caller?.agentName ?? "unknown"
        signature = caller?.signatureText ?? ""
        pid = caller?.agent?.pid
        project = caller?.project ?? ""
        self.command = command
        self.items = items
        self.delivery = delivery
        self.reason = reason
        chain = caller?.chain.map(Link.init) ?? []
    }

    /// "allowed once", "allowed by 7 days, this project", "denied".
    public var outcomeText: String {
        if outcome == .allowedByGrant, let grant { return "allowed by \(grant)" }
        return outcome.rawValue
    }
}

public protocol AgentActivityLogging: AnyObject {
    func append(_ record: AgentActivityRecord)
}

/// The log file: one JSON object per line, mode 0600, in the app's Application Support folder. Lines older than 90 days
/// are dropped. Not tamper-proof: same-user code can edit or delete it. It is a record for the owner.
public final class AgentActivityLog: AgentActivityLogging, @unchecked Sendable {
    public static let keepDays = 90

    public let url: URL
    private let lock = NSLock()
    private let clock: () -> Date
    private var lastPrune: Date?

    public init(url: URL, clock: @escaping () -> Date = Date.init) {
        self.url = url
        self.clock = clock
    }

    /// `~/Library/Application Support/PasswordPie/agent-activity.jsonl`.
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PasswordPie", isDirectory: true)
            .appendingPathComponent("agent-activity.jsonl")
    }

    public func append(_ record: AgentActivityRecord) {
        lock.lock()
        defer { lock.unlock() }
        pruneIfDue()
        var line = Self.encoder.encode(record)
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        fchmod(fd, 0o600)
        line.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = write(fd, base, raw.count)
        }
    }

    /// Every record still kept, oldest first.
    public func records() -> [AgentActivityRecord] {
        lock.lock()
        defer { lock.unlock() }
        return readRecords()
    }

    private func readRecords() -> [AgentActivityRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? Self.decoder.decode(AgentActivityRecord.self, from: Data($0)) }
    }

    /// At most once an hour: rewrites the file without the lines older than `keepDays`.
    private func pruneIfDue() {
        let now = clock()
        if let lastPrune, now.timeIntervalSince(lastPrune) < 3600 { return }
        lastPrune = now
        let all = readRecords()
        let cutoff = now.addingTimeInterval(-Double(Self.keepDays) * 86_400)
        let kept = all.filter { $0.time >= cutoff }
        guard kept.count < all.count else { return }
        var data = Data()
        for record in kept {
            data.append(Self.encoder.encode(record))
            data.append(0x0A)
        }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(getpid())")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }
        let written = data.withUnsafeBytes { raw in raw.baseAddress.map { write(fd, $0, raw.count) } ?? 0 }
        close(fd)
        if written == data.count {
            rename(temporary.path, url.path)
        } else {
            unlink(temporary.path)
        }
    }

    private static let encoder: LineEncoder = LineEncoder()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private struct LineEncoder {
        func encode(_ record: AgentActivityRecord) -> Data {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return (try? encoder.encode(record)) ?? Data()
        }
    }
}
