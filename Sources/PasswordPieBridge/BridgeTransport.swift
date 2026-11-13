import Darwin
import Foundation
import Security

// The transport between PasswordPie and its browser extensions: a Unix socket in the App Group container, framed like
// Chrome native messaging, with the peer's code signature checked on both ends. See docs/BROWSER_EXTENSION.md.
// This file never logs or keeps a frame's contents.

public enum BridgeConstants {
    public static let teamID = "2S468LUF8V"
    public static let appGroup = "2S468LUF8V.com.passwordpie"
    public static let socketName = "bridge.sock"
    public static let appIdentifier = "com.passwordpie"
    public static let chromeHostIdentifier = "com.passwordpie.browser-host"
    public static let safariExtensionIdentifier = "com.passwordpie.safari"
    /// The native messaging host name the extension connects to (extension 0.5.0 and later).
    public static let nativeHostName = "com.passwordpie"
    /// The name the Chrome Web Store extension up to 0.4.0 connects to, from before the move to `com.passwordpie`. The app
    /// installs a manifest under both names for the same host. Remove this once the store's live version is 0.5.0 or later
    /// (docs/BROWSER_EXTENSION.md, "Host manifests").
    public static let legacyNativeHostName = "com.oldcai.passwordpie"
    /// Every name the app installs a host manifest under.
    public static let nativeHostNames = [nativeHostName, legacyNativeHostName]
    /// The Chrome Web Store item's ID. `CHROME_KEY` in extension/manifest.ts is the store's public key, so an unpacked
    /// development build gets the same ID (extension/tests/extension-id.test.ts checks they match). See
    /// docs/BROWSER_EXTENSION.md, "Chrome".
    public static let chromeExtensionID = "ebgkjnfglbkeckkknmeakpkbdpjndjhk"
    /// The extension IDs Chrome may start the host for.
    public static let chromeExtensionIDs = [chromeExtensionID]
    /// Google Chrome's signing team and identifier. The host only serves a parent process signed with them. Only stable
    /// Chrome: the host manifest is written to its profile folder alone, and the app tells browsers apart by bundle ID,
    /// so Beta, Dev and Canary keep typed keystrokes in v1.
    public static let chromeTeamID = "EQHXZ8M8AV"
    public static let chromeIdentifiers: Set<String> = ["com.google.Chrome"]
}

public enum BridgeError: Error, Equatable {
    case noContainer
    case pathTooLong
    case frameTooLarge
    case closed
    case system(Int32)
}

/// A 32-bit little-endian length, then that many bytes of UTF-8 JSON. Frames over 1 MiB are refused.
public enum BridgeFrame {
    public static let maxLength = 1 << 20

    public static func encode(_ payload: Data) -> Data {
        var length = UInt32(payload.count).littleEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(payload)
        return frame
    }

    /// Collects bytes as they arrive and hands back whole frames.
    public struct Reader {
        private var buffer = Data()

        public init() {}

        public mutating func append(_ bytes: Data) throws -> [Data] {
            buffer.append(bytes)
            var frames: [Data] = []
            while buffer.count >= 4 {
                let start = buffer.startIndex
                let length = Int(buffer[start]) | Int(buffer[start + 1]) << 8 | Int(buffer[start + 2]) << 16 | Int(buffer[start + 3]) << 24
                guard length <= BridgeFrame.maxLength else {
                    buffer.removeAll()
                    throw BridgeError.frameTooLarge
                }
                guard buffer.count >= 4 + length else { break }
                frames.append(Data(buffer[(start + 4)..<(start + 4 + length)]))
                buffer.removeSubrange(start..<(start + 4 + length))
            }
            return frames
        }
    }
}

public enum BridgeSocket {
    /// `~/Library/Group Containers/<group>/bridge.sock`. Sandboxed processes need the App Group entitlement to see it.
    public static func defaultPath() throws -> String {
        var container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: BridgeConstants.appGroup)
        if container == nil, let home = getpwuid(getuid())?.pointee.pw_dir {
            container = URL(fileURLWithPath: String(cString: home)).appendingPathComponent("Library/Group Containers/\(BridgeConstants.appGroup)")
        }
        guard let container else { throw BridgeError.noContainer }
        try? FileManager.default.createDirectory(at: container, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return container.appendingPathComponent(BridgeConstants.socketName).path
    }

    private static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw BridgeError.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    private static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BridgeError.system(errno) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// A connected socket, or an error when nothing is listening.
    public static func connect(path: String) throws -> Int32 {
        var address = try address(path)
        let fd = try makeSocket()
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw BridgeError.system(code)
        }
        return fd
    }

    /// A listening socket at `path`. A socket file nobody answers on is replaced; one that answers belongs to another running
    /// copy of the app, and is left alone (`EADDRINUSE`).
    public static func listen(path: String) throws -> Int32 {
        if let live = try? connect(path: path) {
            close(live)
            throw BridgeError.system(EADDRINUSE)
        }
        unlink(path)
        var address = try address(path)
        let fd = try makeSocket()
        // Created owner-only, so it is never reachable by others, not even between bind and chmod.
        let previousMask = umask(0o077)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(previousMask)
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 8) == 0 else {
            let code = errno
            close(fd)
            throw BridgeError.system(code)
        }
        return fd
    }

    public static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = write(fd, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw BridgeError.system(errno)
                }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
        }
    }

    /// Blocks until one whole frame has arrived. Bytes after it stay in `reader`.
    public static func readFrame(_ fd: Int32, reader: inout BridgeFrame.Reader, pending: inout [Data]) throws -> Data {
        if !pending.isEmpty { return pending.removeFirst() }
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw BridgeError.system(errno)
            }
            guard count > 0 else { throw BridgeError.closed }
            pending += try reader.append(Data(chunk[0..<count]))
            if !pending.isEmpty { return pending.removeFirst() }
        }
    }

    /// Sets a receive and send timeout, so a client never hangs on an app that stopped answering.
    public static func setTimeout(_ fd: Int32, seconds: Int) {
        var value = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }
}

/// Who is on the other end of a connected Unix socket, or who a process is, from its code signature.
public enum PeerIdentity {
    /// The peer's signing identifier when it is validly signed by an Apple-issued certificate of `teamID` and the
    /// identifier is one of `allowed`; otherwise nil. The kernel's audit token names the exact process.
    public static func verifiedIdentifier(ofPeer fd: Int32, allowed: Set<String>, teamID: String = BridgeConstants.teamID) -> String? {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return nil }
        let tokenData = Data(bytes: &token, count: Int(length))
        return verifiedIdentifier(guest: [kSecGuestAttributeAudit: tokenData], allowed: allowed, teamID: teamID)
    }

    /// The same check for a process by pid. Only for a pid that cannot be reused meanwhile, such as this process's parent.
    public static func verifiedIdentifier(ofProcess pid: pid_t, allowed: Set<String>, teamID: String) -> String? {
        verifiedIdentifier(guest: [kSecGuestAttributePid: NSNumber(value: pid)], allowed: allowed, teamID: teamID)
    }

    /// Team and identifier are read from the signature on disk, and then bound to the running code: the validity check
    /// requires the code directory hash read with them, so a binary swapped on disk in between fails.
    private static func verifiedIdentifier(guest: [CFString: Any], allowed: Set<String>, teamID: String) -> String? {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, guest as CFDictionary, [], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let details = info as? [String: Any],
              details[kSecCodeInfoTeamIdentifier as String] as? String == teamID,
              let identifier = details[kSecCodeInfoIdentifier as String] as? String,
              allowed.contains(identifier),
              let cdhash = details[kSecCodeInfoUnique as String] as? Data, !cdhash.isEmpty else { return nil }
        let hex = cdhash.map { String(format: "%02x", $0) }.joined()
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple generic and cdhash H\"\(hex)\"" as CFString, [], &requirement) == errSecSuccess,
              SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return nil }
        return identifier
    }
}

/// One request and its answer, for the Safari app extension, which opens a connection per message.
public enum BridgeClient {
    /// Sends `payload` (one JSON message) to the app and returns its answer. Fails when the app is not running, does not
    /// answer within `timeout` seconds, or is not PasswordPie signed by our team.
    public static func request(_ payload: Data, path: String? = nil, timeout: Int = 5, verifyServer: Bool = true) throws -> Data {
        let fd = try connect(path: path, verifyServer: verifyServer)
        defer { close(fd) }
        BridgeSocket.setTimeout(fd, seconds: timeout)
        try BridgeSocket.writeAll(fd, BridgeFrame.encode(payload))
        var reader = BridgeFrame.Reader()
        var pending: [Data] = []
        return try BridgeSocket.readFrame(fd, reader: &reader, pending: &pending)
    }

    /// A connection to the app, checked to be PasswordPie.
    public static func connect(path: String? = nil, verifyServer: Bool = true) throws -> Int32 {
        let fd = try BridgeSocket.connect(path: path ?? BridgeSocket.defaultPath())
        if verifyServer, PeerIdentity.verifiedIdentifier(ofPeer: fd, allowed: [BridgeConstants.appIdentifier]) == nil {
            close(fd)
            throw BridgeError.system(EPERM)
        }
        return fd
    }
}
