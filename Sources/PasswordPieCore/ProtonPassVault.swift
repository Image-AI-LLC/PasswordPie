import Foundation

func loadProtonPass(_ data: Data) throws -> Vault {
    let json = try JSON.parse(data)
    guard json.object != nil else { throw VaultOpenError.invalid("This Proton Pass export is not a JSON object.") }
    if json["encrypted"]?.bool == true {
        throw VaultOpenError.unsupported("Encrypted Proton Pass exports are not supported. Export the vault without encryption.")
    }
    guard let vaults = json["vaults"]?.object else {
        throw VaultOpenError.invalid("This JSON file is not a Proton Pass export.")
    }
    var entries: [VaultEntry] = []
    for (_, vaultValue) in vaults {
        let vault = JSON(value: vaultValue)
        let group = vault["name"]?.string ?? "Proton Pass"
        for item in vault["items"]?.items ?? [] {
            entries.append(readProtonItem(item, group: group))
        }
    }
    return Vault(name: "Proton Pass Import", rootName: "Proton Pass Import", entries: entries)
}

private func readProtonItem(_ item: JSON, group: String) -> VaultEntry {
    var entry = VaultEntry(groupPath: [group])
    let data = item["data"]
    let metadata = data?["metadata"]
    entry.title = metadata?["name"]?.string ?? ""
    entry.notes = metadata?["note"]?.string ?? ""
    if item["pinned"]?.bool == true { addTag(&entry, "Favorite") }
    let type = data?["type"]?.string?.lowercased() ?? ""
    let content = data?["content"]

    if type == "login" {
        entry.username = content?["itemUsername"]?.string ?? ""
        entry.password = content?["password"]?.string ?? ""
        if let totp = content?["totpUri"]?.string, !totp.isEmpty { putOTP(&entry, totp) }
        let email = content?["itemEmail"]?.string ?? ""
        if entry.username.isEmpty { entry.username = email } else { putField(&entry, "login_email", email) }
        var extra = 1
        for url in content?["urls"]?.items ?? [] {
            let text = url.string ?? ""
            guard !text.isEmpty else { continue }
            if entry.url.isEmpty { entry.url = text } else { putField(&entry, "KP2A_URL_\(extra)", text); extra += 1 }
        }
    } else if type == "creditcard" {
        entry.username = content?["number"]?.string ?? ""
        entry.password = content?["verificationNumber"]?.string ?? ""
        for key in ["cardholderName", "pin", "expirationDate"] {
            putField(&entry, "card_\(key)", content?[key]?.string ?? "", protected: key == "pin")
        }
    } else if type == "wifi" {
        entry.username = content?["ssid"]?.string ?? ""
        entry.password = content?["password"]?.string ?? ""
        putField(&entry, "wifi_security", content?["security"]?.string ?? "")
    } else if type == "sshkey" {
        putField(&entry, "ssh_public_key", content?["publicKey"]?.string ?? "")
        putField(&entry, "ssh_private_key", content?["privateKey"]?.string ?? "", protected: true)
    } else if type != "custom" && type != "note" && !type.isEmpty {
        entry.notes = "Unknown entry type '\(type)'. Content data fields have been added as attributes.\n\n\(entry.notes)"
        for (key, value) in content?.object ?? [:] {
            putField(&entry, "content_\(key)", jsonText(value))
        }
    }

    for field in data?["extraFields"]?.items ?? [] {
        let name = field["fieldName"]?.string ?? "field"
        let fieldType = field["type"]?.string?.lowercased() ?? ""
        let value = fieldType == "totp" ? (field["data"]?["totpUri"]?.string ?? "") : (field["data"]?["content"]?.string ?? "")
        putField(&entry, name, value, protected: fieldType == "hidden")
    }
    if item["state"]?.int == 2 { addTag(&entry, "Expired") }
    return entry
}
