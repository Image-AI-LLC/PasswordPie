import CryptoKit
import Foundation
import Security

/// Why a key file could not be read. Never "wrong password": the file itself is the problem.
public enum KeyFileError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case empty
    case hashMismatch
    case unsupportedVersion(String)
    case invalid(String)
    case random(OSStatus)

    public var description: String {
        switch self {
        case .empty: return "The key file is empty."
        case .hashMismatch: return "The key file is damaged: its checksum does not match its key."
        case .unsupportedVersion(let version): return "This key file's version (\(version)) is not supported."
        case .invalid(let reason): return "The key file could not be read: \(reason)"
        case .random(let status): return "A new key could not be generated (\(status))."
        }
    }

    public var errorDescription: String? { description }
}

/// KeePass key files. A key file is a second key for a database: the composite key is
/// SHA-256(SHA-256(password) ‖ key), or SHA-256(key) with no password.
public enum KeyFile {
    /// The 32 bytes a key file contributes, read the way KeePassXC 2.7 and later read them: a KeePass XML key file
    /// first (1.0 Base64, or 2.0 hex with a checked hash), then exactly 32 bytes, then 64 hex characters, and anything
    /// else is hashed. A file whose root is `KeyFile` but cannot be read is an error, not an ordinary file.
    public static func key(from data: Data) throws -> Data {
        guard !data.isEmpty else { throw KeyFileError.empty }
        if let xml = try xmlKey(data) { return xml }
        if data.count == 32 { return data }
        if data.count == 64, let decoded = hexBytes(String(decoding: data, as: UTF8.self)), decoded.count == 32 {
            return decoded
        }
        return Data(SHA256.hash(data: data))
    }

    /// A new KeePass XML 2.0 key file holding 32 random bytes, laid out as KeePassXC writes it.
    public static func generate() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw KeyFileError.random(status) }
        return xmlVersion2(Data(bytes))
    }

    static func xmlVersion2(_ key: Data) -> Data {
        let hex = key.map { String(format: "%02X", $0) }.joined()
        let hash = Data(SHA256.hash(data: key)).prefix(4).map { String(format: "%02X", $0) }.joined()
        var groups: [String] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 8, limitedBy: hex.endIndex) ?? hex.endIndex
            groups.append(String(hex[index..<next]))
            index = next
        }
        var lines: [String] = []
        for start in stride(from: 0, to: groups.count, by: 4) {
            lines.append("            " + groups[start..<min(start + 4, groups.count)].joined(separator: " "))
        }
        let text = """
        <?xml version="1.0" encoding="UTF-8"?>
        <KeyFile>
            <Meta>
                <Version>2.0</Version>
            </Meta>
            <Key>
                <Data Hash="\(hash)">
        \(lines.joined(separator: "\n"))
                </Data>
            </Key>
        </KeyFile>

        """
        return Data(text.utf8)
    }

    /// Nil when the file is not a KeePass XML key file.
    private static func xmlKey(_ data: Data) throws -> Data? {
        guard looksLikeXML(data), let document = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]),
              let root = document.rootElement(), root.name == "KeyFile" else { return nil }
        let version = root.elements(forName: "Meta").first?.elements(forName: "Version").first?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let dataElement = root.elements(forName: "Key").first?.elements(forName: "Data").first else {
            throw KeyFileError.invalid("it has no key.")
        }
        let text = (dataElement.stringValue ?? "").filter { !$0.isWhitespace }
        let raw: Data
        if version.hasPrefix("1.0") {
            guard let decoded = Data(base64Encoded: text), !decoded.isEmpty else { throw KeyFileError.invalid("its key is not Base64.") }
            raw = decoded
        } else if version == "2.0" {
            guard let decoded = hexBytes(text), !decoded.isEmpty else { throw KeyFileError.invalid("its key is not hexadecimal.") }
            let expected = dataElement.attribute(forName: "Hash")?.stringValue.flatMap { hexBytes($0.filter { !$0.isWhitespace }) }
            guard let expected, expected == Data(SHA256.hash(data: decoded)).prefix(4) else { throw KeyFileError.hashMismatch }
            raw = decoded
        } else {
            throw KeyFileError.unsupportedVersion(version.isEmpty ? "none" : version)
        }
        // KeePassXC copies at most 32 bytes into a zeroed key.
        var key = Data(count: 32)
        key.replaceSubrange(0..<min(32, raw.count), with: raw.prefix(32))
        return key
    }

    /// Only text that starts like XML is parsed, so a random binary key never reaches the XML parser.
    private static func looksLikeXML(_ data: Data) -> Bool {
        var bytes = data.prefix(64)[...]
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        let first = bytes.first { ![0x20, 0x09, 0x0A, 0x0D].contains($0) }
        return first == UInt8(ascii: "<")
    }

    private static func hexBytes(_ text: String) -> Data? {
        let characters = Array(text.utf8)
        guard characters.count % 2 == 0 else { return nil }
        var out = Data(capacity: characters.count / 2)
        var index = 0
        while index < characters.count {
            guard let high = hexValue(characters[index]), let low = hexValue(characters[index + 1]) else { return nil }
            out.append(high << 4 | low)
            index += 2
        }
        return out
    }

    private static func hexValue(_ character: UInt8) -> UInt8? {
        switch character {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return character - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return character - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return character - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}

/// A key file kept in the login keychain for one database, with the name it was chosen under.
/// The bytes are the file's contents, not the derived key, so the lock screen can show what it holds.
public struct RememberedKeyFile: Equatable, Sendable {
    public var name: String
    public var data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }

    private static let marker = Data("PPKN".utf8)

    public var encoded: Data {
        let nameBytes = Data(name.utf8)
        var payload = Data()
        var length = UInt32(nameBytes.count).littleEndian
        payload.append(Data(bytes: &length, count: 4))
        payload.append(nameBytes)
        payload.append(data)
        var output = Self.marker
        output.append(Data(SHA256.hash(data: payload)).prefix(8))
        output.append(payload)
        return output
    }

    public init?(stored: Data) {
        let bytes = Data(stored)
        guard bytes.starts(with: Self.marker), bytes.count >= 16 else { return nil }
        let checksum = bytes.subdata(in: 4..<12)
        let payload = bytes.subdata(in: 12..<bytes.count)
        guard Data(SHA256.hash(data: payload)).prefix(8) == checksum, payload.count >= 4 else { return nil }
        let length = Int(payload.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        guard payload.count >= 4 + length else { return nil }
        let key = payload.subdata(in: (4 + length)..<payload.count)
        guard !key.isEmpty, let name = String(data: payload.subdata(in: 4..<(4 + length)), encoding: .utf8) else { return nil }
        self.name = name
        self.data = key
    }
}
