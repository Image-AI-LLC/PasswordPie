import Darwin
import Foundation
import PasswordPieBridge
import PasswordPieCore

/// The app's end of the bridge socket. It accepts only the Safari app extension and the Chrome host, as their code
/// signatures say, answers each frame on the main actor, and can push frames to every open Chrome connection.
/// Frames are never logged. See docs/BROWSER_EXTENSION.md.
final class BrowserBridgeServer: @unchecked Sendable {
    /// Answers one frame from `browser`. Nil sends nothing back.
    typealias Handler = @MainActor (Data, BridgeBrowser) -> Data?
    /// The number of open connections per browser changed.
    typealias Changed = @MainActor ([BridgeBrowser: Int]) -> Void

    private static let peers: [String: BridgeBrowser] = [
        BridgeConstants.chromeHostIdentifier: .chrome,
        BridgeConstants.safariExtensionIdentifier: .safari
    ]

    private final class Connection: @unchecked Sendable {
        let fd: Int32
        let browser: BridgeBrowser
        private let writeLock = NSLock()

        init(fd: Int32, browser: BridgeBrowser) {
            self.fd = fd
            self.browser = browser
        }

        func send(_ payload: Data) {
            writeLock.lock()
            defer { writeLock.unlock() }
            if (try? BridgeSocket.writeAll(fd, BridgeFrame.encode(payload))) == nil {
                shutdown(fd, SHUT_RDWR)
            }
        }
    }

    private let handler: Handler
    private let changed: Changed
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var connections: [ObjectIdentifier: Connection] = [:]

    init(handler: @escaping Handler, changed: @escaping Changed) {
        self.handler = handler
        self.changed = changed
    }

    /// Fails when the group container is missing or another running copy of PasswordPie already listens.
    func start(path: String? = nil) throws {
        let fd = try BridgeSocket.listen(path: path ?? BridgeSocket.defaultPath())
        lock.lock()
        listener = fd
        lock.unlock()
        Thread.detachNewThread { [self] in acceptLoop(fd) }
    }

    func push(_ payload: Data, to browser: BridgeBrowser) {
        lock.lock()
        let targets = connections.values.filter { $0.browser == browser }
        lock.unlock()
        for connection in targets {
            DispatchQueue.global(qos: .userInitiated).async { connection.send(payload) }
        }
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return
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
        guard let identifier = PeerIdentity.verifiedIdentifier(ofPeer: fd, allowed: Set(Self.peers.keys)),
              let browser = Self.peers[identifier] else {
            close(fd)
            return
        }
        let connection = Connection(fd: fd, browser: browser)
        register(connection)
        var reader = BridgeFrame.Reader()
        var pending: [Data] = []
        while let frame = try? BridgeSocket.readFrame(fd, reader: &reader, pending: &pending) {
            let handler = handler
            let answer = DispatchQueue.main.sync { MainActor.assumeIsolated { handler(frame, browser) } }
            if let answer { connection.send(answer) }
        }
        unregister(connection)
        close(fd)
    }

    private func register(_ connection: Connection) {
        lock.lock()
        connections[ObjectIdentifier(connection)] = connection
        let counts = countsLocked()
        lock.unlock()
        report(counts)
    }

    private func unregister(_ connection: Connection) {
        lock.lock()
        connections[ObjectIdentifier(connection)] = nil
        let counts = countsLocked()
        lock.unlock()
        report(counts)
    }

    private func countsLocked() -> [BridgeBrowser: Int] {
        var counts: [BridgeBrowser: Int] = [:]
        for connection in connections.values { counts[connection.browser, default: 0] += 1 }
        return counts
    }

    private func report(_ counts: [BridgeBrowser: Int]) {
        let changed = changed
        DispatchQueue.main.async { MainActor.assumeIsolated { changed(counts) } }
    }
}
