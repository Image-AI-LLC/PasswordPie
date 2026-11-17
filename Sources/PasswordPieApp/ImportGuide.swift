import Foundation
import PasswordPieCore

/// One source in Preferences > Import (docs/UX.md, "Import with a guide").
struct ImportTile: Identifiable, Equatable {
    enum Kind: Equatable {
        case source(BrowserImportSource)
        /// Nothing to import: a KeePass database is opened as it is.
        case keePass
    }

    enum Group: String, CaseIterable {
        case browser = "My browser"
        case manager = "A password manager"
        case other = "Something else"
    }

    let id: String
    let name: String
    let group: Group
    let kind: Kind
    /// The apps whose icon stands for this source, in order. The first one installed is shown.
    var bundleIDs: [String] = []
    /// Drawn on a tile when the source is not an app.
    var symbol: String?

    var source: BrowserImportSource? {
        if case .source(let source) = kind { return source }
        return nil
    }

    static let all: [ImportTile] = [
        ImportTile(id: "chrome", name: "Chrome", group: .browser, kind: .source(.chrome), bundleIDs: ["com.google.Chrome"]),
        // Safari keeps its passwords in the Passwords app, so both tiles lead to the same import.
        ImportTile(id: "safari", name: "Safari", group: .browser, kind: .source(.applePasswords), bundleIDs: ["com.apple.Safari"]),
        ImportTile(id: "firefox", name: "Firefox", group: .browser, kind: .source(.firefox), bundleIDs: ["org.mozilla.firefox"]),
        ImportTile(id: "edge", name: "Edge", group: .browser, kind: .source(.edge), bundleIDs: ["com.microsoft.edgemac"]),
        ImportTile(id: "brave", name: "Brave", group: .browser, kind: .source(.brave), bundleIDs: ["com.brave.Browser"]),
        ImportTile(id: "apple-passwords", name: "Apple Passwords", group: .manager, kind: .source(.applePasswords), bundleIDs: ["com.apple.Passwords"]),
        ImportTile(id: "1password", name: "1Password", group: .manager, kind: .source(.onePassword), bundleIDs: ["com.1password.1password", "com.agilebits.onepassword7"]),
        ImportTile(id: "bitwarden", name: "Bitwarden", group: .manager, kind: .source(.bitwarden), bundleIDs: ["com.bitwarden.desktop"]),
        ImportTile(id: "proton-pass", name: "Proton Pass", group: .manager, kind: .source(.protonPass), bundleIDs: ["me.proton.pass.electron"]),
        ImportTile(id: "lastpass", name: "LastPass", group: .manager, kind: .source(.lastPass), bundleIDs: ["com.lastpass.lastpassmacdesktop", "com.lastpass.LastPass"]),
        ImportTile(id: "dashlane", name: "Dashlane", group: .manager, kind: .source(.dashlane), bundleIDs: ["com.dashlane.dashlanephonefinal", "com.dashlane.Dashlane"]),
        ImportTile(id: "keepass", name: "KeePass", group: .manager, kind: .keePass, bundleIDs: ["org.keepassxc.keepassxc", "com.markmcguill.strongbox.mac", "com.keepassium.mac"]),
        ImportTile(id: "csv", name: "Another App", group: .other, kind: .source(.csv), symbol: "tablecells")
    ]

    static func tile(_ id: String) -> ImportTile? { all.first { $0.id == id } }
}

/// What a source's page says: how to get the file out of the other app, and which file that is. Steps are Markdown,
/// with the names of menus and buttons in bold.
struct ImportGuide: Equatable {
    struct Steps: Equatable {
        var title: String
        var steps: [String]
        /// An address the user pastes into the browser. A browser does not open its own pages for another app.
        var address: String?
        /// The app a button under the steps opens.
        var opens: String?
    }

    /// Said before anything else, when the source needs a word of explanation.
    var intro: String?
    /// macOS 26 and later: Apple Passwords hands its items over with no file.
    var withoutFile: Steps?
    /// Nil when there is nothing to export (KeePass).
    var export: Steps?
    /// The file names the drop zone names.
    var files: String
    /// One line on where the items land and what importing again does.
    var after: String

    static let loginPassword = "Enter the password you use to log in to your Mac."

    /// `exchange`: Passwords can send its items to this app. `macOS`: the major version, which decides where Apple keeps
    /// the export command.
    static func guide(for tile: ImportTile, exchange: Bool, macOS: Int) -> ImportGuide {
        guard let source = tile.source else {
            return ImportGuide(
                intro: "PasswordPie's database is a KeePass database, so there is nothing to export or convert. Open your .kdbx file, or a .kdb file from KeePass 1, and unlock it with its password. KeePassXC, Strongbox and KeePassium can keep using the same file.",
                export: nil,
                files: "",
                after: ""
            )
        }
        let after = source.exportsWholeList
            ? "They go into a “\(source.label)” group. Import again later to update it: new sites are added, changed passwords are updated, and sites that are gone move to the Recycle Bin. Your own items are never changed."
            : "They go into a “\(source.label)” group\(source.keepsFolders ? ", with their folders" : ""). Importing again adds what is new and updates changed passwords. Nothing is removed, and your own items are never changed."
        switch source {
        case .chrome:
            return ImportGuide(
                export: Steps(
                    title: "Export your passwords from Chrome",
                    steps: [
                        "In Chrome, open the **⋮** menu and choose **Passwords and autofill > Google Password Manager**.",
                        "Click **Settings** in the sidebar.",
                        "Beside **Export passwords**, click **Download file**.",
                        loginPassword,
                        "Save **Chrome Passwords.csv**, for example to the Desktop."
                    ],
                    address: "chrome://password-manager/settings",
                    opens: "Chrome"
                ),
                files: "Chrome Passwords.csv",
                after: after
            )
        case .brave:
            return ImportGuide(
                export: Steps(
                    title: "Export your passwords from Brave",
                    steps: [
                        "In Brave, open the **☰** menu and choose **Passwords and autofill > Password Manager**.",
                        "Click **Settings** in the sidebar.",
                        "Beside **Export passwords**, click **Download file**.",
                        loginPassword,
                        "Save **Brave Passwords.csv**, for example to the Desktop."
                    ],
                    address: "brave://password-manager/settings",
                    opens: "Brave"
                ),
                files: "Brave Passwords.csv",
                after: after
            )
        case .edge:
            return ImportGuide(
                export: Steps(
                    title: "Export your passwords from Edge",
                    steps: [
                        "In Edge, open **Settings** and choose **Passwords and autofill**, then **Microsoft Password Manager**.",
                        "Click the **⋯** button beside **Saved passwords** and choose **Export passwords**.",
                        "Confirm with **Export passwords**. " + loginPassword,
                        "Save **Microsoft Edge Passwords.csv**, for example to the Desktop."
                    ],
                    opens: "Edge"
                ),
                files: "Microsoft Edge Passwords.csv",
                after: after
            )
        case .firefox:
            return ImportGuide(
                export: Steps(
                    title: "Export your passwords from Firefox",
                    steps: [
                        "In Firefox, open the **☰** menu and choose **Passwords**.",
                        "Click the **⋯** button at the top right and choose **Export Passwords…**.",
                        "Confirm the export. " + loginPassword,
                        "Save **passwords.csv**, for example to the Desktop."
                    ],
                    address: "about:logins",
                    opens: "Firefox"
                ),
                files: "passwords.csv",
                after: after
            )
        case .applePasswords:
            let export: Steps
            if macOS >= 15 {
                export = Steps(
                    title: "Export your passwords from the Passwords app",
                    steps: [
                        "Open the **Passwords** app and unlock it.",
                        "Choose **File > Export All Passwords to File…**.",
                        "Click **Export Passwords…** and save **Passwords.csv**, for example to the Desktop."
                    ],
                    opens: "Passwords"
                )
            } else {
                export = Steps(
                    title: "Export your passwords from System Settings",
                    steps: [
                        "Open **System Settings > Passwords** and unlock it.",
                        "Click the **⋯** button above the list and choose **Export All Passwords…**.",
                        "Click **Export Passwords…** and save **Passwords.csv**, for example to the Desktop."
                    ]
                )
            }
            return ImportGuide(
                intro: tile.id == "safari" ? "Safari keeps its passwords in Apple’s Passwords app." : nil,
                withoutFile: exchange ? Steps(
                    title: "Send them straight from Passwords",
                    steps: [
                        "Open the **Passwords** app and unlock it.",
                        "Choose **File > Export All Items to App…**.",
                        "Pick **PasswordPie**. No file is saved."
                    ],
                    opens: "Passwords"
                ) : nil,
                export: export,
                files: "Passwords.csv, or the ZIP from Safari’s File > Export Browsing Data to File…",
                after: after
            )
        case .onePassword:
            return ImportGuide(
                export: Steps(
                    title: "Export your items from 1Password",
                    steps: [
                        "Open **1Password** and unlock it.",
                        "Choose **File > Export** and pick your account.",
                        "Enter your account password, choose **1PUX** as the format, and click **Export Data**.",
                        "Save the **.1pux** file, for example to the Desktop."
                    ],
                    opens: "1Password"
                ),
                files: "A .1pux file, or an .opvault folder from 1Password 7",
                after: after
            )
        case .bitwarden:
            return ImportGuide(
                export: Steps(
                    title: "Export your vault from Bitwarden",
                    steps: [
                        "In the **Bitwarden** app, choose **File > Export vault**. In the web vault, it is **Tools > Export vault**.",
                        "Set **File format** to **.json**. To protect the file, choose **.json (Encrypted)** with **Password protected** and set a password: PasswordPie will ask for it.",
                        "Enter your master password and save the file, for example to the Desktop."
                    ],
                    opens: "Bitwarden"
                ),
                files: "A Bitwarden .json export",
                after: after
            )
        case .protonPass:
            return ImportGuide(
                export: Steps(
                    title: "Export your vaults from Proton Pass",
                    steps: [
                        "Open **Proton Pass** in its browser extension or at pass.proton.me, and open **Settings > Export**.",
                        "Choose the **ZIP** format, not the one encrypted with PGP, and click **Export**.",
                        "Enter your Proton password if it asks, and save the ZIP. There is no need to unzip it."
                    ]
                ),
                files: "The Proton Pass ZIP, or the data.json in it",
                after: after
            )
        case .lastPass:
            return ImportGuide(
                export: Steps(
                    title: "Export your vault from LastPass",
                    steps: [
                        "Click the **LastPass** button in your browser’s toolbar and choose **Account**.",
                        "Choose **Fix a problem yourself > Export vault items > Export data for use anywhere**.",
                        "Enter your master password. The browser saves **lastpass_vault_export.csv** to Downloads."
                    ]
                ),
                files: "lastpass_vault_export.csv",
                after: after
            )
        case .dashlane:
            return ImportGuide(
                export: Steps(
                    title: "Export your logins from Dashlane",
                    steps: [
                        "Open **Dashlane** at app.dashlane.com or in its browser extension, then open the menu at the top left and choose **Settings**.",
                        "Choose **Export data**, then **Export to CSV**.",
                        "Save the ZIP. There is no need to unzip it."
                    ]
                ),
                files: "The Dashlane ZIP, or the credentials.csv in it",
                after: after
            )
        case .csv:
            return ImportGuide(
                export: Steps(
                    title: "Export a CSV file from the other app",
                    steps: [
                        "In the other app, look for **Export** and choose **CSV**.",
                        "Check that the first row names the columns. PasswordPie reads **title**, **url**, **username**, **password**, **notes** and **otp**, and also folder, tags and favorite.",
                        "Save the file, for example to the Desktop."
                    ]
                ),
                files: "A .csv file",
                after: after
            )
        }
    }
}
