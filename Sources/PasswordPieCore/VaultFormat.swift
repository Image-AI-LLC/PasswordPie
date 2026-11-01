import Foundation

public enum VaultFormatKind: String, Sendable {
    case kdbx
    case keepass1
    case pux
    case opVault
    case bitwarden
    case protonPass
    case csv
}

public enum VaultFormat {
    /// True when a later save can write this file back as KDBX without destroying another format.
    public static func writesKDBX(_ url: URL) -> Bool {
        !isDirectory(url) && url.pathExtension.lowercased() == "kdbx"
    }

    /// An imported file is saved as a new .kdbx. That file needs a password the lock screen can ask for again.
    public static func blocksImportSave(writesKDBX: Bool, password: String) -> Bool {
        !writesKDBX && password.isEmpty
    }

    /// A new .kdbx next to an imported file. Never returns `source`, and never replaces a file that already exists.
    public static func importedKDBXURL(beside source: URL, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> URL {
        let directory = source.deletingLastPathComponent()
        var stem = isDirectory(source) ? source.lastPathComponent : source.deletingPathExtension().lastPathComponent
        if stem.lowercased().hasSuffix(".opvault") {
            stem = String(stem.dropLast(".opvault".count))
        }
        if stem.isEmpty { stem = "PasswordPie" }
        var names = ["\(stem).kdbx", "\(stem) PasswordPie.kdbx"]
        var number = 2
        while names.count < 100 {
            names.append("\(stem) PasswordPie \(number).kdbx")
            number += 1
        }
        for name in names {
            let url = directory.appendingPathComponent(name)
            if !exists(url.path) { return url }
        }
        return directory.appendingPathComponent("\(stem) PasswordPie \(UUID().uuidString).kdbx")
    }

    public static func load(url: URL, password: String, keyFile: Data? = nil) throws -> Vault {
        if isDirectory(url) {
            return try loadOpVault(directory: url, password: password)
        }
        let data = try Data(contentsOf: url)
        return try load(data: data, password: password, keyFile: keyFile, fileName: url.lastPathComponent)
    }

    public static func load(data: Data, password: String, keyFile: Data? = nil, fileName: String = "") throws -> Vault {
        switch sniff(data, fileName: fileName) {
        case .kdbx:
            return try KDBX.loadRecovering(data: data, password: password)
        case .keepass1:
            return try loadKeePass1(data, password: password, keyFile: keyFile)
        case .pux:
            return try loadPuxImport(data)
        case .bitwarden:
            return try loadBitwarden(data, password: password)
        case .protonPass:
            return try loadProtonPass(data)
        case .csv:
            return try loadCSV(data)
        case .opVault:
            throw VaultOpenError.invalid("An OPVault is a folder. Choose the .opvault directory.")
        }
    }

    private static func sniff(_ data: Data, fileName: String) -> VaultFormatKind {
        if data.count >= 8 {
            let sig1 = readU32LE(data, 0)
            let sig2 = readU32LE(data, 4)
            if sig1 == 0x9AA2D903 && sig2 == 0xB54BFB67 { return .kdbx }
            if sig1 == 0x9AA2D903 && sig2 == 0xB54BFB65 { return .keepass1 }
        }
        if data.count >= 4 && readU32LE(data, 0) == 0x04034b50 { return .pux }
        let extensionName = (fileName as NSString).pathExtension.lowercased()
        if extensionName == "csv" { return .csv }
        if let text = String(data: data.prefix(1), encoding: .utf8), text == "{" || text == "[" {
            if let json = try? JSON.parse(data), json.object != nil {
                if json["vaults"]?.object != nil { return .protonPass }
                if json["items"] != nil && (json["folders"] != nil || json["collections"] != nil || json["encrypted"]?.bool == true) {
                    return .bitwarden
                }
            }
        }
        if extensionName == "json" { return .bitwarden }
        return .csv
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }
}
