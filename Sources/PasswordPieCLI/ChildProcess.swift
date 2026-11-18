import Darwin
import Foundation
import PasswordPieAgent
import PasswordPieBridge

/// Starts the command with its values and passes its output on, masked. Values reach the command only through its
/// environment, its standard input, or files; never its command line.
enum ChildProcess {
    struct Plan {
        var path: String
        var argv: [String]
        var environment: [String: String]
        /// Written to the command's standard input, then closed. Nil: the command reads the tool's own.
        var stdin: Data?
        /// Values to replace in the output. Nil: output is not masked and goes straight through.
        var mask: [Data]?
    }

    /// The command's exit code: its own, or 128 + the signal that ended it.
    static func run(_ plan: Plan) -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        var parentEnds: [Int32] = []
        var childEnds: [Int32] = []

        // Standard input.
        var stdinWriter: Int32 = -1
        if plan.stdin != nil {
            var fds: [Int32] = [0, 0]
            guard pipe(&fds) == 0 else { return failure("Could not create a pipe.") }
            posix_spawn_file_actions_adddup2(&fileActions, fds[0], 0)
            stdinWriter = fds[1]
            _ = fcntl(stdinWriter, F_SETFD, FD_CLOEXEC)
            childEnds.append(fds[0])
        } else {
            posix_spawn_file_actions_addinherit_np(&fileActions, 0)
        }

        // Standard output and error: a pseudo-terminal when the tool's own output is a terminal, so progress bars and
        // colours still work; else pipes. Straight through when output is not masked.
        var sources: [Source] = []
        if let mask = plan.mask {
            var terminal: (master: Int32, slave: Int32)?
            if isatty(STDOUT_FILENO) == 1 { terminal = openTerminal() }
            for target in [STDOUT_FILENO, STDERR_FILENO] {
                if let terminal, isatty(target) == 1 {
                    posix_spawn_file_actions_adddup2(&fileActions, terminal.slave, target)
                    if !sources.contains(where: { $0.fd == terminal.master }) {
                        sources.append(Source(fd: terminal.master, output: STDOUT_FILENO, masker: OutputMasker(values: mask)))
                    }
                } else {
                    var fds: [Int32] = [0, 0]
                    guard pipe(&fds) == 0 else { return failure("Could not create a pipe.") }
                    posix_spawn_file_actions_adddup2(&fileActions, fds[1], target)
                    childEnds.append(fds[1])
                    sources.append(Source(fd: fds[0], output: target, masker: OutputMasker(values: mask)))
                }
            }
            if let terminal {
                childEnds.append(terminal.slave)
                parentEnds.append(terminal.master)
            }
            parentEnds += sources.map(\.fd)
        } else {
            posix_spawn_file_actions_addinherit_np(&fileActions, STDOUT_FILENO)
            posix_spawn_file_actions_addinherit_np(&fileActions, STDERR_FILENO)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Nothing else of this tool's (the socket, a pipe's other end) reaches the command, and the command gets default
        // signal handling, whatever this tool ignores.
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var empty = sigset_t()
        sigemptyset(&empty)
        posix_spawnattr_setsigmask(&attributes, &empty)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        let argv = plan.argv.map { strdup($0) } + [nil]
        let envp = plan.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var child: pid_t = 0
        let spawned = posix_spawn(&child, plan.path, &fileActions, &attributes, argv, envp)
        childEnds.forEach { close($0) }
        guard spawned == 0 else {
            parentEnds.forEach { close($0) }
            if stdinWriter >= 0 { close(stdinWriter) }
            return failure("Could not start \(plan.argv.first ?? plan.path): \(String(cString: strerror(spawned))).")
        }

        if let input = plan.stdin, stdinWriter >= 0 {
            let fd = stdinWriter
            Thread.detachNewThread {
                try? BridgeSocket.writeAll(fd, input)
                close(fd)
            }
        }
        let signals = forwardSignals(to: child, terminal: sources.first { isatty($0.fd) == 1 }?.fd)
        let status = relay(sources, child: child)
        signals.forEach { $0.cancel() }
        return exitCode(status)
    }

    static func exitCode(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    private static func failure(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data((AgentRefusal.line(.usage, detail: message) + "\n").utf8))
        return AgentErrorCode.usage.exitCode
    }

    private struct Source {
        var fd: Int32
        var output: Int32
        var masker: OutputMasker
    }

    /// A pseudo-terminal with the tool's own terminal settings and size.
    private static func openTerminal() -> (master: Int32, slave: Int32)? {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master) else {
            if master >= 0 { close(master) }
            return nil
        }
        let slave = open(name, O_RDWR | O_NOCTTY)
        guard slave >= 0 else {
            close(master)
            return nil
        }
        var settings = termios()
        if tcgetattr(STDOUT_FILENO, &settings) == 0 { tcsetattr(slave, TCSANOW, &settings) }
        copySize(to: master)
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        return (master, slave)
    }

    private static func copySize(to master: Int32) {
        var size = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 { _ = ioctl(master, TIOCSWINSZ, &size) }
    }

    /// Passes termination signals sent to this tool on to the command, so it ends and the files are removed after it.
    /// Ctrl-C at a terminal already reaches the command (same process group), so it is not passed on a second time then.
    private static func forwardSignals(to child: pid_t, terminal: Int32?) -> [DispatchSourceSignal] {
        var forwarded = [SIGTERM, SIGHUP]
        if isatty(STDIN_FILENO) == 0 { forwarded += [SIGINT, SIGQUIT] } else {
            signal(SIGINT, SIG_IGN)
            signal(SIGQUIT, SIG_IGN)
        }
        var sources: [DispatchSourceSignal] = []
        for number in forwarded {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { kill(child, number) }
            source.resume()
            sources.append(source)
        }
        if let terminal {
            signal(SIGWINCH, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
            source.setEventHandler {
                copySize(to: terminal)
                kill(child, SIGWINCH)
            }
            source.resume()
            sources.append(source)
        }
        return sources
    }

    /// Copies the command's output to this tool's, masked, until the command has exited and its output is drained. A
    /// background process the command left holding the output open is not waited for beyond half a second.
    private static func relay(_ initial: [Source], child: pid_t) -> Int32 {
        var wake: [Int32] = [0, 0]
        pipe(&wake)
        let statusBox = StatusBox()
        Thread.detachNewThread {
            var status: Int32 = 0
            while waitpid(child, &status, 0) < 0, errno == EINTR {}
            statusBox.set(status)
            var byte: UInt8 = 1
            _ = write(wake[1], &byte, 1)
        }
        var sources = initial
        var exited = false
        var drainDeadline = Date.distantFuture
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if exited, sources.isEmpty || Date() > drainDeadline { break }
            var polled = sources.map { pollfd(fd: $0.fd, events: Int16(POLLIN), revents: 0) }
            if !exited { polled.append(pollfd(fd: wake[0], events: Int16(POLLIN), revents: 0)) }
            let timeout: Int32 = exited ? Int32(max(0, drainDeadline.timeIntervalSinceNow * 1000)) : -1
            let ready = poll(&polled, nfds_t(polled.count), timeout)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if !exited, let last = polled.last, last.revents != 0 {
                exited = true
                drainDeadline = Date().addingTimeInterval(0.5)
            }
            var closed: [Int32] = []
            for (index, source) in sources.enumerated() where polled[index].revents != 0 {
                let count = read(source.fd, &chunk, chunk.count)
                if count > 0 {
                    let masked = sources[index].masker.feed(Data(chunk[0..<count]))
                    try? BridgeSocket.writeAll(source.output, masked)
                } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                    closed.append(source.fd)
                }
            }
            for fd in closed {
                if let index = sources.firstIndex(where: { $0.fd == fd }) {
                    try? BridgeSocket.writeAll(sources[index].output, sources[index].masker.finish())
                    sources.remove(at: index)
                }
                close(fd)
            }
        }
        for index in sources.indices {
            try? BridgeSocket.writeAll(sources[index].output, sources[index].masker.finish())
            close(sources[index].fd)
        }
        close(wake[0])
        close(wake[1])
        return statusBox.wait()
    }
}

private final class StatusBox: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private var status: Int32 = 0

    func set(_ value: Int32) {
        status = value
        done.signal()
    }

    func wait() -> Int32 {
        done.wait()
        return status
    }
}
