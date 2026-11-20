import Darwin
import Foundation
import PasswordPieBridge
import PasswordPieCore

/// The app's end of the bridge socket. It accepts only the Safari app extension and the Chrome host, as their code
/// signatures say, answers each frame on the main actor, and can push frames to the open Chrome connections: one per
/// profile with the extension, in Chrome or another browser built on Chromium, numbered as they arrive. A Chrome host
/// gets in only when the browser that started it is a signed Chromium browser the person allowed (`Approve`). One the
/// person refused is held: its connection stays open, unregistered, and each frame it sends is ruled on by `Refused`.
/// Frames are never logged. See docs/BROWSER_EXTENSION.md.
final class BrowserBridgeServer: @unchecked Sendable {
    /// Answers one frame from `peer`. Nil sends nothing back.
    typealias Handler = @MainActor (Data, BridgePeer) -> Data?
    /// The open connections changed, with the browser each Chrome connection is in.
    typealias Changed = @MainActor (Set<BridgePeer>, [BridgePeer: ChromiumBrowserIdentity]) -> Void
    /// Whether a browser may connect: answered at once for one already decided, or after the person was asked.
    typealias Approve = @MainActor (ChromiumBrowserIdentity, @escaping @MainActor (Bool) -> Void) -> Void
    /// What to do with a frame from a browser the person refused (`BrowserBridge.refusedFrame`).
    typealias Refused = @MainActor (Data, ChromiumBrowserIdentity) -> BrowserBridge.RefusedFrame
    /// Who is at the other end of an accepted socket: which extension, and for Chrome's host the browser that started
    /// it. Nil refuses the connection. Replaced in tests, which cannot be signed as the host.
    typealias Identify = @Sendable (Int32) -> (browser: BridgeBrowser, app: ChromiumBrowserIdentity?)?

    private static let peers: [String: BridgeBrowser] = [
        BridgeConstants.chromeHostIdentifier: .chrome,
        BridgeConstants.safariExtensionIdentifier: .safari
    ]

    private final class Connection: @unchecked Sendable {
        let fd: Int32
        let peer: BridgePeer
        /// The browser that started the Chrome host. Nil for Safari.
        let browserApp: ChromiumBrowserIdentity?
        private let writeLock = NSLock()
        private var closed = false

        init(fd: Int32, peer: BridgePeer, browserApp: ChromiumBrowserIdentity? = nil) {
            self.fd = fd
            self.peer = peer
            self.browserApp = browserApp
        }

        /// Ends the connection from this side: the read loop sees it closed, and the host exits.
        func hangUp() {
            writeLock.lock()
            defer { writeLock.unlock() }
            guard !closed else { return }
            shutdown(fd, SHUT_RDWR)
        }

        /// A push can still be queued when the connection ends; once closed, the descriptor may belong to someone else.
        func send(_ payload: Data) {
            writeLock.lock()
            defer { writeLock.unlock() }
            guard !closed else { return }
            if (try? BridgeSocket.writeAll(fd, BridgeFrame.encode(payload))) == nil {
                shutdown(fd, SHUT_RDWR)
            }
        }

        func close() {
            writeLock.lock()
            defer { writeLock.unlock() }
            guard !closed else { return }
            closed = true
            Darwin.close(fd)
        }
    }

    private let handler: Handler
    private let changed: Changed
    private let approve: Approve
    private let refused: Refused
    private let identify: Identify
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var connections: [ObjectIdentifier: Connection] = [:]
    /// Connections of browsers the person refused: open, but not connected profiles.
    private var held: [ObjectIdentifier: Connection] = [:]
    /// The last number given to a Chrome connection. Each stays open, so each gets its own; Safari's come and go per
    /// message and share 0.
    private var lastLink = 0

    init(
        handler: @escaping Handler,
        changed: @escaping Changed,
        approve: @escaping Approve,
        refused: @escaping Refused = { _, _ in .close },
        identify: @escaping Identify = BrowserBridgeServer.verifiedPeer
    ) {
        self.handler = handler
        self.changed = changed
        self.approve = approve
        self.refused = refused
        self.identify = identify
    }

    /// The peer as its code signature says: the Safari app extension, or the Chrome host with the browser that started
    /// it. The host checked its parent too, but the app decides: that parent, the browser's main process, must be a
    /// signed Chromium browser.
    static let verifiedPeer: Identify = { fd in
        guard let identifier = PeerIdentity.verifiedIdentifier(ofPeer: fd, allowed: Set(peers.keys)),
              let browser = peers[identifier] else { return nil }
        guard browser == .chrome else { return (browser, nil) }
        guard let host = ChromiumBrowserCheck.peerPID(fd), let parent = ChromiumBrowserCheck.parentPID(of: host),
              let identity = ChromiumBrowserCheck.identity(ofProcess: parent) else { return nil }
        return (browser, identity)
    }

    /// Fails when the group container is missing or another running copy of PasswordPie already listens.
    func start(path: String? = nil) throws {
        let fd = try BridgeSocket.listen(path: path ?? BridgeSocket.defaultPath())
        lock.lock()
        listener = fd
        lock.unlock()
        Thread.detachNewThread { [self] in acceptLoop(fd) }
    }

    /// Stops accepting connections. The open ones end when their peers do.
    func stop() {
        lock.lock()
        let fd = listener
        listener = -1
        lock.unlock()
        if fd >= 0 { close(fd) }
    }

    /// Sends `payload` to one connection of `browser`, or to all of them when `link` is nil.
    func push(_ payload: Data, to browser: BridgeBrowser, link: Int? = nil) {
        lock.lock()
        let targets = connections.values.filter { $0.peer.browser == browser && (link == nil || $0.peer.link == link) }
        lock.unlock()
        for connection in targets {
            DispatchQueue.global(qos: .userInitiated).async { connection.send(payload) }
        }
    }

    /// Ends every connection from the browser app `bundleID` signed by `teamID`: the person no longer allows it.
    func disconnect(app bundleID: String, teamID: String) {
        lock.lock()
        let targets = connections.values.filter { $0.browserApp?.bundleID == bundleID && $0.browserApp?.teamID == teamID }
        lock.unlock()
        for connection in targets { connection.hangUp() }
    }

    /// Sends `payload` to the held connections of the browser app `bundleID` signed by `teamID`: a poke, after the
    /// person allowed it, so its extension speaks and is let in.
    func pushToHeld(_ payload: Data, app bundleID: String, teamID: String) {
        lock.lock()
        let targets = held.values.filter { $0.browserApp?.bundleID == bundleID && $0.browserApp?.teamID == teamID }
        lock.unlock()
        for connection in targets {
            DispatchQueue.global(qos: .userInitiated).async { connection.send(payload) }
        }
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                switch errno {
                case EINTR, ECONNABORTED: continue
                // The listener itself is gone.
                case EBADF, EINVAL, ENOTSOCK: return
                // Out of descriptors or memory for a moment: keep serving rather than stop for good.
                default:
                    usleep(100_000)
                    continue
                }
            }
            Thread.detachNewThread { [self] in serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        // A peer that stops reading must not block a write forever. Reads stay blocking: the Chrome host keeps its connection open.
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard let (browser, browserApp) = identify(fd) else {
            close(fd)
            return
        }
        let connection = Connection(fd: fd, peer: BridgePeer(browser, link: browser == .chrome ? nextLink() : 0), browserApp: browserApp)
        // A Chrome host gets in when the person allowed its browser. One they refused is held instead: open, so its
        // toolbar button can ask again, but not a connected profile.
        var admitted = browserApp.map(waitForApproval(of:)) ?? true
        if admitted { register(connection) } else { hold(connection) }
        var reader = BridgeFrame.Reader()
        var pending: [Data] = []
        while let frame = try? BridgeSocket.readFrame(fd, reader: &reader, pending: &pending) {
            if !admitted, let browserApp {
                let refused = refused
                switch DispatchQueue.main.sync(execute: { MainActor.assumeIsolated { refused(frame, browserApp) } }) {
                case .admit:
                    admitted = true
                    release(connection)
                    register(connection)
                case .hold(let answer):
                    if let answer { connection.send(answer) }
                    continue
                case .close:
                    release(connection)
                    connection.close()
                    return
                }
            }
            let handler = handler
            let peer = connection.peer
            let answer = DispatchQueue.main.sync { MainActor.assumeIsolated { handler(frame, peer) } }
            if let answer { connection.send(answer) }
        }
        if admitted { unregister(connection) } else { release(connection) }
        connection.close()
    }

    /// Blocks this connection's thread until the main actor has the person's answer. The host keeps its connection open
    /// meanwhile, so an Allow lets it in at once.
    private func waitForApproval(of identity: ChromiumBrowserIdentity) -> Bool {
        let answered = DispatchSemaphore(value: 0)
        let result = Answer()
        let approve = approve
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                approve(identity) { allowed in
                    result.set(allowed)
                    answered.signal()
                }
            }
        }
        answered.wait()
        return result.value
    }

    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var allowed = false
        var value: Bool {
            lock.lock()
            defer { lock.unlock() }
            return allowed
        }

        func set(_ value: Bool) {
            lock.lock()
            allowed = value
            lock.unlock()
        }
    }

    private func nextLink() -> Int {
        lock.lock()
        defer { lock.unlock() }
        lastLink += 1
        return lastLink
    }

    private func register(_ connection: Connection) {
        lock.lock()
        connections[ObjectIdentifier(connection)] = connection
        // Queued under the lock, so the main queue sees the connections in the order they were true.
        report()
        lock.unlock()
    }

    private func hold(_ connection: Connection) {
        lock.lock()
        held[ObjectIdentifier(connection)] = connection
        lock.unlock()
    }

    private func release(_ connection: Connection) {
        lock.lock()
        held[ObjectIdentifier(connection)] = nil
        lock.unlock()
    }

    private func unregister(_ connection: Connection) {
        lock.lock()
        connections[ObjectIdentifier(connection)] = nil
        // Queued under the lock, so the main queue sees the connections in the order they were true.
        report()
        lock.unlock()
    }

    /// Called under the lock.
    private func report() {
        let peers = Set(connections.values.map(\.peer))
        var apps: [BridgePeer: ChromiumBrowserIdentity] = [:]
        for connection in connections.values {
            if let app = connection.browserApp { apps[connection.peer] = app }
        }
        let changed = changed
        DispatchQueue.main.async { MainActor.assumeIsolated { changed(peers, apps) } }
    }
}
