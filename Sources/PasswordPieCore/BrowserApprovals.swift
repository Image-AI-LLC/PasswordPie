import Foundation

// Which browsers built on Chromium the person let connect to PasswordPie. Every such browser runs the same extension and
// starts the same host, so the app asks once per browser and remembers the answer. See docs/UX.md, "Other browsers built
// on Chrome", and docs/BROWSER_EXTENSION.md, "Other Chromium browsers". Holds no URL or credential.

/// A browser's answer, kept for good until the person changes it in Preferences.
public enum BrowserApproval: String, Codable, Sendable {
    case allowed
    case denied
}

/// One browser the person answered about. A browser is its bundle ID together with its signing team: the same bundle ID
/// signed by someone else is another browser, and is asked about again.
public struct BrowserApprovalRecord: Codable, Equatable, Sendable {
    public let bundleID: String
    public let teamID: String
    /// The name to show in Preferences, as the browser called itself when it was answered.
    public var name: String
    public var approval: BrowserApproval
    public var decided: Date

    public init(bundleID: String, teamID: String, name: String, approval: BrowserApproval, decided: Date) {
        self.bundleID = bundleID
        self.teamID = teamID
        self.name = name
        self.approval = approval
        self.decided = decided
    }
}

public struct BrowserApprovals: Codable, Equatable, Sendable {
    /// Google's signing team. Chrome, Chrome Beta, Dev and Canary connect without a question, as Chrome always did.
    public static let googleTeamID = "EQHXZ8M8AV"

    public private(set) var records: [BrowserApprovalRecord] = []

    public init(records: [BrowserApprovalRecord] = []) {
        self.records = records
    }

    /// The answer for a browser: Google's are always allowed; nil means the person has not been asked yet.
    public func approval(bundleID: String, teamID: String) -> BrowserApproval? {
        if teamID == Self.googleTeamID { return .allowed }
        return records.first { $0.bundleID == bundleID && $0.teamID == teamID }?.approval
    }

    /// Keeps the person's answer, replacing an earlier one for the same browser. Google's browsers are not recorded: they
    /// are never asked about.
    public mutating func set(_ approval: BrowserApproval, bundleID: String, teamID: String, name: String, now: Date) {
        guard teamID != Self.googleTeamID else { return }
        if let index = records.firstIndex(where: { $0.bundleID == bundleID && $0.teamID == teamID }) {
            records[index].approval = approval
            records[index].name = name
            records[index].decided = now
        } else {
            records.append(BrowserApprovalRecord(bundleID: bundleID, teamID: teamID, name: name, approval: approval, decided: now))
        }
    }

    /// A browser the person said no to, by bundle ID alone: no "Add Chrome Extension…" line is offered over it.
    public func denied(bundleID: String) -> Bool {
        records.contains { $0.bundleID == bundleID && $0.approval == .denied }
    }

    /// Encoded for the preferences. A value that does not decode reads as no answers at all: every browser but Google's
    /// is asked about again, which never lets one in without the person.
    public static func decode(_ data: Data?) -> BrowserApprovals {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let data, let decoded = try? decoder.decode(BrowserApprovals.self, from: data) else { return BrowserApprovals() }
        return decoded
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)) ?? Data()
    }
}
