import PasswordPieCore

/// A Quick Access shortcut from 1Password's Quick Access list. The main app's shortcuts are not included.
enum QuickAccessShortcut: Equatable {
    /// ⌃⌘C. Username, or the first other field when the item has no username.
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
}

/// Escape clears a query. A second press, or Escape in an empty field, closes Quick Access.
enum QuickAccessEscape: Equatable {
    case clearSearch
    case close
}

func quickAccessShortcut(_ press: QuickAccessKeyPress) -> QuickAccessShortcut? {
    let key = press.key.lowercased()
    if press.control {
        return key == "c" && press.command && !press.shift && !press.option ? .copyPrimary : nil
    }
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
    case "o" where !press.shift && !press.option:
        return .pinItem
    default:
        return nil
    }
}

/// The keys go straight to the text view with no menu validation, and with nothing selected Copy and Cut
/// overwrite the clipboard with an empty string.
func editCommandWouldEmptyClipboard(key: String, selectionLength: Int?) -> Bool {
    (key == "c" || key == "x") && selectionLength == 0
}

func quickAccessEscape(searchIsEmpty: Bool) -> QuickAccessEscape {
    searchIsEmpty ? .close : .clearSearch
}

/// The field a copy shortcut puts on the clipboard. The other shortcuts copy nothing.
func quickAccessCopyTarget(_ shortcut: QuickAccessShortcut, of entry: VaultEntry) -> CopyTarget? {
    switch shortcut {
    case .copyPrimary: quickAccessPrimaryCopy(entry)
    case .copyPassword: .password
    case .copyOneTimePassword: .oneTimePassword
    case .pinItem, .openAndFill, .fillFocusedApp: nil
    }
}

/// ⌃⌘C copies the username. An item without one copies the first field the details view would show, except the one-time password.
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
