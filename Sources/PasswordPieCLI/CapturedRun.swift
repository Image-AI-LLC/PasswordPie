import Darwin
import Foundation
import PasswordPieAgent
import PasswordPieBridge

/// Ends one MCP tool call early: the client cancelled it, or the client went away. A request waiting on the app has its
/// connection shut (the app withdraws its prompt); a running command's process group gets SIGTERM, then SIGKILL.
final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var socket: Int32 = -1
    private var group: ProcessGroup?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// False when already cancelled.
    func attach(socket fd: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        socket = fd
        return true
    }

    func detachSocket() {
        lock.lock()
        socket = -1
        lock.unlock()
    }

    /// False when already cancelled: the caller then ends the group itself.
    func attach(group: ProcessGroup) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        self.group = group
        return true
    }

    func detachGroup() {
        lock.lock()
        group = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        // Under the lock: the connection's owner closes it only after `detachSocket`, so the number is still this one.
        if socket >= 0 { shutdown(socket, SHUT_RDWR) }
        let group = group
        lock.unlock()
        group?.terminate()
    }

    /// SIGKILL to the command's group now, when the server exits before SIGTERM worked.
    func forceEnd() {
        lock.lock()
        let group = group
        lock.unlock()
        group?.signal(SIGKILL)
    }
}

/// Runs a command for the MCP server: in the folder the agent named, with its output captured and masked rather than
/// passed on (the server's own standard output carries the MCP messages), its standard input empty unless a secret goes
/// there, in a process group of its own so a timeout or a cancellation ends everything it started.
enum CapturedRun {
    struct Plan {
        var path: String
        var argv: [String]
        var environment: [String: String]
        var cwd: String
        var stdin: Data?
        var mask: [Data]
        var timeout: TimeInterval
        var watched: [ArgumentWatch.Watched] = []
        var report: (@Sendable (ArgumentWatch.Finding) -> Void)?
        /// Each stream keeps at most this many bytes: the first half and the last half.
        var limit = MCPLimits.streamBytes
    }

    struct Outcome {
        var exitCode: Int32
        var stdout: String
        var stderr: String
        var concealed: Int
        var truncated: Bool
        var timedOut: Bool
    }

    static func run(_ plan: Plan, cancellation: Cancellation) throws -> Outcome {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        var childEnds: [Int32] = []
        var parentEnds: [Int32] = []
        func closeAll() {
            (childEnds + parentEnds).forEach { close($0) }
        }

        var stdinWriter: Int32 = -1
        if plan.stdin != nil {
            var fds: [Int32] = [0, 0]
            guard pipe(&fds) == 0 else { throw Refusal(.usage, detail: "Could not create a pipe.") }
            posix_spawn_file_actions_adddup2(&fileActions, fds[0], 0)
            childEnds.append(fds[0])
            stdinWriter = fds[1]
            _ = fcntl(stdinWriter, F_SETFD, FD_CLOEXEC)
        } else {
            posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        }
        var readers: [Int32] = []
        for target in [STDOUT_FILENO, STDERR_FILENO] {
            var fds: [Int32] = [0, 0]
            guard pipe(&fds) == 0 else {
                closeAll()
                if stdinWriter >= 0 { close(stdinWriter) }
                throw Refusal(.usage, detail: "Could not create a pipe.")
            }
            posix_spawn_file_actions_adddup2(&fileActions, fds[1], target)
            childEnds.append(fds[1])
            parentEnds.append(fds[0])
            readers.append(fds[0])
        }
        posix_spawn_file_actions_addchdir_np(&fileActions, plan.cwd)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var empty = sigset_t()
        sigemptyset(&empty)
        posix_spawnattr_setsigmask(&attributes, &empty)
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETPGROUP))

        let argv = plan.argv.map { strdup($0) } + [nil]
        let envp = plan.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var child: pid_t = 0
        let spawned = posix_spawn(&child, plan.path, &fileActions, &attributes, argv, envp)
        childEnds.forEach { close($0) }
        childEnds = []
        guard spawned == 0 else {
            closeAll()
            if stdinWriter >= 0 { close(stdinWriter) }
            throw Refusal(.usage, detail: "Could not start \(plan.argv.first ?? plan.path): \(String(cString: strerror(spawned))).")
        }
        let group = ProcessGroup(child)
        if !cancellation.attach(group: group) { group.terminate() }
        defer { cancellation.detachGroup() }

        if let input = plan.stdin, stdinWriter >= 0 {
            let fd = stdinWriter
            Thread.detachNewThread {
                try? BridgeSocket.writeAll(fd, input)
                close(fd)
            }
        }
        let watch = plan.report.map { ArgumentWatch(root: child, watched: plan.watched, report: $0) }
        watch?.start()
        defer { watch?.stop() }

        // The command's end, seen from its own thread without reaping it (so its pid, the group's id, stays taken
        // until the group is ended below), wakes the loop.
        var wake: [Int32] = [0, 0]
        guard pipe(&wake) == 0 else {
            group.terminate()
            _ = group.reap()
            readers.forEach { close($0) }
            throw Refusal(.usage, detail: "Could not create a pipe.")
        }
        let woke = DispatchSemaphore(value: 0)
        defer {
            // The waiting thread has written its byte before the pipe is closed.
            woke.wait()
            close(wake[0])
            close(wake[1])
        }
        Thread.detachNewThread {
            var info = siginfo_t()
            while waitid(P_PID, id_t(child), &info, WEXITED | WNOWAIT) < 0, errno == EINTR {}
            var byte: UInt8 = 1
            _ = write(wake[1], &byte, 1)
            woke.signal()
        }

        var maskers = readers.map { _ in OutputMasker(values: plan.mask) }
        var kept = readers.map { _ in Clipped(limit: plan.limit) }
        var open = Array(readers.indices)
        var exited = false
        var timedOut = false
        var drainDeadline = Date.distantFuture
        let deadline = Date().addingTimeInterval(plan.timeout)
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if exited, open.isEmpty || Date() > drainDeadline { break }
            var polled = open.map { pollfd(fd: readers[$0], events: Int16(POLLIN), revents: 0) }
            if !exited { polled.append(pollfd(fd: wake[0], events: Int16(POLLIN), revents: 0)) }
            let until = exited ? drainDeadline : (timedOut ? Date().addingTimeInterval(1) : deadline)
            let ready = poll(&polled, nfds_t(polled.count), Int32(max(0, min(until.timeIntervalSinceNow, 3600)) * 1000))
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if !exited, !timedOut, Date() >= deadline {
                timedOut = true
                group.terminate()
            }
            if !exited, let last = polled.last, last.revents != 0 {
                exited = true
                drainDeadline = Date().addingTimeInterval(0.5)
            }
            var closed: [Int] = []
            for (slot, index) in open.enumerated() where polled[slot].revents != 0 {
                let count = read(readers[index], &chunk, chunk.count)
                if count > 0 {
                    kept[index].append(maskers[index].feed(Data(chunk[0..<count])))
                } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                    closed.append(index)
                }
            }
            open.removeAll { closed.contains($0) }
        }
        // A stream still open now was cut (the command was ended, or left something writing): a value it was in the middle
        // of is concealed from its start.
        let stopped = timedOut || cancellation.isCancelled
        for index in readers.indices {
            kept[index].append(maskers[index].finish(cut: stopped || open.contains(index)))
            close(readers[index])
        }
        parentEnds = []
        // Whatever the command left running in its group (a background job holding the output) ends with it.
        let code = group.reap()
        return Outcome(
            exitCode: ChildProcess.exitCode(code),
            stdout: kept[0].text,
            stderr: kept[1].text,
            concealed: maskers.reduce(0) { $0 + $1.concealedCount },
            truncated: kept.contains { $0.dropped > 0 },
            timedOut: timedOut
        )
    }

}

/// The command's process group, whose id is the command's pid. It is signalled only until the command is reaped: while
/// the command (alive, or a zombie not yet reaped) holds its pid, no other process can get it, so no other group is hit.
final class ProcessGroup: @unchecked Sendable {
    let id: pid_t
    private let lock = NSLock()
    private var reaped = false

    init(_ id: pid_t) {
        self.id = id
    }

    func signal(_ number: Int32) {
        lock.lock()
        defer { lock.unlock() }
        if !reaped { killpg(id, number) }
    }

    /// SIGTERM, then SIGKILL two seconds later unless the command was reaped meanwhile.
    func terminate() {
        signal(SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in signal(SIGKILL) }
    }

    /// Ends what is left of the group, then reaps the command and returns its wait status.
    func reap() -> Int32 {
        lock.lock()
        if !reaped { killpg(id, SIGKILL) }
        reaped = true
        lock.unlock()
        var status: Int32 = 0
        while waitpid(id, &status, 0) < 0, errno == EINTR {}
        return status
    }
}

enum MCPLimits {
    /// Each output stream of `passwordpie_run` is cut to this.
    static let streamBytes = 64 * 1024
    static let maxTimeoutSeconds = 3600
    static let defaultTimeoutSeconds = 600
}

/// The first and the last half of a stream, with what was cut in between counted. Build output's end (the error) is
/// usually what matters, its start says what ran.
struct Clipped {
    let limit: Int
    private(set) var head = Data()
    private(set) var tail = Data()
    private(set) var dropped = 0

    init(limit: Int) {
        self.limit = limit
    }

    mutating func append(_ data: Data) {
        guard !data.isEmpty else { return }
        let half = limit / 2
        var rest = data
        if head.count < half {
            let taken = rest.prefix(half - head.count)
            head.append(taken)
            rest = rest.dropFirst(taken.count)
        }
        guard !rest.isEmpty else { return }
        tail.append(rest)
        let over = tail.count - (limit - half)
        if over > 0 {
            dropped += over
            tail = Data(tail.dropFirst(over))
        }
    }

    /// The kept text, decoded as UTF-8 (anything else replaced), with a line where bytes were cut. A character cut in
    /// two at either edge of the gap is dropped rather than shown broken.
    var text: String {
        guard dropped > 0 else { return String(decoding: head + tail, as: UTF8.self) }
        var front = head
        // The last character's lead byte, within its last 4 bytes: drop it with its continuation bytes when they are
        // fewer than it announces.
        let bytes = [UInt8](front.suffix(4))
        if let lead = bytes.lastIndex(where: { $0 & 0xC0 != 0x80 }), bytes[lead] >= 0xC0 {
            let length = bytes[lead] >= 0xF0 ? 4 : bytes[lead] >= 0xE0 ? 3 : 2
            if bytes.count - lead < length { front.removeLast(bytes.count - lead) }
        }
        var back = tail
        while let first = back.first, first & 0xC0 == 0x80 { back.removeFirst() }
        return String(decoding: front, as: UTF8.self) + "\n[… \(dropped) bytes cut by PasswordPie …]\n" + String(decoding: back, as: UTF8.self)
    }
}
