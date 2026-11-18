import Darwin
import Foundation

/// The program a command runs: the first word, as the shell would find it.
enum ProgramPath {
    /// The absolute path of `word`: as given when it has a `/` (relative to the working folder), else the first
    /// executable of that name on `path`. Nil when there is none.
    static func resolve(_ word: String, path: String?, cwd: String = FileManager.default.currentDirectoryPath) -> String? {
        guard !word.isEmpty else { return nil }
        if word.contains("/") {
            let url = word.hasPrefix("/") ? URL(fileURLWithPath: word) : URL(fileURLWithPath: cwd).appendingPathComponent(word)
            let full = url.standardizedFileURL.path
            return isExecutable(full) ? full : nil
        }
        for folder in (path ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":") where !folder.isEmpty {
            let base = folder.hasPrefix("/") ? String(folder) : URL(fileURLWithPath: cwd).appendingPathComponent(String(folder)).path
            let candidate = URL(fileURLWithPath: base).appendingPathComponent(word).standardizedFileURL.path
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    private static func isExecutable(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return false }
        return access(path, X_OK) == 0
    }
}
