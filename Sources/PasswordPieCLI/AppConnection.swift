import AppKit
import Darwin
import Foundation
import PasswordPieAgent
import PasswordPieBridge

/// One request to the app over `agent.sock`, starting PasswordPie first when it is not running.
enum AppConnection {
    struct Failure: Error {
        var code: AgentErrorCode
        var detail: String?
    }

    /// The socket, and whether the server must be PasswordPie. Tests (debug builds only) point the tool at their own
    /// server; a release build always talks to the real socket and checks the app's signature.
    static var socketPath: String? {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["PASSWORDPIE_AGENT_SOCKET"] { return path }
        #endif
        return try? AgentConstants.defaultSocketPath()
    }

    static var verifiesServer: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["PASSWORDPIE_AGENT_SOCKET"] == nil
        #else
        return true
        #endif
    }

    static var launchesApp: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["PASSWORDPIE_AGENT_SOCKET"] == nil
        #else
        return true
        #endif
    }

    /// How long the tool waits for an answer beyond the unlock wait: a request can queue behind other prompts of the
    /// same agent session, each up to the 2-minute approval window. The app enforces the real limits.
    static let answerSeconds = 30 * 60

    /// Sends `request` and waits for the answer.
    static func send(_ request: AgentRequest) -> Result<AgentResponse, Failure> {
        let fd: Int32
        switch connect(startingApp: request.type != .status) {
        case .success(let connected): fd = connected
        case .failure(let failure): return .failure(failure)
        }
        defer { close(fd) }
        let seconds = (request.wait ?? AgentConstants.defaultWaitSeconds) + answerSeconds
        BridgeSocket.setTimeout(fd, seconds: seconds)
        guard (try? BridgeSocket.writeAll(fd, BridgeFrame.encode(AgentCoding.encode(request)))) != nil else {
            return .failure(Failure(code: .appUnavailable, detail: "PasswordPie closed the connection."))
        }
        var reader = BridgeFrame.Reader()
        var pending: [Data] = []
        guard let frame = try? BridgeSocket.readFrame(fd, reader: &reader, pending: &pending),
              let answer = AgentCoding.decode(AgentResponse.self, from: frame) else {
            return .failure(Failure(code: .appUnavailable, detail: "PasswordPie did not answer."))
        }
        return .success(answer)
    }

    /// A connection checked to be PasswordPie. When nothing listens: the app is not running (start it and wait), or it
    /// runs with agent access off (no socket at all).
    static func connect(startingApp: Bool) -> Result<Int32, Failure> {
        guard let path = socketPath else { return .failure(Failure(code: .appUnavailable, detail: "The PasswordPie folder is missing.")) }
        func attempt() -> Result<Int32, Failure>? {
            guard let fd = try? BridgeSocket.connect(path: path) else { return nil }
            if verifiesServer, PeerIdentity.verifiedIdentifier(ofPeer: fd, allowed: [BridgeConstants.appIdentifier]) == nil {
                close(fd)
                return .failure(Failure(code: .appUnavailable, detail: "The program answering on agent.sock is not PasswordPie."))
            }
            return .success(fd)
        }
        if let result = attempt() { return result }
        guard launchesApp else { return .failure(Failure(code: .appUnavailable, detail: nil)) }
        var found: Result<Int32, Failure>?
        if AppLaunch.isAppRunning() {
            // Running without a socket: agent access is off, or the app is just starting.
            _ = AppLaunch.retry(for: 2) {
                found = attempt()
                return found != nil
            }
            return found ?? .failure(Failure(code: .accessOff, detail: nil))
        }
        guard startingApp, let app = appBundle() else {
            return .failure(Failure(code: .appUnavailable, detail: "PasswordPie is not running."))
        }
        AppLaunch.open(app)
        _ = AppLaunch.retry(for: 10) {
            found = attempt()
            return found != nil
        }
        if let found { return found }
        return .failure(AppLaunch.isAppRunning() ? Failure(code: .accessOff, detail: nil) : Failure(code: .appUnavailable, detail: "PasswordPie did not start."))
    }

    /// The app this tool is inside, through any link on the PATH; else the installed one.
    static func appBundle() -> URL? {
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath(), let app = AppLaunch.containingApp(of: executable) {
            return app
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: BridgeConstants.appIdentifier)
    }

    static var version: String {
        guard let app = appBundle(), let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let version = info["CFBundleShortVersionString"] as? String else { return "development" }
        return version
    }
}
