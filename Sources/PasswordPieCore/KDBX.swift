import Foundation
import CommonCrypto
import CryptoKit
import CArgon2
import Security

public enum KDBX {
    /// Strict: a document the XML parser refuses is an error. A save's read-back uses this.
    public static func load(data: Data, password: String) throws -> Vault {
        try load(data: data, password: password, repairing: false)
    }

    /// Opens a file the old writer damaged by repairing its XML in memory. `Vault.recovery` says what changed.
    public static func loadRecovering(data: Data, password: String) throws -> Vault {
        try load(data: data, password: password, repairing: true)
    }

    private static func load(data: Data, password: String, repairing: Bool) throws -> Vault {
        let parsed = try parseOuter(data)
        let composite = compositeKey(password)
        let transformed = try derive(composite, kdf: parsed.kdf, salt: parsed.kdfSalt)
        let hmacBase = sha512(parsed.masterSeed + transformed + Data([0x01]))
        let headerHMACKey = blockKey(index: UInt64.max, base: hmacBase)
        let actualHMAC = Data(HMAC<SHA256>.authenticationCode(for: parsed.header, using: SymmetricKey(data: headerHMACKey)))
        guard actualHMAC == parsed.headerHMAC else { throw KDBXError.wrongPassword }
        let cipherText = try readHMACBlocks(parsed.body, hmacBase: hmacBase)
        let plain = try aesCBCDecrypt(cipherText, key: sha256(parsed.masterSeed + transformed), iv: parsed.iv)
        let inner = parsed.compressed ? try gzipDecompress(plain) : plain
        let split = try splitInner(inner)
        let document: XMLDocument
        var repair: KDBXXMLRepair.Result?
        do {
            document = try parseKDBXDocument(split.xml)
        } catch {
            guard repairing else { throw error }
            let repaired = KDBXXMLRepair.repair(split.xml)
            guard repaired.xml != split.xml, let fixed = try? parseKDBXDocument(repaired.xml) else { throw error }
            document = fixed
            repair = repaired
        }
        try decryptProtectedValues(in: document, streamKey: split.streamKey)
        let preserve = KDBXPreserve(
            document: document,
            pieces: split.pieces,
            version: parsed.version,
            headerFields: parsed.headerFields,
            compressed: parsed.compressed,
            kdfSaltRange: parsed.kdfSaltRange
        )
        var vault = preserve.makeVault(kdf: parsed.kdfParameters)
        if let repair {
            var recovery = repair.recovery
            preserve.locateRecovery(changedTexts: repair.changedTexts, uncertainTexts: repair.uncertainTexts, into: &recovery)
            vault.recovery = recovery
        }
        return vault
    }

    public static func save(vault: inout Vault, password: String) throws -> Data {
        normalizeForXML(&vault)
        if vault.preserve == nil {
            return try saveGenerated(vault: &vault, password: password)
        }
        return try savePreserved(vault: &vault, password: password)
    }

    /// Builds a database whose protected values are still plaintext in `xml`, then saves it.
    /// Tests use this so a fixture can describe the decrypted tree directly.
    static func testingDatabase(
        xml: String,
        binaries: [Data] = [],
        extraPieces: [InnerPiece] = [],
        password: String,
        kdf: KDFParameters = .fastTest,
        version: UInt32 = 0x00040001,
        compressed: Bool = true,
        extraHeader: [HeaderField] = []
    ) throws -> Data {
        let document = try parseKDBXDocument(xml: xml)
        let masterSeed = random(32)
        let iv = random(16)
        let (_, salt) = try writeKDF(kdf)
        let blob = kdfParametersBlob(kdf, salt: salt)
        let saltRange = try locateKDFSalt(blob)
        var fields = [
            HeaderField(type: 2, payload: uuidBytes("31c1f2e6-bf71-4350-be58-05216afc5aff")),
            HeaderField(type: 3, payload: le(compressed ? UInt32(1) : UInt32(0))),
            HeaderField(type: 4, payload: masterSeed),
            HeaderField(type: 7, payload: iv),
            HeaderField(type: 11, payload: blob)
        ]
        fields.append(contentsOf: extraHeader)
        fields.append(HeaderField(type: 0, payload: Data([0x0d, 0x0a, 0x0d, 0x0a])))
        var pieces = binaries.map { InnerPiece.binary(flags: 0x01, data: $0) }
        pieces.append(contentsOf: extraPieces)
        let preserve = KDBXPreserve(
            document: document,
            pieces: pieces,
            version: version,
            headerFields: fields,
            compressed: compressed,
            kdfSaltRange: saltRange
        )
        var vault = preserve.makeVault(kdf: kdf)
        return try save(vault: &vault, password: password)
    }

    /// Packs XML bytes exactly as given, so a test can hold a file the old writer produced.
    static func testingDatabase(rawXML: Data, streamKey: Data, password: String) throws -> Data {
        let masterSeed = random(32)
        let iv = random(16)
        let kdf = KDFParameters.fastTest
        let (kdfParameters, salt) = try writeKDF(kdf)
        let fields = [
            HeaderField(type: 2, payload: uuidBytes("31c1f2e6-bf71-4350-be58-05216afc5aff")),
            HeaderField(type: 3, payload: le(UInt32(1))),
            HeaderField(type: 4, payload: masterSeed),
            HeaderField(type: 7, payload: iv),
            HeaderField(type: 11, payload: kdfParametersBlob(kdfParameters, salt: salt)),
            HeaderField(type: 0, payload: Data([0x0d, 0x0a, 0x0d, 0x0a]))
        ]
        return try packFile(
            version: 0x00040000,
            fields: fields,
            masterSeed: masterSeed,
            transformed: try derive(compositeKey(password), kdf: kdfParameters.kind, salt: salt),
            iv: iv,
            compressed: true,
            xml: rawXML,
            streamKey: streamKey,
            pieces: []
        )
    }
}

/// Text XML cannot carry leaves the model too, so the model stays equal to what the file reads back as.
/// Protected values are encrypted to base64 before they reach the XML, so they keep every character.
private func normalizeForXML(_ vault: inout Vault) {
    vault.name = storedXMLText(vault.name)
    vault.rootName = storedXMLText(vault.rootName)
    for index in vault.entries.indices {
        vault.entries[index].tags = storedXMLText(vault.entries[index].tags)
        vault.entries[index].groupPath = vault.entries[index].groupPath.map(storedXMLText)
        vault.entries[index].fields = normalizedFields(vault.entries[index].fields)
    }
}

/// A key that cleaning empties or makes equal to another key keeps its value under a new name. An empty key is
/// not written, and KeePassXC refuses a database with a repeated key.
private func normalizedFields(_ fields: [VaultField]) -> [VaultField] {
    var result = fields
    var taken = Set(fields.map(\.key).filter { storedXMLText($0) == $0 })
    for index in result.indices {
        if !result[index].protected {
            result[index].value = storedXMLText(result[index].value)
        }
        let original = result[index].key
        let cleaned = storedXMLText(original)
        guard cleaned != original else { continue }
        let base = cleaned.isEmpty ? "Field" : cleaned
        var candidate = base
        var number = 2
        while taken.contains(candidate) {
            candidate = "\(base) \(number)"
            number += 1
        }
        taken.insert(candidate)
        result[index].key = candidate
    }
    return result
}

private func saveGenerated(vault: inout Vault, password: String) throws -> Data {
    let masterSeed = random(32)
    let iv = random(16)
    let protectedKey = random(64)
    let composite = compositeKey(password)
    let (kdfParameters, kdfSalt) = try writeKDF(vault.kdf)
    let transformed = try derive(composite, kdf: kdfParameters.kind, salt: kdfSalt)
    let kdfBlob = kdfParametersBlob(kdfParameters, salt: kdfSalt)
    let saltRange = try locateKDFSalt(kdfBlob)
    let fields = [
        HeaderField(type: 2, payload: uuidBytes("31c1f2e6-bf71-4350-be58-05216afc5aff")),
        HeaderField(type: 3, payload: le(UInt32(1))),
        HeaderField(type: 4, payload: masterSeed),
        HeaderField(type: 7, payload: iv),
        HeaderField(type: 11, payload: kdfBlob),
        HeaderField(type: 0, payload: Data([0x0d, 0x0a, 0x0d, 0x0a]))
    ]
    let parts = sha512SplitKey(protectedStreamKey: protectedKey)
    var stream = ChaCha20(key: parts.key, nonce: parts.nonce, counter: 0)
    let xml = escapingCarriageReturns(xmlDocument(vault, stream: &stream))
    // Same parser the next unlock uses. A document that fails here is not packed or written.
    let document = try parseKDBXDocument(xml)
    let output = try packFile(
        version: 0x00040000,
        fields: fields,
        masterSeed: masterSeed,
        transformed: transformed,
        iv: iv,
        compressed: true,
        xml: xml,
        streamKey: protectedKey,
        pieces: []
    )
    try decryptProtectedValues(in: document, streamKey: protectedKey)
    let preserve = KDBXPreserve(
        document: document,
        pieces: [],
        version: 0x00040000,
        headerFields: fields,
        compressed: true,
        kdfSaltRange: saltRange
    )
    let aligned = preserve.makeVault(kdf: kdfParameters)
    vault = aligned
    return output
}

private func savePreserved(vault: inout Vault, password: String) throws -> Data {
    guard let source = vault.preserve else { throw KDBXError.crypto("The database document is missing.") }
    // Edit a copy. A throw, or a file write that fails after this returns, leaves the open document unchanged.
    let preserve = try source.isolatedCopy()
    try preserve.applyEdits(vault)
    let masterSeed = random(32)
    let iv = random(16)
    let streamKey = random(64)
    var fields = preserve.headerFields
    var kdfBlob: Data?
    for index in fields.indices {
        switch fields[index].type {
        case 4:
            fields[index].payload = masterSeed
        case 7:
            fields[index].payload = iv
        case 11:
            var blob = fields[index].payload
            let range = preserve.kdfSaltRange
            guard !range.isEmpty, range.upperBound <= blob.count else {
                throw KDBXError.crypto("The KDF salt could not be updated.")
            }
            blob.replaceSubrange(range, with: random(range.count))
            fields[index].payload = blob
            kdfBlob = blob
        default:
            break
        }
    }
    guard let kdfBlob else { throw KDBXError.crypto("The KDF parameters are missing.") }
    let parsed = try parseKDF(kdfBlob)
    let composite = compositeKey(password)
    let transformed = try derive(composite, kdf: parsed.kind, salt: parsed.salt)
    let xml = try preserve.encryptedXML(streamKey: streamKey)
    // Same parser the next unlock uses. A document that fails here is not packed or written.
    _ = try parseKDBXDocument(xml)
    let output = try packFile(
        version: preserve.version,
        fields: fields,
        masterSeed: masterSeed,
        transformed: transformed,
        iv: iv,
        compressed: preserve.compressed,
        xml: xml,
        streamKey: streamKey,
        pieces: preserve.pieces
    )
    preserve.headerFields = fields
    vault.preserve = preserve
    return output
}

private func packFile(
    version: UInt32,
    fields: [HeaderField],
    masterSeed: Data,
    transformed: Data,
    iv: Data,
    compressed: Bool,
    xml: Data,
    streamKey: Data,
    pieces: [InnerPiece]
) throws -> Data {
    var header = Data()
    appendU32(0x9AA2D903, to: &header)
    appendU32(0xB54BFB67, to: &header)
    appendU32(version, to: &header)
    for field in fields {
        appendField(field.type, field.payload, to: &header)
    }
    let hmacBase = sha512(masterSeed + transformed + Data([0x01]))
    let headerHash = sha256(header)
    let headerHMAC = Data(HMAC<SHA256>.authenticationCode(
        for: header,
        using: SymmetricKey(data: blockKey(index: UInt64.max, base: hmacBase))
    ))
    var inner = Data()
    appendInner(1, le(UInt32(3)), to: &inner)
    appendInner(2, streamKey, to: &inner)
    for piece in pieces {
        switch piece {
        case .binary(let flags, let data):
            var payload = Data([flags])
            payload.append(data)
            appendInner(3, payload, to: &inner)
        case .other(let type, let payload):
            appendInner(type, payload, to: &inner)
        }
    }
    appendInner(0, Data(), to: &inner)
    inner.append(xml)
    let payload = compressed ? try gzipCompress(inner) : inner
    let cipherText = try aesCBCEncrypt(payload, key: sha256(masterSeed + transformed), iv: iv)
    var output = header
    output.append(headerHash)
    output.append(headerHMAC)
    output.append(hmacBlocks(cipherText, hmacBase: hmacBase))
    return output
}

private struct OuterFile {
    var header: Data
    var headerHMAC: Data
    var body: Data
    var masterSeed: Data
    var iv: Data
    var compressed: Bool
    var kdf: KDFKind
    var kdfSalt: Data
    var kdfParameters: KDFParameters
    var version: UInt32
    var headerFields: [HeaderField]
    var kdfSaltRange: Range<Int>
}

private func parseOuter(_ data: Data) throws -> OuterFile {
    guard data.count > 12 else { throw KDBXError.truncated }
    let sig1 = readU32(data, 0)
    let sig2 = readU32(data, 4)
    guard sig1 == 0x9AA2D903, sig2 == 0xB54BFB67 else { throw KDBXError.notKDBX }
    let version = readU32(data, 8)
    guard (version & 0xFFFF0000) == 0x00040000 else {
        throw KDBXError.unsupported("Only KDBX 4 databases can be opened. This file is version \(String(format: "%08x", version)).")
    }
    var offset = 12
    var masterSeed = Data()
    var iv = Data()
    var compressed = true
    var cipher = Data()
    var kdfBlob = Data()
    var fields: [HeaderField] = []
    while offset + 5 <= data.count {
        let type = data[offset]
        let size = Int(readU32(data, offset + 1))
        let start = offset + 5
        guard start + size <= data.count else { throw KDBXError.truncated }
        let payload = data.subdata(in: start..<(start + size))
        offset = start + size
        fields.append(HeaderField(type: type, payload: payload))
        switch type {
        case 2:
            cipher = payload
        case 3:
            if payload.count >= 4 {
                compressed = readU32(payload, 0) != 0
            }
        case 4:
            masterSeed = payload
        case 7:
            iv = payload
        case 11:
            kdfBlob = payload
        default:
            break
        }
        if type == 0 {
            break
        }
    }
    let aes = uuidBytes("31c1f2e6-bf71-4350-be58-05216afc5aff")
    guard cipher == aes else {
        throw KDBXError.unsupported("This database uses a cipher other than AES-256. Save it from KeePassXC with AES-256, then open it here.")
    }
    guard masterSeed.count == 32, iv.count == 16 else { throw KDBXError.crypto("The header is missing a seed or IV.") }
    let kdf = try parseKDF(kdfBlob)
    let saltRange = try locateKDFSalt(kdfBlob)
    guard offset + 64 <= data.count else { throw KDBXError.truncated }
    let header = data.prefix(offset)
    let hash = data.subdata(in: offset..<(offset + 32))
    guard hash == sha256(header) else { throw KDBXError.crypto("The header hash does not match.") }
    let hmac = data.subdata(in: (offset + 32)..<(offset + 64))
    let body = data.suffix(from: offset + 64)
    return OuterFile(
        header: Data(header),
        headerHMAC: hmac,
        body: Data(body),
        masterSeed: masterSeed,
        iv: iv,
        compressed: compressed,
        kdf: kdf.kind,
        kdfSalt: kdf.salt,
        kdfParameters: kdf.parameters,
        version: version,
        headerFields: fields,
        kdfSaltRange: saltRange
    )
}

private struct ParsedKDF {
    var kind: KDFKind
    var salt: Data
    var parameters: KDFParameters
}

private func parseKDF(_ blob: Data) throws -> ParsedKDF {
    guard blob.count >= 2 else { throw KDBXError.crypto("Missing KDF parameters.") }
    var offset = 2
    var values: [String: Data] = [:]
    var types: [String: UInt8] = [:]
    while offset < blob.count {
        let type = blob[offset]
        offset += 1
        if type == 0 { break }
        guard offset + 4 <= blob.count else { throw KDBXError.truncated }
        let nameLength = Int(readU32(blob, offset))
        offset += 4
        guard offset + nameLength + 4 <= blob.count else { throw KDBXError.truncated }
        let name = String(data: blob.subdata(in: offset..<(offset + nameLength)), encoding: .utf8) ?? ""
        offset += nameLength
        let dataLength = Int(readU32(blob, offset))
        offset += 4
        guard offset + dataLength <= blob.count else { throw KDBXError.truncated }
        values[name] = blob.subdata(in: offset..<(offset + dataLength))
        types[name] = type
        offset += dataLength
    }
    guard let uuid = values["$UUID"], uuid.count == 16 else {
        throw KDBXError.crypto("The KDF id is missing.")
    }
    let salt = values["S"] ?? Data()
    if uuid == uuidBytes("c9d9f39a-628a-4460-bf74-0d08c18a4fea")
        || uuid == uuidBytes("7c02bb82-79a7-4ac0-927d-114a00648238") {
        let rounds = integer(values["R"])
        guard rounds > 0, salt.count == 32 else { throw KDBXError.crypto("AES-KDF parameters are incomplete.") }
        let kind = KDFKind.aes(rounds: rounds)
        return ParsedKDF(kind: kind, salt: salt, parameters: KDFParameters(kind: kind))
    }
    let memoryBytes = integer(values["M"])
    let memoryKiB = UInt32(memoryBytes / 1024)
    let iterations = UInt32(integer(values["I"]))
    let parallelism = UInt32(integer(values["P"]))
    let version = UInt32(integer(values["V"]))
    guard memoryKiB > 0, iterations > 0, parallelism > 0, salt.count >= 8 else {
        throw KDBXError.crypto("Argon2 parameters are incomplete.")
    }
    if uuid == uuidBytes("9e298b19-56db-4773-b23d-fc3ec6f0a1e6") {
        let kind = KDFKind.argon2id(memoryKiB: memoryKiB, iterations: iterations, parallelism: parallelism, version: version)
        return ParsedKDF(kind: kind, salt: salt, parameters: KDFParameters(kind: kind))
    }
    if uuid == uuidBytes("ef636ddf-8c29-444b-91f7-a9a403e30a0c") {
        let kind = KDFKind.argon2d(memoryKiB: memoryKiB, iterations: iterations, parallelism: parallelism, version: version)
        return ParsedKDF(kind: kind, salt: salt, parameters: KDFParameters(kind: kind))
    }
    throw KDBXError.unsupported("This KDF is not supported.")
}

func locateKDFSalt(_ blob: Data) throws -> Range<Int> {
    guard blob.count >= 2 else { throw KDBXError.crypto("Missing KDF parameters.") }
    var offset = 2
    while offset < blob.count {
        let type = blob[offset]
        offset += 1
        if type == 0 { break }
        guard offset + 4 <= blob.count else { throw KDBXError.truncated }
        let nameLength = Int(readU32(blob, offset))
        offset += 4
        guard offset + nameLength + 4 <= blob.count else { throw KDBXError.truncated }
        let name = String(data: blob.subdata(in: offset..<(offset + nameLength)), encoding: .utf8) ?? ""
        offset += nameLength
        let dataLength = Int(readU32(blob, offset))
        offset += 4
        guard offset + dataLength <= blob.count else { throw KDBXError.truncated }
        if name == "S" {
            guard dataLength > 0 else { throw KDBXError.crypto("The KDF salt is empty.") }
            return offset..<(offset + dataLength)
        }
        offset += dataLength
    }
    throw KDBXError.crypto("The KDF salt is missing.")
}

private func writeKDF(_ parameters: KDFParameters) throws -> (KDFParameters, Data) {
    switch parameters.kind {
    case .aes:
        return (parameters, random(32))
    case .argon2id, .argon2d:
        return (parameters, random(32))
    }
}

private func kdfParametersBlob(_ parameters: KDFParameters, salt: Data) -> Data {
    var map = Data()
    appendU16(0x0100, to: &map)
    switch parameters.kind {
    case .aes(let rounds):
        variantBytes("$UUID", uuidBytes("c9d9f39a-628a-4460-bf74-0d08c18a4fea"), to: &map)
        variantU64("R", rounds, to: &map)
        variantBytes("S", salt, to: &map)
    case .argon2id(let memoryKiB, let iterations, let parallelism, let version):
        variantBytes("$UUID", uuidBytes("9e298b19-56db-4773-b23d-fc3ec6f0a1e6"), to: &map)
        variantU64("I", UInt64(iterations), to: &map)
        variantU64("M", UInt64(memoryKiB) * 1024, to: &map)
        variantU32("P", parallelism, to: &map)
        variantBytes("S", salt, to: &map)
        variantU32("V", version, to: &map)
    case .argon2d(let memoryKiB, let iterations, let parallelism, let version):
        variantBytes("$UUID", uuidBytes("ef636ddf-8c29-444b-91f7-a9a403e30a0c"), to: &map)
        variantU64("I", UInt64(iterations), to: &map)
        variantU64("M", UInt64(memoryKiB) * 1024, to: &map)
        variantU32("P", parallelism, to: &map)
        variantBytes("S", salt, to: &map)
        variantU32("V", version, to: &map)
    }
    map.append(0)
    return map
}

private func derive(_ composite: Data, kdf: KDFKind, salt: Data) throws -> Data {
    switch kdf {
    case .aes(let rounds):
        var block = composite
        var round = UInt64(0)
        while round < rounds {
            block = try aesECB(block, key: salt)
            round += 1
        }
        return sha256(block)
    case .argon2id(let memoryKiB, let iterations, let parallelism, let version):
        return try argon2(composite, salt: salt, memoryKiB: memoryKiB, iterations: iterations, parallelism: parallelism, version: version, type: Argon2_id)
    case .argon2d(let memoryKiB, let iterations, let parallelism, let version):
        return try argon2(composite, salt: salt, memoryKiB: memoryKiB, iterations: iterations, parallelism: parallelism, version: version, type: Argon2_d)
    }
}

func argon2(
    _ password: Data,
    salt: Data,
    memoryKiB: UInt32,
    iterations: UInt32,
    parallelism: UInt32,
    version: UInt32,
    type: argon2_type
) throws -> Data {
    var output = Data(count: 32)
    let code: Int32 = password.withUnsafeBytes { passwordRaw in
        salt.withUnsafeBytes { saltRaw in
            output.withUnsafeMutableBytes { outputRaw in
                var context = argon2_context()
                context.out = outputRaw.bindMemory(to: UInt8.self).baseAddress
                context.outlen = 32
                context.pwd = UnsafeMutablePointer(mutating: passwordRaw.bindMemory(to: UInt8.self).baseAddress)
                context.pwdlen = UInt32(password.count)
                context.salt = UnsafeMutablePointer(mutating: saltRaw.bindMemory(to: UInt8.self).baseAddress)
                context.saltlen = UInt32(salt.count)
                context.secret = nil
                context.secretlen = 0
                context.ad = nil
                context.adlen = 0
                context.t_cost = iterations
                context.m_cost = memoryKiB
                context.lanes = parallelism
                context.threads = parallelism
                context.version = version
                context.allocate_cbk = nil
                context.free_cbk = nil
                context.flags = 0
                return argon2_ctx(&context, type)
            }
        }
    }
    guard code == 0 else {
        throw KDBXError.crypto("Argon2 failed (\(code)).")
    }
    return output
}

private func compositeKey(_ password: String) -> Data {
    sha256(sha256(Data(password.utf8)))
}

private func readHMACBlocks(_ data: Data, hmacBase: Data) throws -> Data {
    var offset = 0
    var index: UInt64 = 0
    var plain = Data()
    while offset + 36 <= data.count {
        let hmac = data.subdata(in: offset..<(offset + 32))
        let size = Int(readU32(data, offset + 32))
        let start = offset + 36
        guard size >= 0, start + size <= data.count else { throw KDBXError.truncated }
        let block = data.subdata(in: start..<(start + size))
        var message = Data()
        appendU64(index, to: &message)
        appendU32(UInt32(size), to: &message)
        message.append(block)
        let expected = Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: blockKey(index: index, base: hmacBase))))
        guard hmac == expected else { throw KDBXError.wrongPassword }
        offset = start + size
        index += 1
        if size == 0 {
            return plain
        }
        plain.append(block)
    }
    throw KDBXError.truncated
}

private func hmacBlocks(_ data: Data, hmacBase: Data) -> Data {
    let blockSize = 1024 * 1024
    var output = Data()
    var index: UInt64 = 0
    var cursor = 0
    while cursor < data.count {
        let end = min(cursor + blockSize, data.count)
        let block = data.subdata(in: cursor..<end)
        output.append(hmacBlock(block, index: index, hmacBase: hmacBase))
        cursor = end
        index += 1
    }
    output.append(hmacBlock(Data(), index: index, hmacBase: hmacBase))
    return output
}

private func hmacBlock(_ block: Data, index: UInt64, hmacBase: Data) -> Data {
    var message = Data()
    appendU64(index, to: &message)
    appendU32(UInt32(block.count), to: &message)
    message.append(block)
    var output = Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: blockKey(index: index, base: hmacBase))))
    appendU32(UInt32(block.count), to: &output)
    output.append(block)
    return output
}

private func blockKey(index: UInt64, base: Data) -> Data {
    var material = Data()
    appendU64(index, to: &material)
    material.append(base)
    return sha512(material)
}

private struct SplitInner {
    var streamKey: Data
    var pieces: [InnerPiece]
    var xml: Data
}

private func splitInner(_ data: Data) throws -> SplitInner {
    var offset = 0
    var streamKey = Data()
    var algorithm: UInt32?
    var pieces: [InnerPiece] = []
    while offset + 5 <= data.count {
        let type = data[offset]
        let size = Int(readU32(data, offset + 1))
        let start = offset + 5
        guard start + size <= data.count else { throw KDBXError.truncated }
        let payload = data.subdata(in: start..<(start + size))
        offset = start + size
        switch type {
        case 0:
            guard algorithm == 3 else {
                throw KDBXError.unsupported("The inner stream is not ChaCha20.")
            }
            guard streamKey.count == 64 else { throw KDBXError.crypto("The inner stream key is missing.") }
            return SplitInner(streamKey: streamKey, pieces: pieces, xml: Data(data.suffix(from: offset)))
        case 1:
            if payload.count >= 4 {
                algorithm = readU32(payload, 0)
            }
        case 2:
            streamKey = payload
        case 3:
            if payload.isEmpty {
                pieces.append(.binary(flags: 0, data: Data()))
            } else {
                pieces.append(.binary(flags: payload[0], data: Data(payload.dropFirst())))
            }
        default:
            pieces.append(.other(type: type, payload: payload))
        }
    }
    throw KDBXError.truncated
}

private func xmlDocument(_ vault: Vault, stream: inout ChaCha20) -> Data {
    var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<KeePassFile>\n<Meta>\n"
    xml += tag("Generator", "PasswordPie")
    xml += tag("DatabaseName", vault.name)
    xml += "<MemoryProtection><ProtectTitle>False</ProtectTitle><ProtectUserName>False</ProtectUserName><ProtectPassword>True</ProtectPassword><ProtectURL>False</ProtectURL><ProtectNotes>False</ProtectNotes></MemoryProtection>\n"
    let recycle = UUID()
    xml += "<RecycleBinEnabled>True</RecycleBinEnabled>\n"
    xml += tag("RecycleBinUUID", base64UUID(recycle))
    xml += "</Meta>\n<Root>\n"
    xml += groupTreeXML(
        name: vault.rootName.isEmpty ? "PasswordPie" : vault.rootName,
        path: [],
        entries: vault.entries.filter { !$0.trashed },
        stream: &stream
    )
    let trashed = vault.entries.filter(\.trashed)
    if !trashed.isEmpty {
        xml += groupXML(name: "Recycle Bin", entries: trashed, recycle: true, recycleID: recycle, stream: &stream)
    }
    xml += "</Root>\n</KeePassFile>\n"
    return Data(xml.utf8)
}

/// Writes `entries` as nested groups following each entry's `groupPath`, so folders survive a save.
private func groupTreeXML(name: String, path: [String], entries: [VaultEntry], stream: inout ChaCha20) -> String {
    var xml = "<Group>\n"
    xml += tag("UUID", base64UUID(UUID()))
    xml += tag("Name", name)
    xml += entriesXML(entries.filter { $0.groupPath == path }, stream: &stream)
    var children: [String] = []
    for entry in entries where entry.groupPath.count > path.count && Array(entry.groupPath.prefix(path.count)) == path {
        let child = entry.groupPath[path.count]
        if !children.contains(child) { children.append(child) }
    }
    for child in children {
        xml += groupTreeXML(name: child, path: path + [child], entries: entries, stream: &stream)
    }
    xml += "</Group>\n"
    return xml
}

private func groupXML(name: String, entries: [VaultEntry], recycle: Bool, recycleID: UUID, stream: inout ChaCha20) -> String {
    var xml = "<Group>\n"
    xml += tag("UUID", base64UUID(recycle ? recycleID : UUID()))
    xml += tag("Name", name)
    xml += entriesXML(entries, stream: &stream)
    xml += "</Group>\n"
    return xml
}

private func entriesXML(_ entries: [VaultEntry], stream: inout ChaCha20) -> String {
    var xml = ""
    for entry in entries {
        xml += "<Entry>\n"
        xml += tag("UUID", base64UUID(entry.id))
        xml += tag("Tags", entry.tags)
        let now = isoDate(Date())
        xml += "<Times><CreationTime>\(now)</CreationTime><LastModificationTime>\(now)</LastModificationTime><LastAccessTime>\(now)</LastAccessTime><ExpiryTime>\(now)</ExpiryTime><Expires>False</Expires><UsageCount>0</UsageCount><LocationChanged>\(now)</LocationChanged></Times>\n"
        var fields = entry.fields
        if fields.isEmpty {
            fields = [VaultField(key: "Title", value: entry.title)]
        }
        for field in fields where !field.key.isEmpty {
            let protected = field.protected || field.key == "Password" || field.key == "otp"
            xml += "<String>\n"
            xml += tag("Key", field.key)
            if protected {
                let cipher = stream.xor(Data(field.value.utf8)).base64EncodedString()
                xml += "<Value Protected=\"True\">\(cipher)</Value>\n"
            } else {
                xml += tag("Value", field.value)
            }
            xml += "</String>\n"
        }
        xml += "</Entry>\n"
    }
    return xml
}

private func tag(_ name: String, _ value: String) -> String {
    "<\(name)>\(xmlEscape(value))</\(name)>\n"
}

private func xmlEscape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

private func isoDate(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

func base64UUID(_ id: UUID) -> String {
    uuidData(id).base64EncodedString()
}

private func uuidData(_ id: UUID) -> Data {
    withUnsafeBytes(of: id.uuid) { Data($0) }
}

func uuidFromBase64(_ text: String) -> UUID? {
    guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines), options: .ignoreUnknownCharacters),
          data.count == 16 else { return nil }
    return data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return nil }
        return UUID(uuid: base.load(as: uuid_t.self))
    }
}

private func random(_ count: Int) -> Data {
    var data = Data(count: count)
    data.withUnsafeMutableBytes { buffer in
        _ = SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
    }
    return data
}

private func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
private func sha512(_ data: Data) -> Data { Data(SHA512.hash(data: data)) }

private func aesECB(_ data: Data, key: Data) throws -> Data {
    try crypt(data, key: key, iv: nil, operation: CCOperation(kCCEncrypt), options: CCOptions(kCCOptionECBMode))
}

private func aesCBCEncrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
    try crypt(data, key: key, iv: iv, operation: CCOperation(kCCEncrypt), options: CCOptions(kCCOptionPKCS7Padding))
}

private func aesCBCDecrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
    try crypt(data, key: key, iv: iv, operation: CCOperation(kCCDecrypt), options: CCOptions(kCCOptionPKCS7Padding))
}

private func crypt(_ data: Data, key: Data, iv: Data?, operation: CCOperation, options: CCOptions) throws -> Data {
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
    guard status == kCCSuccess else { throw KDBXError.crypto("AES failed (\(status)).") }
    output.removeSubrange(written..<output.count)
    return output
}

private func uuidBytes(_ string: String) -> Data {
    let hex = string.replacingOccurrences(of: "-", with: "")
    var data = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        data.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return data
}

private func integer(_ data: Data?) -> UInt64 {
    guard let data else { return 0 }
    if data.count >= 8 { return readU64(data, 0) }
    if data.count >= 4 { return UInt64(readU32(data, 0)) }
    return 0
}

private func appendField(_ type: UInt8, _ payload: Data, to data: inout Data) {
    data.append(type)
    appendU32(UInt32(payload.count), to: &data)
    data.append(payload)
}

private func appendInner(_ type: UInt8, _ payload: Data, to data: inout Data) {
    appendField(type, payload, to: &data)
}

private func variantBytes(_ name: String, _ value: Data, to data: inout Data) {
    data.append(0x42)
    let nameBytes = Data(name.utf8)
    appendU32(UInt32(nameBytes.count), to: &data)
    data.append(nameBytes)
    appendU32(UInt32(value.count), to: &data)
    data.append(value)
}

private func variantU32(_ name: String, _ value: UInt32, to data: inout Data) {
    data.append(0x04)
    let nameBytes = Data(name.utf8)
    appendU32(UInt32(nameBytes.count), to: &data)
    data.append(nameBytes)
    appendU32(4, to: &data)
    appendU32(value, to: &data)
}

private func variantU64(_ name: String, _ value: UInt64, to data: inout Data) {
    data.append(0x05)
    let nameBytes = Data(name.utf8)
    appendU32(UInt32(nameBytes.count), to: &data)
    data.append(nameBytes)
    appendU32(8, to: &data)
    appendU64(value, to: &data)
}

private func appendU16(_ value: UInt16, to data: inout Data) {
    data.append(UInt8(value & 0xff))
    data.append(UInt8(value >> 8))
}

private func appendU32(_ value: UInt32, to data: inout Data) {
    data.append(UInt8(value & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 24) & 0xff))
}

private func appendU64(_ value: UInt64, to data: inout Data) {
    for shift in stride(from: 0, to: 64, by: 8) {
        data.append(UInt8((value >> shift) & 0xff))
    }
}

private func readU32(_ data: Data, _ offset: Int) -> UInt32 {
    UInt32(data[offset])
        | (UInt32(data[offset + 1]) << 8)
        | (UInt32(data[offset + 2]) << 16)
        | (UInt32(data[offset + 3]) << 24)
}

private func readU64(_ data: Data, _ offset: Int) -> UInt64 {
    var value: UInt64 = 0
    for index in 0..<8 {
        value |= UInt64(data[offset + index]) << (8 * index)
    }
    return value
}

private func le(_ value: UInt32) -> Data {
    var data = Data()
    appendU32(value, to: &data)
    return data
}
