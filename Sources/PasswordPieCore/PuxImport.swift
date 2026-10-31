import Foundation

func loadPuxImport(_ data: Data) throws -> Vault {
    let files = try unzip(data)
    guard let export = files["export.data"] else {
        throw VaultOpenError.invalid("This export is missing export.data.")
    }
    let json = try JSON.parse(export)
    guard let accounts = json["accounts"]?.items, let account = accounts.first else {
        throw VaultOpenError.invalid("This export has no accounts.")
    }
    var entries: [VaultEntry] = []
    for vault in account["vaults"]?.items ?? [] {
        let name = vault["attrs"]?["name"]?.string ?? "Import"
        for item in vault["items"]?.items ?? [] {
            entries.append(readPuxItem(item, group: name, files: files))
        }
    }
    return Vault(name: "PUX Import", rootName: "PUX Import", entries: entries)
}

private func readPuxItem(_ item: JSON, group: String, files: [String: Data]) -> VaultEntry {
    var entry = VaultEntry(groupPath: [group])
    let overview = item["overview"]
    let details = item["details"]
    entry.title = overview?["title"]?.string ?? ""
    entry.url = overview?["url"]?.string ?? ""
    var extraURL = 1
    for raw in overview?["urls"]?.items ?? [] {
        let url = raw["url"]?.string ?? ""
        guard !url.isEmpty, url != entry.url else { continue }
        putField(&entry, "KP2A_URL_\(extraURL)", url)
        extraURL += 1
    }
    for tag in overview?["tags"]?.items ?? [] {
        addTag(&entry, tag.string ?? "")
    }
    if item["favIndex"]?.string == "1" { addTag(&entry, "Favorite") }
    if item["state"]?.string == "archived" { addTag(&entry, "Archived") }

    for field in details?["loginFields"]?.items ?? [] {
        let designation = field["designation"]?.string?.lowercased() ?? ""
        let value = field["value"]?.string ?? ""
        if designation == "username" { entry.username = value }
        if designation == "password" { entry.password = value }
    }
    if entry.password.isEmpty, let password = details?["password"]?.string { entry.password = password }
    entry.notes = details?["notesPlain"]?.string ?? ""

    for section in details?["sections"]?.items ?? [] {
        var prefix = section["title"]?.string ?? ""
        if prefix.isEmpty { prefix = String(UUID().uuidString.prefix(5)) }
        for field in section["fields"]?.items ?? [] {
            var name = field["title"]?.string ?? ""
            if name.isEmpty { name = field["id"]?.string ?? "field" }
            name = "\(prefix)_\(name)"
            guard let valueObject = field["value"]?.object, let key = valueObject.keys.first else { continue }
            let raw = valueObject[key]
            if key == "totp" {
                putOTP(&entry, jsonText(raw))
            } else if key == "file" {
                attachPuxFile(raw, files: files, entry: &entry)
            } else {
                let text = puxFieldText(key, raw)
                putField(&entry, name, text, protected: key == "concealed")
            }
        }
    }
    if let document = details?["documentAttributes"]?.object {
        attachPuxFile(document, files: files, entry: &entry)
    }
    return entry
}

private func puxFieldText(_ key: String, _ raw: Any?) -> String {
    if key == "date", let seconds = (raw as? NSNumber)?.uint64Value {
        return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }
    if key == "email", let map = raw as? [String: Any] {
        return jsonText(map["email_address"])
    }
    if key == "address", let map = raw as? [String: Any] {
        return "\(jsonText(map["street"]))\n\(jsonText(map["city"])), \(jsonText(map["state"])) \(jsonText(map["zip"]))\n\(jsonText(map["country"]))"
    }
    return jsonText(raw)
}

private func attachPuxFile(_ raw: Any?, files: [String: Data], entry: inout VaultEntry) {
    guard let map = raw as? [String: Any] else { return }
    let fileName = jsonText(map["fileName"])
    let documentID = jsonText(map["documentId"])
    guard !fileName.isEmpty, !documentID.isEmpty else { return }
    let key = "files/\(documentID)__\(fileName)"
    guard let data = files[key] else { return }
    entry.attachments.append(VaultAttachment(name: fileName, data: data))
}
