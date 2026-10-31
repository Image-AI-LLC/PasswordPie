import CryptoKit
import Foundation

func loadKeePass1(_ data: Data, password: String, keyFile: Data?) throws -> Vault {
    var cursor = ByteCursor(data: data)
    let signature1 = try cursor.u32()
    let signature2 = try cursor.u32()
    guard signature1 == 0x9AA2D903, signature2 == 0xB54BFB65 else { throw VaultOpenError.invalid("This is not a KeePass 1 database.") }
    let flags = try cursor.u32()
    guard flags & 2 != 0 || flags & 8 != 0 else { throw VaultOpenError.unsupported("This KeePass 1 database uses an unsupported cipher.") }
    let version = try cursor.u32()
    guard version & 0xFFFFFF00 == 0x00030000 else { throw VaultOpenError.unsupported("This KeePass 1 database version is not supported.") }
    let masterSeed = try cursor.take(16)
    let iv = try cursor.take(16)
    let groupCount = Int(try cursor.u32())
    let entryCount = Int(try cursor.u32())
    let contentHash = try cursor.take(32)
    let transformSeed = try cursor.take(32)
    let rounds = try cursor.u32()
    let cipherText = Data(data.suffix(from: cursor.offset))
    let keyMaterial = keepass1KeyMaterial(keyFile)

    var encodings = passwordEncodings(password)
    if encodings.isEmpty { encodings = [Data()] }
    var plain: Data?
    for encoded in encodings {
        let raw = keepass1Composite(password: encoded, keyFile: keyMaterial)
        let transformed = try aesKDF(raw, seed: transformSeed, rounds: rounds)
        let finalKey = importSHA256(masterSeed + transformed)
        let decrypted: Data
        if flags & 8 != 0 {
            decrypted = (try? Twofish.cbcDecrypt(cipherText, key: finalKey, iv: iv)) ?? Data()
        } else {
            decrypted = (try? aesCBCDecryptPKCS7(cipherText, key: finalKey, iv: iv)) ?? Data()
        }
        guard !decrypted.isEmpty, importSHA256(decrypted) == contentHash else { continue }
        plain = decrypted
        break
    }
    guard let plain else { throw VaultOpenError.wrongPassword }
    return try parseKeePass1(plain, groups: groupCount, entries: entryCount, rounds: rounds)
}

private func passwordEncodings(_ password: String) -> [Data] {
    var seen: [Data] = []
    for candidate in [windows1252Data(password), password.data(using: .isoLatin1), Data(password.utf8)] {
        guard let candidate, !seen.contains(candidate) else { continue }
        seen.append(candidate)
    }
    return seen
}

private func keepass1KeyMaterial(_ keyFile: Data?) -> Data? {
    guard let keyFile, !keyFile.isEmpty else { return nil }
    if keyFile.count == 32 { return keyFile }
    if keyFile.count == 64, let hex = hex32(keyFile) { return hex }
    return importSHA256(keyFile)
}

private func hex32(_ data: Data) -> Data? {
    guard let text = String(data: data, encoding: .ascii), text.allSatisfy(\.isHexDigit) else { return nil }
    var out = Data()
    var index = text.startIndex
    while index < text.endIndex {
        let next = text.index(index, offsetBy: 2)
        guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
        out.append(byte)
        index = next
    }
    return out.count == 32 ? out : nil
}

private func keepass1Composite(password: Data, keyFile: Data?) -> Data {
    let passwordHash = importSHA256(password)
    if let keyFile {
        return password.isEmpty ? keyFile : importSHA256(passwordHash + keyFile)
    }
    return passwordHash
}

private func aesKDF(_ raw: Data, seed: Data, rounds: UInt32) throws -> Data {
    var block = raw
    var round: UInt32 = 0
    while round < rounds {
        block = try aesECBEncrypt(block, key: seed)
        round += 1
    }
    return importSHA256(block)
}

private struct KeePass1Group {
    var id: UInt32
    var name: String
    var level: Int
    var path: [String]
}

private func parseKeePass1(_ data: Data, groups groupCount: Int, entries entryCount: Int, rounds: UInt32) throws -> Vault {
    var cursor = ByteCursor(data: data)
    var groups: [KeePass1Group] = []
    for _ in 0..<groupCount {
        var id: UInt32?
        var name = ""
        var level: UInt16?
        var done = false
        while !done {
            let type = try cursor.u16()
            let size = Int(try cursor.u32())
            let field = try cursor.take(size)
            switch type {
            case 0x0001: id = readU32LE(field, 0)
            case 0x0002: name = cString(field)
            case 0x0008: level = readU16LE(field, 0)
            case 0xFFFF: done = true
            default: break
            }
        }
        guard let id, let level else { throw VaultOpenError.invalid("A KeePass 1 group is missing its id.") }
        groups.append(KeePass1Group(id: id, name: name, level: Int(level), path: []))
    }
    var stack: [(level: Int, name: String)] = []
    for index in groups.indices {
        while let last = stack.last, last.level >= groups[index].level { stack.removeLast() }
        groups[index].path = stack.map(\.name) + [groups[index].name]
        stack.append((groups[index].level, groups[index].name))
    }
    let paths = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.path) })

    var entries: [VaultEntry] = []
    for _ in 0..<entryCount {
        var entry = VaultEntry()
        var groupID: UInt32?
        var binaryName = ""
        var done = false
        while !done {
            let type = try cursor.u16()
            let size = Int(try cursor.u32())
            let field = try cursor.take(size)
            switch type {
            case 0x0002: groupID = readU32LE(field, 0)
            case 0x0004: entry.title = cString(field)
            case 0x0005: entry.url = cString(field)
            case 0x0006: entry.username = cString(field)
            case 0x0007: entry.password = cString(field)
            case 0x0008: entry.notes = stripAutoType(cString(field))
            case 0x000D: binaryName = cString(field)
            case 0x000E: if !field.isEmpty { entry.attachments.append(VaultAttachment(name: binaryName, data: field)) }
            case 0xFFFF: done = true
            default: break
            }
        }
        if isKeePass1Meta(entry) { continue }
        if let groupID { entry.groupPath = paths[groupID] ?? [] }
        entries.append(entry)
    }
    let kdf = KDFParameters(kind: .aes(rounds: UInt64(rounds)))
    return Vault(name: "KeePass 1 Import", rootName: "KeePass 1 Import", entries: entries, kdf: kdf)
}

private func isKeePass1Meta(_ entry: VaultEntry) -> Bool {
    entry.title == "Meta-Info" && entry.username == "SYSTEM" && entry.url == "$"
        && entry.attachments.contains { $0.name == "bin-stream" } && !entry.notes.isEmpty
}

private func stripAutoType(_ notes: String) -> String {
    let sequence = try? NSRegularExpression(pattern: #"^Auto-Type(?:-\d+)?: .+"#, options: [.caseInsensitive])
    let window = try? NSRegularExpression(pattern: #"^Auto-Type-Window(?:-\d+)?: .+"#, options: [.caseInsensitive])
    var kept: [String] = []
    var lastWasAutoType = false
    for raw in notes.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = raw.replacingOccurrences(of: "\r", with: "")
        let range = NSRange(line.startIndex..., in: line)
        let isAutoType = sequence?.firstMatch(in: line, range: range) != nil || window?.firstMatch(in: line, range: range) != nil
        if isAutoType {
            lastWasAutoType = true
            continue
        }
        if lastWasAutoType && line.isEmpty {
            lastWasAutoType = false
            continue
        }
        lastWasAutoType = false
        kept.append(line)
    }
    return kept.joined(separator: "\n")
}
