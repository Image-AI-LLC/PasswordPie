import Darwin
import Foundation
import XCTest
@testable import PasswordPieBridge

final class BridgeFrameTests: XCTestCase {
    func testEncodeIsLittleEndianLengthThenPayload() {
        let frame = BridgeFrame.encode(Data("{}".utf8))
        XCTAssertEqual(Array(frame), [2, 0, 0, 0, 0x7B, 0x7D])
    }

    func testReaderJoinsSplitDeliveryAndSplitsBackToBack() throws {
        var reader = BridgeFrame.Reader()
        let both = BridgeFrame.encode(Data("one".utf8)) + BridgeFrame.encode(Data("two!".utf8))
        XCTAssertEqual(try reader.append(both.prefix(2)), [])
        XCTAssertEqual(try reader.append(both.dropFirst(2).prefix(4)), [])
        let frames = try reader.append(both.dropFirst(6))
        XCTAssertEqual(frames.map { String(decoding: $0, as: UTF8.self) }, ["one", "two!"])
    }

    func testEmptyFrame() throws {
        var reader = BridgeFrame.Reader()
        XCTAssertEqual(try reader.append(BridgeFrame.encode(Data())), [Data()])
    }

    func testOversizedFrameIsRefused() {
        var reader = BridgeFrame.Reader()
        var length = UInt32(BridgeFrame.maxLength + 1).littleEndian
        let header = Data(bytes: &length, count: 4)
        XCTAssertThrowsError(try reader.append(header)) { XCTAssertEqual($0 as? BridgeError, .frameTooLarge) }
    }
}

final class BridgeSocketTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        // sun_path is 104 bytes, so the test socket lives under /tmp rather than the long per-test temporary folder.
        directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("ppb-\(getpid())-\(Int.random(in: 0..<1_000_000))")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRoundTripThroughASocket() throws {
        let path = directory.appendingPathComponent("s").path
        let server = try BridgeSocket.listen(path: path)
        defer { close(server) }
        let served = expectation(description: "served")
        Thread.detachNewThread {
            let client = accept(server, nil, nil)
            var reader = BridgeFrame.Reader()
            var pending: [Data] = []
            if let request = try? BridgeSocket.readFrame(client, reader: &reader, pending: &pending) {
                try? BridgeSocket.writeAll(client, BridgeFrame.encode(Data("echo:".utf8) + request))
            }
            close(client)
            served.fulfill()
        }
        let answer = try BridgeClient.request(Data("hi".utf8), path: path, timeout: 2, verifyServer: false)
        XCTAssertEqual(String(decoding: answer, as: UTF8.self), "echo:hi")
        wait(for: [served], timeout: 2)
    }

    func testSocketFileIsOwnerOnly() throws {
        let path = directory.appendingPathComponent("s").path
        let server = try BridgeSocket.listen(path: path)
        defer { close(server) }
        let mode = (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o600)
    }

    func testALiveSocketIsNotTakenOver() throws {
        let path = directory.appendingPathComponent("s").path
        let first = try BridgeSocket.listen(path: path)
        defer { close(first) }
        XCTAssertThrowsError(try BridgeSocket.listen(path: path)) { XCTAssertEqual($0 as? BridgeError, .system(EADDRINUSE)) }
    }

    func testAStaleSocketFileIsReplaced() throws {
        let path = directory.appendingPathComponent("s").path
        close(try BridgeSocket.listen(path: path))
        let second = try BridgeSocket.listen(path: path)
        close(second)
    }

    func testNothingListening() {
        XCTAssertThrowsError(try BridgeClient.request(Data("x".utf8), path: directory.appendingPathComponent("none").path, verifyServer: false))
    }

    func testTooLongAPath() {
        let path = "/tmp/" + String(repeating: "x", count: 200)
        XCTAssertThrowsError(try BridgeSocket.listen(path: path)) { XCTAssertEqual($0 as? BridgeError, .pathTooLong) }
    }

    func testUnsignedPeerIsNotVerified() throws {
        // The test runner is ad hoc signed, so it is never one of ours.
        let path = directory.appendingPathComponent("s").path
        let server = try BridgeSocket.listen(path: path)
        defer { close(server) }
        let client = try BridgeSocket.connect(path: path)
        defer { close(client) }
        let accepted = accept(server, nil, nil)
        defer { close(accepted) }
        XCTAssertNil(PeerIdentity.verifiedIdentifier(ofPeer: accepted, allowed: [BridgeConstants.appIdentifier]))
        XCTAssertThrowsError(try BridgeClient.connect(path: path, verifyServer: true))
    }

    func testDefaultPathIsInTheGroupContainer() throws {
        let path = try BridgeSocket.defaultPath()
        XCTAssertTrue(path.hasSuffix("Group Containers/\(BridgeConstants.appGroup)/bridge.sock"), path)
        XCTAssertLessThan(path.utf8.count, 104)
    }
}
