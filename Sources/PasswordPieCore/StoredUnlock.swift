import Foundation

/// The secret kept in the login keychain for one database.
///
/// A password alone is the raw UTF-8 password, which is what older builds stored.
/// A KeePass 1 key file is wrapped with a checksum so a password that happens to
/// start with the wrapper marker is still read as a password.
public struct StoredUnlock: Equatable, Sendable {
    public var password: String
    public var keyFile: Data?

    public init(password: String, keyFile: Data? = nil) {
        self.password = password
        self.keyFile = keyFile?.isEmpty == true ? nil : keyFile
    }

    public var encoded: Data {
        guard let keyFile else { return Data(password.utf8) }
        let passwordBytes = Data(password.utf8)
        var payload = Data()
        var length = UInt32(passwordBytes.count).littleEndian
        payload.append(Data(bytes: &length, count: 4))
        payload.append(passwordBytes)
        payload.append(keyFile)
        var checksum = StoredUnlock.fnv32(payload).littleEndian
        var data = Data("PPKF".utf8)
        data.append(Data(bytes: &checksum, count: 4))
        data.append(payload)
        return data
    }

    public init?(stored data: Data) {
        if let parsed = Self.envelope(data) {
            self = parsed
            return
        }
        guard let password = String(data: data, encoding: .utf8), !password.isEmpty else { return nil }
        self.password = password
        self.keyFile = nil
    }

    private static func envelope(_ data: Data) -> StoredUnlock? {
        guard data.starts(with: Data("PPKF".utf8)), data.count >= 12 else { return nil }
        let checksum = readU32LE(data, 4)
        let payload = data.subdata(in: 8..<data.count)
        guard fnv32(payload) == checksum else { return nil }
        let length = Int(readU32LE(payload, 0))
        guard payload.count >= 4 + length else { return nil }
        let passwordData = payload.subdata(in: 4..<(4 + length))
        guard let password = String(data: passwordData, encoding: .utf8) else { return nil }
        let key = payload.subdata(in: (4 + length)..<payload.count)
        guard !key.isEmpty else { return nil }
        return StoredUnlock(password: password, keyFile: key)
    }

    private static func fnv32(_ data: Data) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in data {
            hash ^= UInt32(byte)
            hash &*= 16_777_619
        }
        return hash
    }
}
