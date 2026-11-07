import Darwin
import Foundation
import PasswordPieBridge

// PasswordPie's Chrome native messaging host. Chrome starts it for the PasswordPie extension and talks to it over
// stdin/stdout; it relays each frame to the PasswordPie app over the bridge socket and back. It keeps no state, and it
// never prints or logs a frame's contents. See docs/BROWSER_EXTENSION.md.

signal(SIGPIPE, SIG_IGN)

// Chrome passes the calling extension's origin first. The manifest's allowed_origins is the real gate; this is a second one.
let caller = CommandLine.arguments.dropFirst().first ?? ""
guard BridgeConstants.chromeExtensionIDs.contains(where: { caller == "chrome-extension://\($0)/" }) else {
    FileHandle.standardError.write(Data("PasswordPie: refused an unknown caller\n".utf8))
    exit(1)
}

final class Relay: @unchecked Sendable {
    private let lock = NSLock()
    private let outputLock = NSLock()
    private var socket: Int32 = -1

    /// Writes one frame to Chrome. Chrome reads the length in native byte order, which is little-endian on every Mac.
    func sendToChrome(_ payload: Data) {
        outputLock.lock()
        defer { outputLock.unlock() }
        try? BridgeSocket.writeAll(STDOUT_FILENO, BridgeFrame.encode(payload))
    }

    private var connected: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return socket
    }

    private func setSocket(_ fd: Int32) {
        lock.lock()
        socket = fd
        lock.unlock()
    }

    /// Keeps a connection to the app, reconnecting every second while the app is not running, and copies its frames to Chrome.
    func runAppSide() {
        while true {
            guard let fd = try? BridgeClient.connect() else {
                sleep(1)
                continue
            }
            setSocket(fd)
            var reader = BridgeFrame.Reader()
            var pending: [Data] = []
            while let frame = try? BridgeSocket.readFrame(fd, reader: &reader, pending: &pending) {
                sendToChrome(frame)
            }
            setSocket(-1)
            close(fd)
            sleep(1)
        }
    }

    /// Copies Chrome's frames to the app. Exits when Chrome closes stdin, which it does when the extension's port closes.
    func runChromeSide() -> Never {
        var reader = BridgeFrame.Reader()
        var pending: [Data] = []
        while true {
            let frame: Data
            do {
                frame = try BridgeSocket.readFrame(STDIN_FILENO, reader: &reader, pending: &pending)
            } catch {
                exit(0)
            }
            let fd = connected
            if fd >= 0, (try? BridgeSocket.writeAll(fd, BridgeFrame.encode(frame))) != nil { continue }
            sendToChrome(Self.unavailable(answering: frame))
        }
    }

    /// `{"type":"error","id":…,"code":"app-unavailable"}` for a request the app could not get.
    static func unavailable(answering frame: Data) -> Data {
        var answer: [String: Any] = ["type": "error", "code": "app-unavailable"]
        if let request = try? JSONSerialization.jsonObject(with: frame) as? [String: Any], let id = request["id"] as? Int {
            answer["id"] = id
        }
        return (try? JSONSerialization.data(withJSONObject: answer)) ?? Data(#"{"type":"error","code":"app-unavailable"}"#.utf8)
    }
}

let relay = Relay()
Thread.detachNewThread { relay.runAppSide() }
relay.runChromeSide()
