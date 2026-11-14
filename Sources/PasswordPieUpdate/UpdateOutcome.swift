import Foundation

/// The one line `PasswordPieUpdater check` prints, and all the app learns from it.
public struct UpdateOutcome: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// The installed version is the latest.
        case upToDate
        /// A newer version is downloaded, checked and waiting at `path`.
        case staged
        /// A newer version exists, but this copy of the app cannot be replaced where it is.
        case available
        /// Not a release build: nothing was asked of GitHub.
        case notEligible
        case failed
    }

    public var status: Status
    public var version: String?
    public var path: String?
    public var message: String?

    public init(_ status: Status, version: String? = nil, path: String? = nil, message: String? = nil) {
        self.status = status
        self.version = version
        self.path = path
        self.message = message
    }

    /// One line of JSON, no newline inside.
    public func line() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: (try? encoder.encode(self)) ?? Data(#"{"status":"failed"}"#.utf8), as: UTF8.self)
    }

    /// The last line of the updater's output that is an outcome. Nil when there is none: the updater crashed or is not ours.
    public static func parse(_ output: Data) -> UpdateOutcome? {
        let lines = String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline)
        for line in lines.reversed() {
            if let outcome = try? JSONDecoder().decode(UpdateOutcome.self, from: Data(line.utf8)) { return outcome }
        }
        return nil
    }
}
