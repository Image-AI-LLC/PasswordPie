import Darwin
import Foundation

/// `PasswordPieUpdater install`: put a staged, checked app where the installed one is. See docs/CHANNELS.md, "Updates".
public struct UpdateInstall {
    public var app: URL
    public var staged: URL
    public var cache: URL
    public var policy: ReleasePolicy
    public var fileManager: FileManager = .default

    public init(app: URL, staged: URL, cache: URL, policy: ReleasePolicy = .release) {
        self.app = app
        self.staged = staged
        self.cache = cache
        self.policy = policy
    }

    /// Waits until `pid` is gone. False when it still runs after `seconds`: the app is not replaced under a running process.
    public static func waitForExit(of pid: pid_t, seconds: Double, interval: Double = 0.1) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            if kill(pid, 0) != 0, errno == ESRCH { return true }
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: interval)
        }
    }

    /// Replaces `app` with `staged`. On any failure the installed app is where and what it was.
    public func run() throws {
        // Only a copy this updater staged: nothing outside its own cache folder is installed.
        let stagedPath = staged.standardizedFileURL.resolvingSymlinksInPath().path
        let cachePath = cache.standardizedFileURL.resolvingSymlinksInPath().path
        guard stagedPath.hasPrefix(cachePath + "/") else { throw UpdateError("That is not a downloaded update.") }
        guard let installed = BundleInfo(app: app) else { throw UpdateError("The installed PasswordPie could not be read.") }

        // A folder on the app's own volume, so that both moves below are renames.
        let work: URL
        do {
            work = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        } catch {
            throw UpdateError("PasswordPie cannot be replaced where it is.")
        }
        var keepWork = false
        defer { if !keepWork { try? fileManager.removeItem(at: work) } }
        let incoming = work.appendingPathComponent("new", isDirectory: true).appendingPathComponent(app.lastPathComponent, isDirectory: true)
        let outgoing = work.appendingPathComponent("old", isDirectory: true).appendingPathComponent(app.lastPathComponent, isDirectory: true)
        do {
            try fileManager.createDirectory(at: incoming.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: outgoing.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: staged, to: incoming)
        } catch {
            throw UpdateError("The update could not be moved into place.")
        }
        // Checked again where it now is: these are the bytes that become the app.
        _ = try policy.verifyApp(incoming, newerThan: installed.version)
        do {
            try fileManager.moveItem(at: app, to: outgoing)
        } catch {
            throw UpdateError("PasswordPie cannot be replaced where it is.")
        }
        do {
            try fileManager.moveItem(at: incoming, to: app)
        } catch {
            // Put the old app back. If even that fails, it is still intact in `work`, which is then kept.
            keepWork = (try? fileManager.moveItem(at: outgoing, to: app)) == nil
            throw UpdateError("The update could not be moved into place.")
        }
        try? fileManager.removeItem(at: staged.deletingLastPathComponent())
    }
}
