import Foundation

/// Item categories PasswordPie can derive from a KeePass entry.
public enum ItemCategory: Int, CaseIterable, Sendable, Comparable {
    case login
    case secureNote
    case creditCard
    case identity
    case password
    case document

    public static func < (lhs: ItemCategory, rhs: ItemCategory) -> Bool { lhs.rawValue < rhs.rawValue }

    public var singularName: String {
        switch self {
        case .login: return "Login"
        case .secureNote: return "Secure Note"
        case .creditCard: return "Credit Card"
        case .identity: return "Identity"
        case .password: return "Password"
        case .document: return "Document"
        }
    }

    public var pluralName: String {
        switch self {
        case .login: return "Logins"
        case .secureNote: return "Secure Notes"
        case .creditCard: return "Credit Cards"
        case .identity: return "Identities"
        case .password: return "Passwords"
        case .document: return "Documents"
        }
    }

    /// Header of the group in search results.
    public var searchGroupTitle: String {
        switch self {
        case .login: return "Open Login"
        case .creditCard: return "Fill Credit Card"
        case .identity: return "Fill Identity"
        case .password: return "Show Password"
        default: return pluralName
        }
    }

    /// Sort key for category groups.
    var order: Int {
        switch self {
        case .login: return 10000
        case .secureNote: return 20000
        case .creditCard: return 30000
        case .identity: return 40000
        case .password: return 50000
        case .document: return 60000
        }
    }
}

private let cardFieldKeys: Set<String> = [
    "card number", "cardnumber", "credit card number", "ccnum", "cc number",
    "card_number", "card_cardholdername", "cardholder name"
]
private let identityFieldKeys: Set<String> = [
    "first name", "firstname", "last name", "lastname", "identity_name", "identity_address"
]

extension VaultEntry {
    /// KeePass has no item types, so the category comes from which fields are filled in.
    public var category: ItemCategory {
        let keys = Set(fields.filter { !$0.value.isEmpty }.map { $0.key.lowercased() })
        if !keys.isDisjoint(with: cardFieldKeys) { return .creditCard }
        if !keys.isDisjoint(with: identityFieldKeys) { return .identity }
        if !url.isEmpty || !username.isEmpty { return .login }
        if !password.isEmpty { return .password }
        return .secureNote
    }
}
