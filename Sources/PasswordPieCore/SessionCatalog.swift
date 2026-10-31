import Foundation

/// Which decrypted files stay in the merged list after the user removes one.
public enum OpenedCatalog {
    /// A failed keychain delete keeps the file. Removing it would hide a secret that is still stored.
    public static func afterRemoval(openedPaths: [String], removedPath: String, secretDeleted: Bool) -> [String] {
        guard secretDeleted else { return openedPaths }
        return openedPaths.filter { $0 != removedPath }
    }
}

/// Where an import's opened file points after the sibling `.kdbx` is written.
public enum ImportRetarget {
    public struct Decision: Equatable, Sendable {
        public var openedPath: String
        /// The sibling already on disk. The next save writes here until the secret moves.
        public var pendingPath: String?
        public var retargetRoster: Bool

        public init(openedPath: String, pendingPath: String?, retargetRoster: Bool) {
            self.openedPath = openedPath
            self.pendingPath = pendingPath
            self.retargetRoster = retargetRoster
        }
    }

    /// The opened file stays on the source path until the keychain secret has moved.
    /// A failed move remembers the written sibling so the next save does not create another one.
    public static func decide(source: String, destination: String, secretMoved: Bool) -> Decision {
        if source != destination, secretMoved {
            return Decision(openedPath: destination, pendingPath: nil, retargetRoster: true)
        }
        if source != destination {
            return Decision(openedPath: source, pendingPath: destination, retargetRoster: false)
        }
        return Decision(openedPath: source, pendingPath: nil, retargetRoster: false)
    }
}

/// Which `.kdbx` an import writes. A path remembered from a failed secret move wins over a new name.
public enum ImportDestination {
    public static func url(
        source: URL,
        pending: String?,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL {
        if let pending, !pending.isEmpty { return URL(fileURLWithPath: pending) }
        return VaultFormat.importedKDBXURL(beside: source, exists: exists)
    }
}

/// Whether a sibling vault that finished decrypting may join the list.
public enum CatalogLoad {
    public enum Step: Equatable, Sendable {
        case publish
        case skipFile
        case stop
    }

    /// A newer unlock or a lock bumps `current` and makes the whole batch stale.
    /// The locked flag is not a signal: this load starts before unlock clears it.
    /// A removed path is skipped on its own.
    public static func step(generation: UInt, current: UInt, pathStillListed: Bool) -> Step {
        guard generation == current else { return .stop }
        return pathStillListed ? .publish : .skipFile
    }
}
