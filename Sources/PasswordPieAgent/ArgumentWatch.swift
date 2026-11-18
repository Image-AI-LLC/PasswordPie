import Darwin
import Foundation

/// While a run lasts, looks at the command lines of the command and every process under it for the values the run handed
/// out, and reports each value once per process it appears in: "the value of APPLE_PASSWORD appeared on the command line
/// of notarytool". Any process of the same user can read a command line (`ps`), so a value there has leaked even though
/// PasswordPie gave it by environment, file or standard input. Detection, not prevention: by the time it is seen, it is
/// there. A process that starts and ends between two looks (a quarter of a second) can be missed, and so can one that
/// left the run's tree (a daemon re-parented to launchd). Only the arguments are read, never the environment that
/// follows them in the kernel's record, where the values are expected. See docs/AGENTS.md, "Argument watch".
public final class ArgumentWatch: @unchecked Sendable {
    public struct Watched: Equatable, Sendable {
        /// The environment variable, or nil for standard input.
        public var name: String?
        public var ref: String
        public var delivery: AgentDelivery
        public var value: Data

        public init(name: String?, ref: String, delivery: AgentDelivery, value: Data) {
            self.name = name
            self.ref = ref
            self.delivery = delivery
            self.value = value
        }

        /// "APPLE_PASSWORD", or "the standard input value" for stdin.
        public var label: String { name ?? "the standard input value" }
    }

    public struct Finding: Equatable, Sendable {
        public var name: String?
        public var ref: String
        public var delivery: AgentDelivery
        public var pid: Int32
        /// The executable's path, as the kernel knows it. Never the command line.
        public var program: String

        /// "PasswordPie: the value of APPLE_PASSWORD appeared on the command line of notarytool (pid 4120). …". Never
        /// the value, never the command line.
        public var warning: String {
            let what = name.map { "the value of \($0)" } ?? "the standard input value"
            let tool = (program as NSString).lastPathComponent
            return "PasswordPie: \(what) (\(ref)) appeared on the command line of \(tool) (pid \(pid)), where any process on this Mac can read it. Pass it by environment, standard input or a file instead; if the tool takes it only as an argument, nothing can keep it off the command line."
        }
    }

    /// What the watch reads about processes; tests give their own.
    public struct Facts: Sendable {
        public var children: @Sendable (Int32) -> [Int32]
        public var arguments: @Sendable (Int32) -> [Data]
        public var path: @Sendable (Int32) -> String?

        public init(children: @escaping @Sendable (Int32) -> [Int32], arguments: @escaping @Sendable (Int32) -> [Data], path: @escaping @Sendable (Int32) -> String?) {
            self.children = children
            self.arguments = arguments
            self.path = path
        }

        public static let live = Facts(children: ArgumentWatch.liveChildren, arguments: ArgumentWatch.liveArguments, path: ArgumentWatch.livePath)
    }

    public static let interval: TimeInterval = 0.25

    private let root: Int32
    private let watched: [Watched]
    private let facts: Facts
    private let report: @Sendable (Finding) -> Void
    private let lock = NSLock()
    private var stopped = false
    /// "pid:index" of what was reported, so each value is reported once per process.
    private var reported: Set<String> = []

    /// Values shorter than `AgentConstants.minimumMaskedLength` are not watched: they would match ordinary words.
    public init(root: Int32, watched: [Watched], facts: Facts = .live, report: @escaping @Sendable (Finding) -> Void) {
        self.root = root
        self.watched = watched.filter { $0.value.count >= AgentConstants.minimumMaskedLength }
        self.facts = facts
        self.report = report
    }

    public var isEmpty: Bool { watched.isEmpty }

    /// Looks every quarter of a second, on its own thread, until `stop()`.
    public func start() {
        guard !watched.isEmpty else { return }
        Thread.detachNewThread { [self] in
            while !isStopped {
                look()
                Thread.sleep(forTimeInterval: Self.interval)
            }
        }
    }

    /// Ends the watch after the look in progress, if any.
    public func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    /// One look at the command and everything under it.
    public func look() {
        var queue = [root]
        var seen: Set<Int32> = []
        while let pid = queue.popLast() {
            guard seen.insert(pid).inserted, seen.count < 4096 else { continue }
            check(pid)
            queue += facts.children(pid)
        }
    }

    private func check(_ pid: Int32) {
        let arguments = facts.arguments(pid)
        guard !arguments.isEmpty else { return }
        for (index, value) in watched.enumerated() where arguments.contains(where: { $0.range(of: value.value) != nil }) {
            let key = "\(pid):\(index)"
            lock.lock()
            let fresh = reported.insert(key).inserted
            lock.unlock()
            guard fresh else { continue }
            report(Finding(name: value.name, ref: value.ref, delivery: value.delivery, pid: pid, program: facts.path(pid) ?? "pid \(pid)"))
        }
    }

    // MARK: The kernel's view

    /// The pids whose parent is `pid`.
    public static let liveChildren: @Sendable (Int32) -> [Int32] = { pid in
        var buffer = [Int32](repeating: 0, count: 256)
        while true {
            let bytes = buffer.withUnsafeMutableBytes { raw in
                proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(bitPattern: pid), raw.baseAddress, Int32(raw.count))
            }
            guard bytes > 0 else { return [] }
            let count = Int(bytes) / MemoryLayout<Int32>.size
            if count < buffer.count { return buffer.prefix(count).filter { $0 > 0 } }
            buffer = [Int32](repeating: 0, count: buffer.count * 2)
            if buffer.count > 65_536 { return [] }
        }
    }

    /// The process's arguments, all of them, as bytes (`KERN_PROCARGS2`): the executable path, padding, `argc`
    /// arguments, then the environment, which is not read.
    public static let liveArguments: @Sendable (Int32) -> [Data] = { pid in
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        return arguments(fromRecord: Array(buffer.prefix(size)))
    }

    /// The `argc` arguments of a `KERN_PROCARGS2` record: `argc` (32 bits), the executable path, padding NULs, the
    /// arguments, then the environment, which is left alone.
    static func arguments(fromRecord buffer: [UInt8]) -> [Data] {
        let size = buffer.count
        guard size > MemoryLayout<Int32>.size else { return [] }
        let count = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [Data] = []
        while index < size, arguments.count < Int(count) {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(Data(buffer[start..<index]))
            index += 1
        }
        return arguments
    }

    public static let livePath: @Sendable (Int32) -> String? = { pid in
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
