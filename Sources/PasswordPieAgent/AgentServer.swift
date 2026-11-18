import Darwin
import Foundation
import PasswordPieBridge

/// The app's end of `agent.sock`. It exists only while agent access is on. It serves only PasswordPie's command-line tool
/// signed by our team (the browser bridge's peer check), works out the caller from the kernel for every request, and
/// hands each request to the broker on the main actor. Frames are never logged. See docs/AGENTS.md.
public final class AgentServer: @unchecked Sendable {
    public typealias Handler = @MainActor (AgentRequest, AgentCaller) async -> AgentResponse

    private let handler: Handler
    private let peerCheck: @Sendable (Int32) -> Bool
    private let identify: @Sendable (Int32) -> AgentCaller?
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var path: String?
    private var connections: Set<Int32> = []

    /// `peerCheck` and `identify` are for tests; the defaults are the code-signature check and the kernel's process facts.
    public init(
        handler: @escaping Handler,
        peerCheck: @escaping @Sendable (Int32) -> Bool = AgentServer.isPasswordPieCLI,
        identify: @escaping @Sendable (Int32) -> AgentCaller? = { CallerInspector.identify(pid: $0) }
    ) {
        self.handler = handler
        self.peerCheck = peerCheck
        self.identify = identify
    }

    /// Only `com.passwordpie.cli` of our team, bound to the running code's cdhash.
    public static let isPasswordPieCLI: @Sendable (Int32) -> Bool = { fd in
        PeerIdentity.verifiedIdentifier(ofPeer: fd, allowed: [AgentConstants.cliIdentifier]) != nil
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return listener >= 0
    }

    /// Fails when the group container is missing or another running copy of PasswordPie already listens.
    public func start(path: String? = nil) throws {
        let socketPath = try path ?? AgentConstants.defaultSocketPath()
        let fd = try BridgeSocket.listen(path: socketPath)
        lock.lock()
        listener = fd
        self.path = socketPath
        lock.unlock()
        Thread.detachNewThread { [self] in acceptLoop(fd) }
    }

    /// Closes the socket and every connection, and removes the socket file: no socket while agent access is off.
    public func stop() {
        lock.lock()
        let fd = listener
        let socketPath = path
        let open = connections
        listener = -1
        path = nil
        lock.unlock()
        guard fd >= 0 else { return }
        if let socketPath { unlink(socketPath) }
        shutdown(fd, SHUT_RDWR)
        close(fd)
        for connection in open { shutdown(connection, SHUT_RDWR) }
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                switch errno {
                case EINTR, ECONNABORTED: continue
                case EBADF, EINVAL, ENOTSOCK: return
                default:
                    lock.lock()
                    let stopped = listener != fd
                    lock.unlock()
                    if stopped { return }
                    usleep(100_000)
                    continue
                }
            }
            lock.lock()
            let current = listener == fd
            if current { connections.insert(client) }
            lock.unlock()
            guard current else {
                close(client)
                return
            }
            Thread.detachNewThread { [self] in serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        defer {
            lock.lock()
            connections.remove(fd)
            lock.unlock()
            close(fd)
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard peerCheck(fd), let pid = Self.peerPID(fd) else { return }
        var reader = BridgeFrame.Reader()
        var pending: [Data] = []
        while let frame = try? BridgeSocket.readFrame(fd, reader: &reader, pending: &pending) {
            let answer: AgentResponse
            if let request = AgentCoding.decode(AgentRequest.self, from: frame) {
                // Every request, not once per connection: the agent that started the tool may have gone meanwhile.
                if let caller = identify(pid) {
                    answer = Self.wait(handler, request, caller, fd: fd)
                } else {
                    answer = .error(.appUnavailable, id: request.id)
                }
            } else {
                answer = .error(.usage, id: 0)
            }
            guard (try? BridgeSocket.writeAll(fd, BridgeFrame.encode(AgentCoding.encode(answer)))) != nil else { return }
        }
    }

    /// The peer's pid, from the kernel's audit token for the connection.
    static func peerPID(_ fd: Int32) -> Int32? {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return nil }
        // audit_token_to_pid(): the pid is the token's sixth word.
        let pid = Int32(bitPattern: token.val.5)
        return pid > 0 ? pid : nil
    }

    /// Runs the async handler on the main actor and blocks this connection's thread until it answers. When the tool hangs
    /// up meanwhile (the agent killed it), the request is cancelled: a prompt for it is withdrawn, a wait ends.
    private static func wait(_ handler: @escaping Handler, _ request: AgentRequest, _ caller: AgentCaller, fd: Int32) -> AgentResponse {
        let done = DispatchSemaphore(value: 0)
        let box = AnswerBox()
        let task = Task { @MainActor in
            box.answer = await handler(request, caller)
            done.signal()
        }
        while done.wait(timeout: .now() + 0.25) == .timedOut {
            if peerHungUp(fd) {
                task.cancel()
                done.wait()
                break
            }
        }
        return box.answer ?? .error(.appUnavailable, id: request.id)
    }

    /// The tool sends nothing while it waits for an answer, so anything readable is the end of the connection.
    static func peerHungUp(_ fd: Int32) -> Bool {
        var polled = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&polled, 1, 0) > 0 else { return false }
        if polled.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return true }
        var byte: UInt8 = 0
        return recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) == 0
    }
}

private final class AnswerBox: @unchecked Sendable {
    var answer: AgentResponse?
}
