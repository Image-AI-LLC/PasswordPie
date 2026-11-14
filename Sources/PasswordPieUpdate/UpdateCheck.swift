import Foundation

/// The updater's network side: two requests, both to GitHub. The library names no networking API; the executable does.
public protocol UpdateTransport {
    func fetch(_ url: URL) throws -> Data
    /// Writes the file at `url` to `file`, and fails rather than write more than `maxBytes`.
    func download(_ url: URL, to file: URL, maxBytes: Int) throws
}

/// `PasswordPieUpdater check`: ask for the latest release and, when it is newer, leave a checked copy of it in `cache`.
public struct UpdateCheck {
    public var app: URL
    public var cache: URL
    public var policy: ReleasePolicy
    public var transport: UpdateTransport
    public var fileManager: FileManager = .default

    public init(app: URL, cache: URL, policy: ReleasePolicy = .release, transport: UpdateTransport) {
        self.app = app
        self.cache = cache
        self.policy = policy
        self.transport = transport
    }

    /// `~/Library/Caches/com.passwordpie.updater`.
    public static func defaultCache(fileManager: FileManager = .default) -> URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return caches.appendingPathComponent("\(ReleasePolicy.appIdentifier).updater", isDirectory: true)
    }

    public func run() -> UpdateOutcome {
        // A build that is not a release never asks GitHub anything.
        guard CodeSignature.satisfies(app, requirement: policy.installed, nested: false),
              let installed = BundleInfo(app: app), installed.identifier == policy.bundleIdentifier else {
            return UpdateOutcome(.notEligible)
        }
        do {
            let release = try ReleaseFeed.parse(try transport.fetch(ReleaseFeed.latestURL))
            guard release.version > installed.version else {
                try? clear(keeping: nil)
                return UpdateOutcome(.upToDate, version: installed.version.description)
            }
            guard Self.canReplace(app, fileManager: fileManager) else {
                return UpdateOutcome(.available, version: release.version.description)
            }
            let staged = try stage(release, newerThan: installed.version)
            return UpdateOutcome(.staged, version: release.version.description, path: staged.path)
        } catch let error as UpdateError {
            return UpdateOutcome(.failed, message: error.message)
        } catch {
            return UpdateOutcome(.failed, message: "The update check failed.")
        }
    }

    /// False for an app run from a disk image, from where macOS moved it at random (run from Downloads), or from a folder this user cannot change.
    public static func canReplace(_ app: URL, fileManager: FileManager = .default) -> Bool {
        let path = app.standardizedFileURL.path
        guard !path.contains("/AppTranslocation/") else { return false }
        return fileManager.isWritableFile(atPath: app.deletingLastPathComponent().path) && fileManager.isWritableFile(atPath: path)
    }

    /// Where a checked copy of `version` waits: `<cache>/PasswordPie-<version>/PasswordPie.app`.
    func stagedApp(for version: AppVersion) -> URL {
        cache.appendingPathComponent("PasswordPie-\(version)", isDirectory: true)
            .appendingPathComponent(app.lastPathComponent, isDirectory: true)
    }

    private func stage(_ release: Release, newerThan installed: AppVersion) throws -> URL {
        let staged = stagedApp(for: release.version)
        // Downloaded by an earlier check and still intact: no second download.
        if fileManager.fileExists(atPath: staged.path), (try? policy.verifyApp(staged, newerThan: installed)) == release.version {
            return staged
        }
        try clear(keeping: nil)
        try fileManager.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let image = cache.appendingPathComponent(release.imageName)
        defer { try? fileManager.removeItem(at: image) }
        try transport.download(release.imageURL, to: image, maxBytes: release.imageBytes)
        // Checked before it is mounted: a disk image that is not ours is never opened.
        guard CodeSignature.satisfies(image, requirement: policy.image, nested: false) else {
            throw UpdateError("The download is not signed by PasswordPie's developer.")
        }
        let mountPoint = cache.appendingPathComponent("mount-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: mountPoint) }
        try DiskImage.attach(image, at: mountPoint)
        do {
            let source = mountPoint.appendingPathComponent(app.lastPathComponent, isDirectory: true)
            guard fileManager.fileExists(atPath: source.path) else { throw UpdateError("The download does not contain PasswordPie.") }
            try fileManager.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: staged)
        } catch {
            try? DiskImage.detach(mountPoint)
            try? fileManager.removeItem(at: staged.deletingLastPathComponent())
            throw (error as? UpdateError) ?? UpdateError("The download could not be copied.")
        }
        try? DiskImage.detach(mountPoint)
        // The copy is what gets installed, so the copy is what is checked.
        do {
            guard try policy.verifyApp(staged, newerThan: installed) == release.version else {
                throw UpdateError("The download is not PasswordPie \(release.version).")
            }
        } catch {
            try? fileManager.removeItem(at: staged.deletingLastPathComponent())
            throw error
        }
        return staged
    }

    /// Empties the cache folder, except `keeping`. A folder that is not there is already empty.
    func clear(keeping: URL?) throws {
        guard let items = try? fileManager.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil) else { return }
        for item in items where item.standardizedFileURL != keeping?.standardizedFileURL {
            if item.lastPathComponent.hasPrefix("mount-") { try? DiskImage.detach(item) }
            try fileManager.removeItem(at: item)
        }
    }
}
