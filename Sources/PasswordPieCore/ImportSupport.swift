import CommonCrypto
import CoreFoundation
import CryptoKit
import Foundation

public enum VaultOpenError: Error, Equatable, CustomStringConvertible {
    case wrongPassword
    case unsupported(String)
    case invalid(String)
    case crypto(String)

    public var description: String {
        switch self {
        case .wrongPassword: return "Wrong password."
        case .unsupported(let message): return message
        case .invalid(let message): return message
        case .crypto(let message): return message
        }
    }
}

func importSHA256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
func importSHA512(_ data: Data) -> Data { Data(SHA512.hash(data: data)) }

func importHMACSHA256(_ data: Data, key: Data) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
}

func importUInt32(_ value: Int) -> UInt32? {
    guard value > 0, value <= Int(UInt32.max) else { return nil }
    return UInt32(value)
}

func importUInt32Product(_ value: Int, _ factor: Int) -> UInt32? {
    guard factor > 0, value > 0, value <= Int.max / factor else { return nil }
    return importUInt32(value * factor)
}

func importPBKDF2(password: Data, salt: Data, iterations: Int, length: Int, sha512: Bool) throws -> Data {
    guard let rounds = importUInt32(iterations), length > 0 else {
        throw VaultOpenError.crypto("Invalid password stretching parameters.")
    }
    var output = Data(count: length)
    let status: CCCryptorStatus = password.withUnsafeBytes { passwordRaw in
        salt.withUnsafeBytes { saltRaw in
            output.withUnsafeMutableBytes { outputRaw in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordRaw.bindMemory(to: Int8.self).baseAddress,
                    password.count,
                    saltRaw.bindMemory(to: UInt8.self).baseAddress,
                    salt.count,
                    sha512 ? CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512) : CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    rounds,
                    outputRaw.bindMemory(to: UInt8.self).baseAddress,
                    length
                )
            }
        }
    }
    guard status == kCCSuccess else { throw VaultOpenError.crypto("Password stretching failed (\(status)).") }
    return output
}

/// HKDF-Expand (RFC 5869) with SHA-256. The input is already the pseudorandom key.
func hkdfExpandSHA256(prk: Data, info: Data, length: Int) -> Data {
    var okm = Data()
    var block = Data()
    var counter: UInt8 = 1
    while okm.count < length {
        var message = block
        message.append(info)
        message.append(counter)
        block = importHMACSHA256(message, key: prk)
        okm.append(block)
        counter += 1
    }
    return Data(okm.prefix(length))
}

func aesECBEncrypt(_ data: Data, key: Data) throws -> Data {
    try aesCrypt(data, key: key, iv: nil, operation: CCOperation(kCCEncrypt), options: CCOptions(kCCOptionECBMode))
}

func aesCBCDecryptPKCS7(_ data: Data, key: Data, iv: Data) throws -> Data {
    try aesCrypt(data, key: key, iv: iv, operation: CCOperation(kCCDecrypt), options: CCOptions(kCCOptionPKCS7Padding))
}

func aesCBCDecryptRaw(_ data: Data, key: Data, iv: Data) throws -> Data {
    guard data.count % 16 == 0 else { throw VaultOpenError.crypto("Ciphertext is not a whole number of AES blocks.") }
    return try aesCrypt(data, key: key, iv: iv, operation: CCOperation(kCCDecrypt), options: 0)
}

private func aesCrypt(_ data: Data, key: Data, iv: Data?, operation: CCOperation, options: CCOptions) throws -> Data {
    let outputCount = data.count + kCCBlockSizeAES128
    var output = Data(count: outputCount)
    var written = 0
    let status: CCCryptorStatus = data.withUnsafeBytes { dataRaw in
        key.withUnsafeBytes { keyRaw in
            output.withUnsafeMutableBytes { outputRaw in
                if let iv {
                    return iv.withUnsafeBytes { ivRaw in
                        CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), options, keyRaw.baseAddress, key.count, ivRaw.baseAddress, dataRaw.baseAddress, data.count, outputRaw.baseAddress, outputCount, &written)
                    }
                }
                return CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), options, keyRaw.baseAddress, key.count, nil, dataRaw.baseAddress, data.count, outputRaw.baseAddress, outputCount, &written)
            }
        }
    }
    guard status == kCCSuccess else { throw VaultOpenError.crypto("AES failed (\(status)).") }
    output.removeSubrange(written..<output.count)
    return output
}

func decodeBase64Loose(_ text: String) -> Data? {
    var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let remainder = cleaned.count % 4
    if remainder != 0 { cleaned.append(String(repeating: "=", count: 4 - remainder)) }
    return Data(base64Encoded: cleaned)
}

func base64URLNoPadding(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func percentEncode(_ text: String) -> String {
    let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    var out = ""
    for byte in Data(text.utf8) {
        let scalar = UnicodeScalar(byte)
        if allowed.contains(Character(scalar)) {
            out.append(Character(scalar))
        } else {
            out.append(String(format: "%%%02X", byte))
        }
    }
    return out
}

func otpAuthURL(secretOrURL: String, title: String, username: String) -> String {
    if secretOrURL.lowercased().hasPrefix("otpauth://") { return secretOrURL }
    return "otpauth://totp/\(percentEncode(title)):\(percentEncode(username))?secret=\(percentEncode(secretOrURL))"
}

func windows1252Data(_ text: String) -> Data? {
    text.data(using: .windowsCP1252)
}

func readU16LE(_ data: Data, _ offset: Int) -> UInt16 {
    UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
}

func readU32LE(_ data: Data, _ offset: Int) -> UInt32 {
    UInt32(data[offset])
        | (UInt32(data[offset + 1]) << 8)
        | (UInt32(data[offset + 2]) << 16)
        | (UInt32(data[offset + 3]) << 24)
}

func readU64LE(_ data: Data, _ offset: Int) -> UInt64 {
    var value: UInt64 = 0
    for index in 0..<8 {
        value |= UInt64(data[offset + index]) << (8 * index)
    }
    return value
}

struct ByteCursor {
    var data: Data
    var offset = 0

    var remaining: Int { data.count - offset }

    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else { throw VaultOpenError.invalid("The file ended early.") }
        let slice = data.subdata(in: offset..<(offset + count))
        offset += count
        return slice
    }

    mutating func u16() throws -> UInt16 {
        let bytes = try take(2)
        return readU16LE(bytes, 0)
    }

    mutating func u32() throws -> UInt32 {
        let bytes = try take(4)
        return readU32LE(bytes, 0)
    }
}

func cString(_ data: Data) -> String {
    let end = data.firstIndex(of: 0) ?? data.endIndex
    return String(data: data[..<end], encoding: .utf8) ?? ""
}

func putField(_ entry: inout VaultEntry, _ key: String, _ value: String, protected: Bool = false) {
    guard !value.isEmpty || protected else { return }
    var name = key
    var suffix = 2
    while entry.fields.contains(where: { $0.key == name }) {
        name = "\(key)_\(suffix)"
        suffix += 1
    }
    entry.setValue(value, for: name, protected: protected)
}

func putOTP(_ entry: inout VaultEntry, _ raw: String) {
    let url = otpAuthURL(secretOrURL: raw, title: entry.title, username: entry.username)
    if entry.otp.isEmpty {
        entry.otp = url
        return
    }
    var index = 1
    var name = "otp_\(index)"
    while entry.fields.contains(where: { $0.key == name }) {
        index += 1
        name = "otp_\(index)"
    }
    entry.setValue(url, for: name, protected: true)
}

func addTag(_ entry: inout VaultEntry, _ tag: String) {
    guard !tag.isEmpty else { return }
    if entry.tagList.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) { return }
    entry.tags = (entry.tagList + [tag]).joined(separator: ",")
}

// MARK: - ZIP (store and raw deflate)

func unzip(_ data: Data) throws -> [String: Data] {
    var cursor = ByteCursor(data: data)
    var files: [String: Data] = [:]
    while cursor.remaining >= 4 {
        let signature = try cursor.u32()
        guard signature == 0x04034b50 else { break }
        _ = try cursor.take(2)
        let flags = try cursor.u16()
        let method = try cursor.u16()
        _ = try cursor.take(4)
        _ = try cursor.u32()
        let compressedSize = Int(try cursor.u32())
        _ = try cursor.u32()
        let nameLength = Int(try cursor.u16())
        let extraLength = Int(try cursor.u16())
        let nameData = try cursor.take(nameLength)
        _ = try cursor.take(extraLength)
        if flags & 0x8 != 0 {
            throw VaultOpenError.unsupported("This ZIP uses data descriptors, which this reader does not support.")
        }
        let compressed = try cursor.take(compressedSize)
        let name = String(data: nameData, encoding: .utf8) ?? ""
        if name.hasSuffix("/") { continue }
        switch method {
        case 0:
            files[name] = compressed
        case 8:
            files[name] = try rawInflate(compressed)
        default:
            throw VaultOpenError.unsupported("ZIP compression method \(method) is not supported.")
        }
    }
    return files
}

// MARK: - OpData01

func decodeOpData01(_ data: Data, key: Data, hmacKey: Data) throws -> Data {
    // A Data slice keeps its original indices. Rebase so offsets below start at 0.
    let data = Data(data)
    let header = Data("opdata01".utf8)
    guard data.starts(with: header), data.count >= 8 + 8 + 16 + 32 else {
        throw VaultOpenError.crypto("Invalid OpData01 header.")
    }
    let rawLength = readU64LE(data, 8)
    guard rawLength <= UInt64(Int.max) else {
        throw VaultOpenError.crypto("OpData01 length is not supported.")
    }
    let length = Int(rawLength)
    let iv = data.subdata(in: 16..<32)
    let remainder = length % 16
    let pad = remainder == 0 ? 16 : 16 - remainder
    guard length <= Int.max - pad, length + pad <= data.count - 64 else {
        throw VaultOpenError.crypto("OpData01 is truncated.")
    }
    let cipherLength = length + pad
    let cipherText = data.subdata(in: 32..<(32 + cipherLength))
    let mac = data.subdata(in: (32 + cipherLength)..<(32 + cipherLength + 32))
    let signed = data.prefix(32 + cipherLength)
    guard importHMACSHA256(Data(signed), key: hmacKey) == mac else { throw VaultOpenError.wrongPassword }
    let clear = try aesCBCDecryptRaw(cipherText, key: key, iv: iv)
    guard clear.count >= pad else { throw VaultOpenError.crypto("OpData01 plaintext is short.") }
    let plain = clear.suffix(from: pad)
    guard plain.count == length else { throw VaultOpenError.crypto("OpData01 plaintext length does not match.") }
    return Data(plain)
}

func decodeOpData01Base64(_ text: String, key: Data, hmacKey: Data) throws -> Data {
    guard let data = decodeBase64Loose(text) else { throw VaultOpenError.crypto("OpData01 is not valid base64.") }
    return try decodeOpData01(data, key: key, hmacKey: hmacKey)
}

// MARK: - JSON

struct JSON {
    var value: Any

    static func parse(_ data: Data) throws -> JSON {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return JSON(value: object)
    }

    static func parseObject(_ text: String) throws -> JSON {
        guard let data = text.data(using: .utf8) else { throw VaultOpenError.invalid("The file is not UTF-8.") }
        let json = try parse(data)
        guard json.object != nil else { throw VaultOpenError.invalid("Expected a JSON object.") }
        return json
    }

    var object: [String: Any]? { value as? [String: Any] }
    var array: [Any]? { value as? [Any] }
    var string: String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.stringValue }
        return nil
    }
    var int: Int? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }
    var bool: Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    subscript(_ key: String) -> JSON? {
        guard let object, let child = object[key] else { return nil }
        if child is NSNull { return nil }
        return JSON(value: child)
    }

    var items: [JSON] { (array ?? []).map { JSON(value: $0) } }

    func map(_ key: String) -> [String: Any]? { self[key]?.object }
}

func jsonText(_ value: Any?) -> String {
    switch value {
    case let text as String:
        return text
    case let number as NSNumber:
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
        return number.stringValue
    default:
        return ""
    }
}

// MARK: - CSV

func parseCSV(_ text: String) -> [[String]] {
    let separator: Character = {
        let sample = text.prefix(2000)
        let commas = sample.filter { $0 == "," }.count
        let semis = sample.filter { $0 == ";" }.count
        return semis > commas && commas == 0 ? ";" : ","
    }()
    var rows: [[String]] = []
    var row: [String] = []
    var field = ""
    var quoted = false
    var iterator = text.makeIterator()
    while let character = iterator.next() {
        if quoted {
            if character == "\"" {
                if let next = iterator.next() {
                    if next == "\"" {
                        field.append("\"")
                    } else {
                        quoted = false
                        if next == separator {
                            row.append(field)
                            field = ""
                        } else if next == "\n" {
                            row.append(field)
                            rows.append(row)
                            row = []
                            field = ""
                        } else if next == "\r" {
                            row.append(field)
                            rows.append(row)
                            row = []
                            field = ""
                        } else {
                            field.append(next)
                        }
                    }
                } else {
                    quoted = false
                }
            } else {
                field.append(character)
            }
        } else if character == "\"" && field.isEmpty {
            quoted = true
        } else if character == separator {
            row.append(field)
            field = ""
        } else if character == "\n" {
            row.append(field)
            rows.append(row)
            row = []
            field = ""
        } else if character == "\r" {
            continue
        } else {
            field.append(character)
        }
    }
    if quoted || !field.isEmpty || !row.isEmpty {
        row.append(field)
        rows.append(row)
    }
    return rows.filter { row in row.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
}

func loadCSV(_ data: Data) throws -> Vault {
    guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) else {
        throw VaultOpenError.invalid("The CSV file is not text.")
    }
    let rows = parseCSV(text)
    guard let header = rows.first else { throw VaultOpenError.invalid("The CSV file is empty.") }
    let mapping = csvMapping(header)
    let body = mapping.isEmpty ? rows : Array(rows.dropFirst())
    let columns = mapping.isEmpty ? csvFallbackColumns(header.count) : mapping
    var entries: [VaultEntry] = []
    for row in body {
        var entry = VaultEntry()
        for (index, role) in columns {
            guard index < row.count else { continue }
            let value = row[index]
            switch role {
            case .group:
                entry.groupPath = value.split { $0 == "/" || $0 == "\\" }.map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            case .title:
                entry.title = value
            case .username:
                entry.username = value
            case .password:
                entry.password = value
            case .url:
                entry.url = value
            case .notes:
                entry.notes = value
            case .otp:
                if !value.isEmpty { putOTP(&entry, value) }
            case .favorite:
                let flag = value.trimmingCharacters(in: .whitespaces).lowercased()
                entry.favorite = flag == "1" || flag == "true" || flag == "yes" || flag == "*"
            case .extra(let name):
                putField(&entry, name, value)
            }
        }
        if entry.title.isEmpty && entry.username.isEmpty && entry.password.isEmpty && entry.notes.isEmpty { continue }
        entries.append(entry)
    }
    return Vault(name: "CSV Import", rootName: "CSV Import", entries: entries)
}

private enum CSVRole {
    case group, title, username, password, url, notes, otp, favorite
    case extra(String)
}

private func csvMapping(_ header: [String]) -> [Int: CSVRole] {
    var mapping: [Int: CSVRole] = [:]
    var known = 0
    for (index, column) in header.enumerated() {
        let key = column.lowercased().filter { $0.isLetter || $0.isNumber }
        let role: CSVRole?
        switch key {
        case "group", "groups", "folder", "folders", "grouping": role = .group
        case "title", "name", "account", "loginname": role = .title
        case "username", "user", "login", "loginusername", "email": role = .username
        case "password", "loginpassword", "pass": role = .password
        case "url", "website", "uri", "loginuri", "web": role = .url
        case "notes", "note", "extra", "comment", "comments": role = .notes
        case "totp", "otp", "logintotp", "otpauth": role = .otp
        case "favorite", "fav", "favourite": role = .favorite
        default: role = nil
        }
        if let role {
            mapping[index] = role
            known += 1
        } else if !column.trimmingCharacters(in: .whitespaces).isEmpty {
            mapping[index] = .extra(column.trimmingCharacters(in: .whitespaces))
        }
    }
    return known >= 2 ? mapping : [:]
}

private func csvFallbackColumns(_ count: Int) -> [Int: CSVRole] {
    let roles: [CSVRole] = [.group, .title, .username, .password, .url, .notes, .otp]
    var mapping: [Int: CSVRole] = [:]
    for index in 0..<min(count, roles.count) {
        mapping[index] = roles[index]
    }
    return mapping
}

private extension String.Encoding {
    /// Windows-1252. KeePass 1 stored passwords in this code page before trying Latin-1 and UTF-8.
    static var windowsCP1252: String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(0x0500))
    }
}
