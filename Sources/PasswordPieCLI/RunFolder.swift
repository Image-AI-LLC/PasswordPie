import Darwin
import Foundation
import PasswordPieAgent

/// The short-lived files of a `run`: one 0700 folder per run under the per-user temporary folder (`$TMPDIR`), 0600 files,
/// removed when the command exits or the tool is interrupted. A folder left by a tool that was killed is removed by the
/// next `run`: its name carries the tool's pid.
enum RunFolder {
    static let prefix = "passwordpie-run."

    /// `$TMPDIR`, else the per-user temporary folder macOS gives this user.
    static var base: URL {
        let folder = ProcessInfo.processInfo.environment["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory()
        return URL(fileURLWithPath: folder, isDirectory: true)
    }

    /// A new folder for this run, mode 0700.
    static func create() throws -> URL {
        var template = Array(base.appendingPathComponent("\(prefix)\(getpid()).\(startTime(getpid()) ?? 0).XXXXXXXX").path.utf8CString)
        guard let made = mkdtemp(&template) else { throw UsageError("Could not create a folder in \(base.path).") }
        let path = String(cString: made)
        chmod(path, 0o700)
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Writes `bytes` to a new 0600 file in `folder`. Never follows or replaces an existing file.
    static func write(_ bytes: Data, named name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw UsageError("Could not create a file in \(folder.path).") }
        defer { close(fd) }
        fchmod(fd, 0o600)
        let written = bytes.withUnsafeBytes { raw in raw.baseAddress.map { Darwin.write(fd, $0, raw.count) } ?? 0 }
        guard written == bytes.count else { throw UsageError("Could not write a file in \(folder.path).") }
        return url
    }

    /// True when `ref` names an attachment rather than a text field.
    static func namesAttachment(_ ref: String) -> Bool {
        attachmentName(ref) != nil
    }

    private static func attachmentName(_ ref: String) -> String? {
        guard let reference = try? AgentReference(ref) else { return nil }
        switch reference.target {
        case .id(_, .attachment(let name)): return name
        case .path(let readings):
            for reading in readings {
                if case .attachment(let name) = reading.field { return name }
            }
            return nil
        default: return nil
        }
    }

    /// The file's name: the variable's, with the attachment's extension so tools that look at it (`.p8`, `.p12`) are happy.
    static func fileName(variable: String, ref: String) -> String {
        let attachment = attachmentName(ref)
        let ext = attachment.map { ($0 as NSString).pathExtension } ?? ""
        let safe = ext.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) } ? ext : ""
        return safe.isEmpty ? variable : "\(variable).\(safe)"
    }

    /// A process's start time in microseconds, or nil when no such process runs.
    static func startTime(_ pid: Int32) -> UInt64? {
        LiveProcessFacts.shared.info(pid)?.startTime
    }

    static func remove(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Removes the folders of runs whose tool is no longer running. Only folders of this user, never through a link.
    static func removeStale() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { return }
        for name in names where name.hasPrefix(prefix) {
            // passwordpie-run.<pid>.<start time>.<random>: the tool that made it, by pid and start time, so a later
            // process that got the pid does not keep it alive.
            let parts = name.dropFirst(prefix.count).split(separator: ".")
            guard parts.count >= 2, let pid = Int32(parts[0]) else { continue }
            if let started = UInt64(parts[1]), let running = startTime(pid), running == started { continue }
            let path = base.appendingPathComponent(name).path
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else { continue }
            remove(URL(fileURLWithPath: path, isDirectory: true))
        }
    }
}
