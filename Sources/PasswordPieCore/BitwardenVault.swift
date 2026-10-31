import Foundation
import CArgon2

func loadBitwarden(_ data: Data, password: String) throws -> Vault {
    var json = try JSON.parse(data)
    guard json.object != nil else { throw VaultOpenError.invalid("This Bitwarden export is not a JSON object.") }
    if json["encrypted"]?.bool == true {
        json = try decryptBitwarden(json, password: password)
    }
    let folderKey = json["folders"] != nil ? "folders" : "collections"
    guard json[folderKey] != nil, json["items"] != nil else {
        throw VaultOpenError.invalid("This JSON file is not a Bitwarden export.")
    }
    var folders: [String: [String]] = [:]
    for folder in json[folderKey]?.items ?? [] {
        let id = folder["id"]?.string ?? ""
        let name = folder["name"]?.string ?? ""
        folders[id] = name.split(separator: "/").map { String($0) }.filter { !$0.isEmpty }
    }
    var entries: [VaultEntry] = []
    for item in json["items"]?.items ?? [] {
        entries.append(readBitwardenItem(item, folders: folders))
    }
    return Vault(name: "Bitwarden Import", rootName: "Bitwarden Import", entries: entries)
}

private func readBitwardenItem(_ item: JSON, folders: [String: [String]]) -> VaultEntry {
    var folderID = item["folderId"]?.string ?? ""
    if folderID.isEmpty { folderID = item["collectionIds"]?.items.first?.string ?? "" }
    var entry = VaultEntry(groupPath: folders[folderID] ?? [])
    entry.title = item["name"]?.string ?? ""
    entry.notes = item["notes"]?.string ?? ""
    if item["favorite"]?.bool == true { addTag(&entry, "Favorite") }

    if let login = item["login"] {
        entry.username = login["username"]?.string ?? ""
        entry.password = login["password"]?.string ?? ""
        if let totp = login["totp"]?.string, !totp.isEmpty { putOTP(&entry, totp) }
        for credential in login["fido2Credentials"]?.items ?? [] {
            readPasskey(credential, entry: &entry)
        }
        var extra = 1
        for uri in login["uris"]?.items ?? [] {
            let url = uri["uri"]?.string ?? ""
            guard !url.isEmpty else { continue }
            if entry.url.isEmpty {
                entry.url = url
            } else {
                putField(&entry, "KP2A_URL_\(extra)", url)
                extra += 1
            }
        }
    }

    if let identity = item["identity"] {
        let name = [identity["title"], identity["firstName"], identity["middleName"], identity["lastName"]]
            .compactMap { $0?.string }.filter { !$0.isEmpty }.joined(separator: " ")
        putField(&entry, "identity_name", name)
        let streets = [identity["address1"], identity["address2"], identity["address3"]]
            .compactMap { $0?.string }.filter { !$0.isEmpty }
        let address = streets.joined(separator: "\n")
            + "\n\(identity["city"]?.string ?? ""), \(identity["state"]?.string ?? "") \(identity["postalCode"]?.string ?? "")\n"
            + (identity["country"]?.string ?? "")
        putField(&entry, "identity_address", address)
        for key in ["company", "email", "phone", "ssn", "passportNumber", "licenseNumber"] {
            let sensitive = key == "ssn" || key == "passportNumber" || key == "licenseNumber"
            putField(&entry, "identity_\(key)", identity[key]?.string ?? "", protected: sensitive)
        }
        let username = identity["username"]?.string ?? ""
        if !username.isEmpty {
            if entry.username.isEmpty { entry.username = username } else { putField(&entry, "identity_username", username) }
        }
    }

    if let card = item["card"] {
        for key in ["cardholderName", "brand", "number", "expMonth", "expYear", "code"] {
            putField(&entry, "card_\(key)", card[key]?.string ?? "", protected: key == "code")
        }
    }

    for field in item["fields"]?.items ?? [] {
        let name = field["name"]?.string ?? "field"
        putField(&entry, name, field["value"]?.string ?? "", protected: field["type"]?.int == 1)
    }

    let history = (item["passwordHistory"]?.items ?? []).compactMap { $0["password"]?.string }.filter { !$0.isEmpty }
    if !history.isEmpty { putField(&entry, "Password History", history.joined(separator: "\n"), protected: true) }
    return entry
}

private func readPasskey(_ credential: JSON, entry: inout VaultEntry) {
    if let hexID = credential["credentialId"]?.string, let bytes = Data(hexEncoded: hexID) {
        putField(&entry, "KPEX_PASSKEY_CREDENTIAL_ID", base64URLNoPadding(bytes), protected: true)
    }
    if let keyValue = credential["keyValue"]?.string, let bytes = decodeBase64Loose(keyValue) {
        let pem = "-----BEGIN PRIVATE KEY-----\(bytes.base64EncodedString())-----END PRIVATE KEY-----"
        putField(&entry, "KPEX_PASSKEY_PRIVATE_KEY_PEM", pem, protected: true)
    }
    putField(&entry, "KPEX_PASSKEY_USERNAME", credential["userName"]?.string ?? "")
    putField(&entry, "KPEX_PASSKEY_RELYING_PARTY", credential["rpId"]?.string ?? "")
    putField(&entry, "KPEX_PASSKEY_USER_HANDLE", credential["userHandle"]?.string ?? "", protected: true)
    addTag(&entry, "Passkey")
}

private func decryptBitwarden(_ json: JSON, password: String) throws -> JSON {
    guard let kdfType = json["kdfType"]?.int, let saltText = json["salt"]?.string else {
        throw VaultOpenError.unsupported("This Bitwarden export is encrypted in an unsupported way. Export it with a password.")
    }
    let saltBytes = Data(saltText.utf8)
    let master: Data
    if kdfType == 0 {
        let iterations = json["kdfIterations"]?.int ?? 0
        guard iterations > 0 else { throw VaultOpenError.crypto("Bitwarden KDF iterations are missing.") }
        master = try importPBKDF2(password: Data(password.utf8), salt: saltBytes, iterations: iterations, length: 32, sha512: false)
    } else if kdfType == 1 {
        let salt = importSHA256(saltBytes)
        guard let iterations = importUInt32(json["kdfIterations"]?.int ?? 0),
              let memory = importUInt32Product(json["kdfMemory"]?.int ?? 0, 1024),
              let lanes = importUInt32(json["kdfParallelism"]?.int ?? 0) else {
            throw VaultOpenError.crypto("Bitwarden Argon2 parameters are incomplete.")
        }
        master = try argon2(Data(password.utf8), salt: salt, memoryKiB: memory, iterations: iterations, parallelism: lanes, version: 0x13, type: Argon2_id)
    } else {
        throw VaultOpenError.unsupported("Only PBKDF2 and Argon2id Bitwarden exports can be opened.")
    }
    let macKey = hkdfExpandSHA256(prk: master, info: Data("mac".utf8), length: 32)
    let encKey = hkdfExpandSHA256(prk: master, info: Data("enc".utf8), length: 32)
    let validation = json["encKeyValidation_DO_NOT_EDIT"]?.string ?? ""
    try checkBitwardenMAC(validation, macKey: macKey)
    let payload = json["data"]?.string ?? ""
    let clear = try decryptBitwardenField(payload, key: encKey)
    return try JSON.parse(clear)
}

private func checkBitwardenMAC(_ field: String, macKey: Data) throws {
    let parts = field.split(separator: ".").dropFirst().joined(separator: ".").split(separator: "|").map(String.init)
    guard parts.count >= 3,
          let iv = decodeBase64Loose(parts[0]),
          let cipher = decodeBase64Loose(parts[1]) else {
        throw VaultOpenError.invalid("The Bitwarden key check is malformed.")
    }
    let mac = importHMACSHA256(iv + cipher, key: macKey).base64EncodedString()
    guard mac == parts[2] else { throw VaultOpenError.wrongPassword }
}

private func decryptBitwardenField(_ field: String, key: Data) throws -> Data {
    let parts = field.split(separator: ".").dropFirst().joined(separator: ".").split(separator: "|").map(String.init)
    guard parts.count >= 2, let iv = decodeBase64Loose(parts[0]), let cipher = decodeBase64Loose(parts[1]) else {
        throw VaultOpenError.invalid("The encrypted Bitwarden payload is malformed.")
    }
    return try aesCBCDecryptPKCS7(cipher, key: key, iv: iv)
}

private extension Data {
    init?(hexEncoded text: String) {
        // Qt's fromHex skips dashes, so a UUID-shaped credential id still decodes.
        let hex = String(text.filter(\.isHexDigit))
        guard !hex.isEmpty, hex.count % 2 == 0 else { return nil }
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
