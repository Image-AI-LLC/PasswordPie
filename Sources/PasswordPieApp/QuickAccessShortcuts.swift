import PasswordPieCore

/// A Quick Access shortcut from 1Password's Quick Access list. The main app's shortcuts are not included.
enum QuickAccessShortcut: Equatable {
    /// ⌘C. Username, or the first other field when the item has no username.
    case copyPrimary
    /// ⇧⌘C.
    case copyPassword
    /// ⌥⌘C.
    case copyOneTimePassword
    /// ⌘O. The same window as the pin button.
    case pinItem
    /// ⌥Return. Open the website and fill the username and password.
    case openAndFill
    /// ⇧Return. Fill the app that was focused before Quick Access.
    case fillFocusedApp
}

struct QuickAccessKeyPress: Equatable {
    var key: String
    var command = false
    var shift = false
    var option = false
    var control = false
    /// A selection in the search field keeps plain ⌘C as a text copy.
    var searchTextIsSelected = false
}

/// Escape clears a query. A second press, or Escape in an empty field, closes Quick Access.
enum QuickAccessEscape: Equatable {
    case clearSearch
    case close
}

func quickAccessShortcut(_ press: QuickAccessKeyPress) -> QuickAccessShortcut? {
    if press.control { return nil }
    let key = press.key.lowercased()
    if key == "\r" || key == "\n" {
        if press.command { return nil }
        if press.option && !press.shift { return .openAndFill }
        if press.shift && !press.option { return .fillFocusedApp }
        return nil
    }
    guard press.command else { return nil }
    switch key {
    case "c" where press.option && !press.shift:
        return .copyOneTimePassword
    case "c" where press.shift && !press.option:
        return .copyPassword
    case "c" where !press.shift && !press.option && !press.searchTextIsSelected:
        return .copyPrimary
    case "o" where !press.shift && !press.option:
        return .pinItem
    default:
        return nil
    }
}

func quickAccessEscape(searchIsEmpty: Bool) -> QuickAccessEscape {
    searchIsEmpty ? .close : .clearSearch
}

/// ⌘C copies the username. An item without one copies the first field the details view would show, except the one-time password.
func quickAccessPrimaryCopy(_ entry: VaultEntry) -> CopyTarget? {
    if !entry.username.isEmpty { return .username }
    if !entry.password.isEmpty { return .password }
    if !entry.url.isEmpty { return .url }
    let handled: Set<String> = ["title", "username", "password", "url", "notes", "otp"]
    if let field = entry.fields.first(where: { field in
        let key = field.key.lowercased()
        return !field.value.isEmpty
            && !handled.contains(key)
            && !key.hasPrefix("timeotp")
            && !EntryMerge.isReservedKey(field.key)
    }) {
        return .custom(field.key)
    }
    if !entry.notes.isEmpty { return .notes }
    return nil
}
