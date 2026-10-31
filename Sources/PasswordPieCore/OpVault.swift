import Foundation

private let opVaultCategories: [String: String] = [
    "001": "Login", "002": "Credit Card", "003": "Secure Note", "004": "Identity", "005": "Password",
    "099": "Tombstone", "100": "Software License", "101": "Bank Account", "102": "Database",
    "103": "Driver License", "104": "Outdoor License", "105": "Membership", "106": "Passport",
    "107": "Rewards", "108": "SSN", "109": "Router", "110": "Server", "111": "Email"
]

func loadOpVault(directory: URL, password: String) throws -> Vault {
    let root = opVaultRoot(directory)
    let profile = try wrappedJSON(root.appendingPathComponent("profile.js"), prefix: "var profile=", suffix: ";")
    let derived = try opVaultMasterKeys(profile, password: password)
    var entries: [VaultEntry] = []
    let bands = "0123456789ABCDEF".map { root.appendingPathComponent("band_\($0).js") }
    for band in bands where FileManager.default.fileExists(atPath: band.path) {
        let json = try wrappedJSON(band, prefix: "ld(", suffix: ");")
        for (_, value) in json.object ?? [:] {
            let item = JSON(value: value)
            if let entry = try readOpVaultItem(item, keys: derived, attachmentDirectory: root) {
                entries.append(entry)
            }
        }
    }
    let name = directory.deletingPathExtension().lastPathComponent
    return Vault(name: name, rootName: name, entries: entries)
}

private struct OpVaultKeys {
    var master: Data
    var masterHMAC: Data
    var overview: Data
    var overviewHMAC: Data
}

private func opVaultRoot(_ directory: URL) -> URL {
    let nested = directory.appendingPathComponent("default")
    if FileManager.default.fileExists(atPath: nested.appendingPathComponent("profile.js").path) { return nested }
    return directory
}

private func wrappedJSON(_ url: URL, prefix: String, suffix: String) throws -> JSON {
    guard var text = try? String(contentsOf: url, encoding: .utf8) else {
        throw VaultOpenError.invalid("Cannot read \(url.lastPathComponent).")
    }
    if text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
    if text.hasSuffix(suffix) { text.removeLast(suffix.count) }
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return try JSON.parseObject(text)
}

private func opVaultMasterKeys(_ profile: JSON, password: String) throws -> OpVaultKeys {
    let iterations = profile["iterations"]?.int ?? 0
    guard iterations > 0, let saltText = profile["salt"]?.string, let salt = decodeBase64Loose(saltText) else {
        throw VaultOpenError.invalid("The OPVault profile is missing its key parameters.")
    }
    let derived = try importPBKDF2(password: Data(password.utf8), salt: salt, iterations: iterations, length: 64, sha512: true)
    let enc = derived.prefix(32)
    let mac = derived.suffix(32)
    let master = try splitComposite(profile["masterKey"]?.string ?? "", enc: Data(enc), mac: Data(mac))
    let overview = try splitComposite(profile["overviewKey"]?.string ?? "", enc: Data(enc), mac: Data(mac))
    return OpVaultKeys(master: master.0, masterHMAC: master.1, overview: overview.0, overviewHMAC: overview.1)
}

private func splitComposite(_ text: String, enc: Data, mac: Data) throws -> (Data, Data) {
    let clear = try decodeOpData01Base64(text, key: enc, hmacKey: mac)
    let digest = importSHA512(clear)
    return (Data(digest.prefix(32)), Data(digest.suffix(32)))
}

private func readOpVaultItem(_ item: JSON, keys: OpVaultKeys, attachmentDirectory: URL) throws -> VaultEntry? {
    let uuid = item["uuid"]?.string ?? ""
    guard uuid.count == 32 || uuid.count == 36 else { return nil }
    guard let overviewText = item["o"]?.string else { return nil }
    let overviewData = try decodeOpData01Base64(overviewText, key: keys.overview, hmacKey: keys.overviewHMAC)
    let overview = try JSON.parse(overviewData)
    let category = item["category"]?.string ?? ""
    let group = opVaultCategories[category] ?? ""
    var entry = VaultEntry(groupPath: group.isEmpty ? [] : [group])
    entry.title = overview["title"]?.string ?? ""
    entry.url = overview["url"]?.string ?? ""
    var extra = 1
    for url in overview["URLs"]?.items ?? [] {
        let text = url["u"]?.string ?? ""
        guard !text.isEmpty, text != entry.url else { continue }
        putField(&entry, "KP2A_URL_\(extra)", text)
        extra += 1
    }
    for tag in overview["tags"]?.items ?? [] { addTag(&entry, tag.string ?? "") }
    if item["trashed"]?.bool == true {
        entry.trashed = true
        entry.groupPath = []
    }

    let (itemKey, itemHMAC) = try decryptItemKey(item["k"]?.string ?? "", keys: keys)
    guard let detailText = item["d"]?.string else { return entry }
    let detailData = try decodeOpData01Base64(detailText, key: itemKey, hmacKey: itemHMAC)
    let detail = try JSON.parse(detailData)
    if let notes = detail["notesPlain"]?.string { entry.notes = notes }
    if let password = detail["password"]?.string, !password.isEmpty { entry.password = password }
    for field in detail["fields"]?.items ?? [] {
        let designation = field["designation"]?.string ?? ""
        let value = field["value"]?.string ?? ""
        if designation == "password" { entry.password = value }
        if designation == "username" { entry.username = value }
    }
    for section in detail["sections"]?.items ?? [] {
        let title = section["title"]?.string ?? ""
        for field in section["fields"]?.items ?? [] {
            fillOpVaultField(field, section: title, entry: &entry)
        }
    }
    try attachOpVaultFiles(uuid: uuid, directory: attachmentDirectory, itemKey: itemKey, itemHMAC: itemHMAC, overviewKey: keys.overview, overviewHMAC: keys.overviewHMAC, entry: &entry)
    return entry
}

private func decryptItemKey(_ text: String, keys: OpVaultKeys) throws -> (Data, Data) {
    guard let blob = decodeBase64Loose(text), blob.count == 112 else {
        throw VaultOpenError.crypto("An OPVault item key is malformed.")
    }
    let signed = blob.prefix(80)
    let mac = blob.suffix(32)
    guard importHMACSHA256(Data(signed), key: keys.masterHMAC) == mac else { throw VaultOpenError.wrongPassword }
    let iv = blob.prefix(16)
    let cipher = blob.subdata(in: 16..<80)
    let clear = try aesCBCDecryptRaw(cipher, key: keys.master, iv: Data(iv))
    return (clear.prefix(32), clear.suffix(32))
}

private func fillOpVaultField(_ field: JSON, section: String, entry: inout VaultEntry) {
    guard field["v"] != nil else { return }
    let name = field["n"]?.string ?? ""
    let text = field["t"]?.string ?? ""
    let kind = field["k"]?.string ?? ""
    if name.hasPrefix("TOTP_") {
        let raw = field["v"]?.string ?? ""
        if raw.hasPrefix("otpauth://") { putOTP(&entry, raw) } else if !raw.isEmpty { putOTP(&entry, raw) }
        return
    }
    let attribute = opVaultAttributeName(section: section, name: name, text: text)
    if attribute == "Password" {
        entry.password = field["v"]?.string ?? entry.password
        return
    }
    if attribute == "UserName" {
        entry.username = field["v"]?.string ?? entry.username
        return
    }
    if attribute == "URL" {
        entry.url = field["v"]?.string ?? entry.url
        return
    }
    if kind == "address", let parts = field["v"]?.object {
        for (part, value) in parts { putField(&entry, "\(attribute)_\(part)", jsonText(value)) }
        return
    }
    let value = field["v"]?.string ?? jsonText(field["v"]?.value)
    putField(&entry, attribute.isEmpty ? name : attribute, value, protected: kind == "password" || kind == "concealed")
}

private func opVaultAttributeName(section: String, name: String, text: String) -> String {
    if name.hasPrefix("TOTP_") { return name }
    let lowName = name.lowercased()
    let lowText = text.lowercased()
    if section.isEmpty || name.hasPrefix("address") {
        if lowName == "password" || lowText == "password" { return "Password" }
        if lowName == "username" || lowText == "username" { return "UserName" }
        if lowName == "url" || lowText == "url" || lowName == "hostname" || lowText == "server" || lowName == "website" { return "URL" }
        return text.isEmpty ? name : text
    }
    return text.isEmpty ? name : "\(section)_\(text)"
}

private func attachOpVaultFiles(uuid: String, directory: URL, itemKey: Data, itemHMAC: Data, overviewKey: Data, overviewHMAC: Data, entry: inout VaultEntry) throws {
    let prefix = uuid.replacingOccurrences(of: "-", with: "").uppercased() + "_"
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    for name in names where name.hasPrefix(prefix) && name.hasSuffix(".attachment") {
        let url = directory.appendingPathComponent(name)
        guard let payload = try opVaultAttachment(url, itemKey: itemKey, itemHMAC: itemHMAC, overviewKey: overviewKey, overviewHMAC: overviewHMAC) else { continue }
        entry.attachments.append(payload)
    }
}

private func opVaultAttachment(_ url: URL, itemKey: Data, itemHMAC: Data, overviewKey: Data, overviewHMAC: Data) throws -> VaultAttachment? {
    let data = try Data(contentsOf: url)
    guard data.starts(with: Data("OPCLDAT".utf8)), data.count > 16 else { return nil }
    let metadataLength = Int(readU16LE(data, 8))
    let iconLength = Int(readU32LE(data, 12))
    var offset = 16
    guard offset + metadataLength + iconLength <= data.count else { return nil }
    let metadataBytes = data.subdata(in: offset..<(offset + metadataLength))
    offset += metadataLength
    let icon = data.subdata(in: offset..<(offset + iconLength))
    offset += iconLength
    _ = try decodeOpData01(icon, key: itemKey, hmacKey: itemHMAC)
    let metadata = try JSON.parse(metadataBytes)
    if metadata["trashed"]?.bool == true { return nil }
    let payload = try decodeOpData01(data.suffix(from: offset), key: itemKey, hmacKey: itemHMAC)
    var fileName = url.deletingPathExtension().lastPathComponent
    if let overviewText = metadata["overview"]?.string {
        let overview = try JSON.parse(try decodeOpData01Base64(overviewText, key: overviewKey, hmacKey: overviewHMAC))
        if let name = overview["filename"]?.string, !name.isEmpty { fileName = name }
    }
    return VaultAttachment(name: fileName, data: Data(payload))
}
