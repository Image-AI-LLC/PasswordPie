import Foundation
import PasswordPieBridge
import PasswordPieCore
import XCTest
@testable import PasswordPie

/// The server's side of a browser the person refused (docs/BROWSER_EXTENSION.md, "held"): real sockets, with the peer's
/// signature check stood in for, since a test cannot be signed as the Chrome host.
@MainActor
final class BrowserBridgeHeldConnectionTests: XCTestCase {
    private let ego = ChromiumBrowserIdentity(
        bundleID: "com.example.passwordpie-tests.ego", teamID: "JGQLC6YQYJ",
        bundleURL: URL(fileURLWithPath: "/tmp/ego lite.app"), name: "ego lite", signer: "CITRO LABS PTE. LIMITED"
    )
    private var path: String!
    private var server: BrowserBridgeServer?

    /// What the main actor saw, read by the assertions.
    private var served: [String] = []
    private var ruled: [String] = []
    private var peers: [Set<BridgePeer>] = []
    private var apps: [BridgePeer: ChromiumBrowserIdentity] = [:]
    private var allowed = false
    private var record = true

    override func setUpWithError() throws {
        try XCTSkipUnless(BrowserBridge.chromeSupported, "Chrome is in the direct channel only")
        path = FileManager.default.temporaryDirectory.appendingPathComponent("ppb-\(UUID().uuidString.prefix(8)).sock").path
        let ego = ego
        let server = BrowserBridgeServer(
            handler: { [weak self] frame, _ in
                self?.served.append(String(decoding: frame, as: UTF8.self))
                return Data(#"{"type":"tab","id":3}"#.utf8)
            },
            changed: { [weak self] peers, apps in
                self?.peers.append(peers)
                self?.apps = apps
            },
            // The person said no to this browser before.
            approve: { _, answer in answer(false) },
            refused: { [weak self] frame, _ in
                guard let self else { return .close }
                let text = String(decoding: frame, as: UTF8.self)
                self.ruled.append(text)
                if !self.record { return .close }
                if self.allowed { return .admit }
                return .hold(answer: text.contains("show") ? Data(#"{"type":"show","id":2}"#.utf8) : nil)
            },
            identify: { _ in (.chrome, ego) }
        )
        try server.start(path: path)
        self.server = server
    }

    override func tearDown() {
        server?.stop()
        server = nil
        if let path { try? FileManager.default.removeItem(atPath: path) }
    }

    /// One client connection, driven off the main thread so the main actor can answer the server.
    private final class Client: @unchecked Sendable {
        let fd: Int32
        private var reader = BridgeFrame.Reader()
        private var pending: [Data] = []

        init(path: String) throws { fd = try BridgeSocket.connect(path: path) }
        deinit { close(fd) }

        func send(_ text: String) throws { try BridgeSocket.writeAll(fd, BridgeFrame.encode(Data(text.utf8))) }
        func read() throws -> String { String(decoding: try BridgeSocket.readFrame(fd, reader: &reader, pending: &pending), as: UTF8.self) }
    }

    private func background(_ name: String, _ work: @escaping @Sendable () throws -> Void) -> XCTestExpectation {
        let done = expectation(description: name)
        DispatchQueue.global().async {
            do { try work() } catch { XCTFail("\(name): \(error)") }
            done.fulfill()
        }
        return done
    }

    func testARefusedBrowserIsHeldUnansweredUntilThePersonAllowsIt() async throws {
        let client = try Client(path: path)
        let box = Box()

        // Held: the tab report gets no answer, the toolbar button gets its own; the first frame read is the button's.
        await fulfillment(of: [background("held") {
            try client.send(#"{"type":"tab","id":1,"url":"https://github.com/login"}"#)
            try client.send(#"{"type":"show","id":2}"#)
            box.set("first", try client.read())
        }], timeout: 10)
        XCTAssertEqual(box.get("first"), #"{"type":"show","id":2}"#)
        XCTAssertEqual(ruled.count, 2, "both frames were ruled on")
        XCTAssertTrue(served.isEmpty, "nothing a refused browser sends reaches the bridge")
        XCTAssertTrue(peers.allSatisfy(\.isEmpty), "a held connection is not a connected profile")

        // The person allows it: the held connection is poked, and its next frame is served.
        allowed = true
        server?.pushToHeld(Data(#"{"type":"poke"}"#.utf8), app: ego.bundleID, teamID: ego.teamID)
        await fulfillment(of: [background("admitted") {
            box.set("poke", try client.read())
            try client.send(#"{"type":"tab","id":3,"url":"https://github.com/login"}"#)
            box.set("answer", try client.read())
        }], timeout: 10)
        XCTAssertEqual(box.get("poke"), #"{"type":"poke"}"#)
        XCTAssertEqual(box.get("answer"), #"{"type":"tab","id":3}"#)
        XCTAssertEqual(served, [#"{"type":"tab","id":3,"url":"https://github.com/login"}"#], "the frame that found it allowed is served, not dropped")
        // The report is queued to the main actor; let it land.
        await fulfillment(of: [background("settle") { usleep(200_000) }], timeout: 5)
        XCTAssertEqual(peers.last?.count, 1)
        XCTAssertEqual(apps.values.map(\.bundleID), [ego.bundleID])

        // A push to held connections no longer reaches it: it is a connected profile now.
        server?.pushToHeld(Data(#"{"type":"poke"}"#.utf8), app: ego.bundleID, teamID: ego.teamID)
        server?.push(Data(#"{"type":"fill"}"#.utf8), to: .chrome)
        await fulfillment(of: [background("pushed") { box.set("pushed", try client.read()) }], timeout: 10)
        XCTAssertEqual(box.get("pushed"), #"{"type":"fill"}"#)
    }

    func testAPushToConnectedProfilesNeverReachesAHeldConnection() async throws {
        let client = try Client(path: path)
        let box = Box()
        await fulfillment(of: [background("held") {
            try client.send(#"{"type":"show","id":2}"#)
            box.set("first", try client.read())
        }], timeout: 10)
        // A fill for Chrome, then the marker only held connections get: the held one reads the marker first.
        server?.push(Data(#"{"type":"fill"}"#.utf8), to: .chrome)
        await fulfillment(of: [background("settle") { usleep(200_000) }], timeout: 5)
        server?.pushToHeld(Data(#"{"type":"poke"}"#.utf8), app: ego.bundleID, teamID: ego.teamID)
        await fulfillment(of: [background("marker") { box.set("next", try client.read()) }], timeout: 10)
        XCTAssertEqual(box.get("next"), #"{"type":"poke"}"#)
        // Another browser's held connections are not this one's.
        server?.pushToHeld(Data(#"{"type":"other"}"#.utf8), app: "com.example.other", teamID: ego.teamID)
        server?.pushToHeld(Data(#"{"type":"other"}"#.utf8), app: ego.bundleID, teamID: "ZZZZZZZZZZ")
        server?.pushToHeld(Data(#"{"type":"mine"}"#.utf8), app: ego.bundleID, teamID: ego.teamID)
        await fulfillment(of: [background("mine") { box.set("mine", try client.read()) }], timeout: 10)
        XCTAssertEqual(box.get("mine"), #"{"type":"mine"}"#)
    }

    func testAConnectionWithNoAnswerOnRecordIsClosed() async throws {
        record = false
        let client = try Client(path: path)
        let box = Box()
        await fulfillment(of: [background("closed") {
            try client.send(#"{"type":"hello","id":1}"#)
            box.set("read", (try? client.read()) ?? "closed")
        }], timeout: 10)
        XCTAssertEqual(box.get("read"), "closed")
        XCTAssertTrue(served.isEmpty)
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]
        func set(_ key: String, _ value: String) { lock.lock(); values[key] = value; lock.unlock() }
        func get(_ key: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[key] }
    }
}
