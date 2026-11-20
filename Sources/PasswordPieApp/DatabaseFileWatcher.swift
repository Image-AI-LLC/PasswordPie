import Foundation

/// What the file system says about a file without reading it: enough to tell that it was replaced or rewritten. A sync
/// tool replaces a file by renaming a new one over it, so the inode changes even when size and time happen to match.
struct FileSignature: Equatable, Sendable {
    var inode: UInt64
    var size: Int64
    var modifiedSeconds: Int
    var modifiedNanoseconds: Int

    init?(path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        inode = UInt64(info.st_ino)
        size = Int64(info.st_size)
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
    }

    /// For remembering a file across launches: "inode:size:seconds:nanoseconds".
    var text: String { "\(inode):\(size):\(modifiedSeconds):\(modifiedNanoseconds)" }
}

/// Looks at the open databases' files, and at the folders they are in, every few seconds, and says which changed
/// (docs/UX.md, "The same database on two Macs"). It reads nothing and opens nothing: what to do about a change is the
/// session's business (`VaultSession+Merge.swift`). Looking is cheap, and unlike a file-system event it cannot miss a
/// file that a sync tool renamed into place.
final class DatabaseFileWatcher: @unchecked Sendable {
    static let defaultInterval: TimeInterval = 2

    private let queue = DispatchQueue(label: "com.passwordpie.database-file-watcher", qos: .utility)
    private let interval: TimeInterval
    private var timer: DispatchSourceTimer?
    private var files: [String: FileSignature?] = [:]
    private var folders: [String: FileSignature?] = [:]
    /// On the main queue: the watched paths whose file changed, and those whose folder did.
    private let onChange: @MainActor (_ files: [String], _ folders: [String]) -> Void

    init(interval: TimeInterval = DatabaseFileWatcher.defaultInterval, onChange: @escaping @MainActor (_ files: [String], _ folders: [String]) -> Void) {
        self.interval = interval
        self.onChange = onChange
    }

    deinit {
        timer?.cancel()
    }

    /// Watches exactly these files. One already watched keeps what was last seen of it; a new one starts from how it
    /// is now. None: stops looking.
    func watch(_ paths: [String]) {
        queue.async { [self] in
            let wanted = Set(paths)
            guard wanted != Set(files.keys) else { return }
            files = Dictionary(uniqueKeysWithValues: wanted.map { ($0, files[$0] ?? FileSignature(path: $0)) })
            folders = Dictionary(uniqueKeysWithValues: wanted.map { ($0, folders[$0] ?? FileSignature(path: Self.folder(of: $0))) })
            if wanted.isEmpty {
                timer?.cancel()
                timer = nil
            } else if timer == nil {
                let made = DispatchSource.makeTimerSource(queue: queue)
                made.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(250))
                made.setEventHandler { [weak self] in self?.look() }
                made.resume()
                timer = made
            }
        }
    }

    /// One look now, without waiting for the timer. Returns once it is done; the callback follows on the main queue.
    func lookNow() {
        queue.sync { look() }
    }

    private func look() {
        var changedFiles: [String] = [], changedFolders: [String] = []
        for path in files.keys.sorted() {
            let now = FileSignature(path: path)
            if now != files[path] ?? nil {
                files[path] = now
                changedFiles.append(path)
            }
            let folder = FileSignature(path: Self.folder(of: path))
            if folder != folders[path] ?? nil {
                folders[path] = folder
                changedFolders.append(path)
            }
        }
        guard !changedFiles.isEmpty || !changedFolders.isEmpty else { return }
        let report = onChange
        DispatchQueue.main.async {
            MainActor.assumeIsolated { report(changedFiles, changedFolders) }
        }
    }

    private static func folder(of path: String) -> String {
        URL(fileURLWithPath: path).deletingLastPathComponent().path
    }
}
