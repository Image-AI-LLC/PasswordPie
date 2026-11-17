import AppKit
import PasswordPieCore
import SwiftUI
#if PP_DIRECT
import PasswordPieUpdate
#endif

/// One pane of Preferences (docs/UX.md, "Preferences in panes").
enum PreferencesPane: String, CaseIterable, Identifiable {
    case general
    case security
    case database
    case browsers
    case importPasswords
    case premium

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .security: return "Security"
        case .database: return "Database"
        case .browsers: return "Browsers"
        case .importPasswords: return "Import"
        case .premium: return "Premium"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "The shortcut that opens PasswordPie, and everyday habits."
        case .security: return "When PasswordPie locks, and how it unlocks."
        case .database: return "The file your passwords are in, and its keys."
        case .browsers: return "Filling sign-in forms in your browser."
        case .importPasswords: return "Bring your passwords from a browser or another password manager."
        case .premium: return "Two-step codes."
        }
    }

    /// A single-layer outline: it sits on a tile.
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .security: return "lock"
        case .database: return "cylinder.split.1x2"
        case .browsers: return "globe"
        case .importPasswords: return "square.and.arrow.down"
        case .premium: return "star"
        }
    }
}

/// A place other parts of the app open Preferences at.
enum PreferencesSection: Hashable {
    case importPasswords
    case browserExtensions
    #if PP_DIRECT
    case chrome
    #endif

    var pane: PreferencesPane {
        switch self {
        case .importPasswords: return .importPasswords
        case .browserExtensions: return .browsers
        #if PP_DIRECT
        case .chrome: return .browsers
        #endif
        }
    }
}

/// Which pane Preferences shows.
@MainActor
final class PreferencesNavigator: ObservableObject {
    @Published var pane: PreferencesPane = .general

    /// A window that just opened starts on General, unless it was opened at a place. An open window keeps its pane
    /// unless it is sent somewhere.
    func open(at section: PreferencesSection?, newWindow: Bool) {
        if let section {
            pane = section.pane
        } else if newWindow {
            pane = .general
        }
    }
}

/// A pane's title and the line under it.
struct PaneHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 16, weight: .semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The small capitals over a card.
struct PaneGroupLabel: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(.secondary)
            .padding(.leading, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

struct PreferencesView: View {
    @ObservedObject var session: VaultSession
    @ObservedObject var navigator: PreferencesNavigator
    /// Preferences > Import. Nil leaves the pane out.
    var importFlow: ImportFlow?
    /// The browser extensions' state, for "Browsers". Nil leaves the extensions out.
    var bridge: BrowserBridge?
    #if PP_DIRECT
    /// The downloaded app's updater, for "Updates". Nil leaves the card out.
    var updates: UpdateCoordinator?
    #endif
    @StateObject private var recorder = ShortcutRecorder()
    @Environment(\.colorScheme) private var colorScheme

    static let sidebarWidth: CGFloat = 188

    private var cardColor: Color { Palette.card(dark: colorScheme == .dark) }

    /// The panes this build and this window have something in.
    var panes: [PreferencesPane] {
        PreferencesPane.allCases.filter { pane in
            switch pane {
            case .browsers:
                #if PP_DIRECT
                return true
                #else
                return bridge != nil
                #endif
            case .importPasswords: return importFlow != nil
            default: return true
            }
        }
    }

    private var shown: PreferencesPane { panes.contains(navigator.pane) ? navigator.pane : .general }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    pane(shown)
                }
                .padding(.horizontal, 24)
                .padding(.top, 14)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // A new pane starts at its top.
            .id(shown)
        }
        .font(.system(size: 13))
        .background(Palette.windowSurface(dark: colorScheme == .dark).ignoresSafeArea())
        .tint(Palette.brandAccent)
        .frame(minWidth: 700, idealWidth: 760, maxWidth: .infinity,
               minHeight: 460, idealHeight: 650, maxHeight: .infinity)
        .onChange(of: navigator.pane) { _, _ in recorder.stop() }
        .onDisappear { recorder.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in recorder.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in recorder.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in recorder.stop() }
    }

    // MARK: The list of panes

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(panes.filter { $0 != .premium }) { pane in
                PaneRow(pane: pane, selected: pane == shown) { navigator.pane = pane }
            }
            Spacer(minLength: 8)
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1).padding(.horizontal, 4).padding(.bottom, 6)
            PaneRow(pane: .premium, selected: shown == .premium) { navigator.pane = .premium }
        }
        .padding(.horizontal, 8)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(width: Self.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.primary.opacity(0.04).ignoresSafeArea())
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1).ignoresSafeArea()
        }
    }

    // MARK: Panes

    @ViewBuilder
    private func pane(_ pane: PreferencesPane) -> some View {
        if pane != .importPasswords {
            PaneHeader(title: pane.title, subtitle: pane.subtitle)
        }
        switch pane {
        case .general:
            section("Quick access") { shortcut }
            section("Everyday") { everyday }
            #if PP_DIRECT
            if let updates {
                section("Updates") { UpdatesSection(updates: updates) }
            }
            #endif
        case .security:
            section("Lock automatically") { security }
            section("Touch ID") { touchID }
        case .database:
            section("Database") { database }
            section("Key file") { keyFile }
            section("Master password") { masterPassword }
        case .browsers:
            if let bridge {
                section("Extensions") { BrowserExtensionsSection(bridge: bridge) }
            }
            #if PP_DIRECT
            section("Chrome passwords") { chromeSync }
            #endif
        case .importPasswords:
            if let importFlow {
                ImportPane(flow: importFlow, session: session)
            }
        case .premium:
            section("Premium") { PremiumPreferencesSection(store: session.premium) }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            PaneGroupLabel(title)
            content()
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(cardColor, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
        }
    }

    private var shortcut: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Keyboard shortcut").fontWeight(.medium)
                Spacer()
                Text("Open PasswordPie from any app")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                Button {
                    if recorder.isRecording { recorder.stop() } else {
                        recorder.start(in: NSApp.keyWindow, suspend: {
                            session.recordingHotKey = true
                            AppDelegate.shared?.unregisterHotkey()
                        }, commit: { session.hotKey = $0 }, finish: {
                            session.recordingHotKey = false
                            AppDelegate.shared?.reregisterHotkey()
                        })
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "keyboard").foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if recorder.isRecording {
                            Text("Press a shortcut…").font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.accentText(dark: colorScheme == .dark))
                        } else {
                            HStack(spacing: 5) {
                                ForEach(Array(session.hotKey.keycaps.enumerated()), id: \.offset) { _, key in
                                    Text(key)
                                        .font(.system(size: 17, weight: .medium))
                                        .frame(minWidth: 24, minHeight: 28)
                                        .padding(.horizontal, 5)
                                        .background(cardColor, in: RoundedRectangle(cornerRadius: 5))
                                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.12)))
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 14)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(recorder.isRecording ? "Cancel shortcut recording" : "Record keyboard shortcut")
                .accessibilityValue(session.hotKey.display)
                .help("Click, then press a shortcut with Command, Option or Control. Esc cancels.")

                Button {
                    if recorder.isRecording { recorder.stop() } else { session.hotKey = .default }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, height: 54)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!recorder.isRecording && session.hotKey == .default)
                .help(Text(verbatim: recorder.isRecording ? "Cancel recording" : "Restore default shortcut (⌘\\)"))
                .accessibilityLabel(recorder.isRecording ? "Cancel recording" : "Restore default shortcut")
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
                recorder.isRecording ? Palette.focus(dark: colorScheme == .dark) : Color.primary.opacity(0.16),
                lineWidth: recorder.isRecording ? 2 : 1))

            Text(shortcutHint)
                .font(.system(size: 11))
                .foregroundStyle(!recorder.isRecording && !session.hotKeyActive ? Palette.error(dark: colorScheme == .dark) : .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("shortcut-hint")
        }
    }

    private var shortcutHint: String {
        if recorder.needsModifier { return "Include Command (⌘), Option (⌥) or Control (⌃). Esc cancels." }
        if recorder.isRecording { return "Use ⌘, ⌥ or ⌃ with a key. Press Esc to cancel." }
        if !session.hotKeyActive { return "Shortcut unavailable. It may be in use by another app; choose a different one." }
        return "Click to record a shortcut. × restores the default ⌘\\."
    }

    private var idleSelection: Binding<Int> {
        Binding(get: { session.autoLock.lockOnIdle ? session.autoLock.timeoutMinutes : 0 }, set: { value in
            recorder.stop()
            var settings = session.autoLock
            settings.lockOnIdle = value != 0
            if value != 0 { settings.timeoutMinutes = value }
            session.autoLock = settings
        })
    }

    private var security: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Lock after inactivity")
                Spacer()
                Picker("Lock after inactivity", selection: idleSelection) {
                    ForEach(PreferenceDurations.idleOptions(including: session.autoLock.timeoutMinutes), id: \.self) { minutes in
                        Text(PreferenceDurations.minutesLabel(minutes)).tag(minutes)
                    }
                    Divider()
                    Text("Never").tag(0)
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 150)
            }
            Divider()
            settingToggle("When the Mac sleeps", value: $session.autoLock.lockOnSleep)
            settingToggle("When the screen locks or the screen saver starts", value: $session.autoLock.lockOnScreenSaver)
            settingToggle("When switching users", value: $session.autoLock.lockOnUserSwitch)
            Text("“Never” only turns off idle locking. The switches above still apply.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var everyday: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Clear clipboard after")
                Spacer()
                Picker("Clear clipboard after", selection: $session.clipboardTimeout) {
                    ForEach(PreferenceDurations.clipboardOptions(including: session.clipboardTimeout), id: \.self) { seconds in
                        Text(PreferenceDurations.secondsLabel(seconds)).tag(seconds)
                    }
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 150)
                .onChange(of: session.clipboardTimeout) { _, _ in recorder.stop() }
            }
            Divider()
            settingToggle("Search all fields", detail: "Also search usernames, notes, tags and custom fields.", value: $session.searchAll)
        }
    }

    private func settingToggle(_ title: String, detail: String? = nil, value: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: value)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(title)
                .accessibilityHint(detail ?? "")
        }
        .onChange(of: value.wrappedValue) { _, _ in recorder.stop() }
    }

    private var database: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive")
                    .font(.system(size: 25)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.databaseURL.lastPathComponent).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    Text(session.databaseURL.deletingLastPathComponent().path)
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                .help(session.databaseURL.path)
                Spacer(minLength: 4)
                Button("Open…") { recorder.stop(); session.chooseDatabase() }
                Button("New…") { recorder.stop(); session.newDatabase() }
            }
            if session.databasePaths.count > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(session.databasePaths.enumerated()), id: \.element) { index, path in
                        HStack(spacing: 8) {
                            Text(session.databaseMenuTitles[index])
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            if path == session.databaseURL.path {
                                Text("Current").font(.system(size: 11)).foregroundStyle(.secondary)
                            } else {
                                Button("Switch") { recorder.stop(); session.selectDatabase(path) }
                            }
                            Button("Remove") { recorder.stop(); session.forgetDatabase(path) }
                                .help("Remove from the list. The file stays on disk.")
                        }
                    }
                }
            }
        }
        .controlSize(.regular)
    }

    /// Touch ID for the open database.
    private var touchID: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Unlock “\(session.databaseURL.lastPathComponent)” with Touch ID").fontWeight(.medium)
                        .lineLimit(1).truncationMode(.middle)
                    Text(touchIDDescription)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !session.touchIDStatus.isEmpty {
                        Text(session.touchIDStatus)
                            .font(.system(size: 11))
                            .foregroundStyle(session.touchIDStatusIsError ? Palette.error(dark: colorScheme == .dark) : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                if session.touchIDEnabled {
                    Label("On", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.top, 4)
                    Button(session.touchIDBusy ? "Waiting…" : "Turn Off") {
                        recorder.stop()
                        session.disableTouchID(declined: true)
                    }
                    .disabled(session.touchIDBusy)
                } else if session.touchIDHardware {
                    Button(session.touchIDBusy ? "Waiting…" : "Enable…") {
                        recorder.stop()
                        session.enableTouchID()
                    }
                    .disabled(session.locked || session.touchIDBusy)
                    .help(session.locked ? "Unlock this database with its master password first." : "Save the current master password for Touch ID")
                }
            }
        }
        .controlSize(.regular)
    }

    /// Key file actions for the open database. See "A key file that stays on this Mac" in docs/UX.md.
    private var keyFile: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.databaseUsesKeyFile && !session.locked ? "This database has a key file" : "A second key").fontWeight(.medium)
                    Text(keyFileDescription)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if session.databaseUsesKeyFile && !session.locked {
                    Label("On", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
            HStack(spacing: 8) {
                Button("Add Key File…") { recorder.stop(); session.addKeyFile() }
                    .help("Make a new key file and lock the database with it and the master password")
                Button("Use Existing Key File…") { recorder.stop(); session.useExistingKeyFile() }
                    .help("Lock the database with a file you already have and the master password")
                Spacer(minLength: 0)
            }
            .disabled(!session.canChangeKeys)
            if (session.databaseUsesKeyFile && !session.locked) || session.keyFileRemembered {
                HStack(spacing: 8) {
                    if session.databaseUsesKeyFile && !session.locked {
                        Button("Remove Key File…") { recorder.stop(); session.removeKeyFile() }
                            .help("Go back to the master password alone")
                            .disabled(!session.canChangeKeys)
                    }
                    Spacer(minLength: 0)
                    if session.keyFileRemembered {
                        Button("Forget Key File") { recorder.stop(); session.forgetKeyFile() }
                            .help("This Mac stops keeping the key file. The database still needs it.")
                    }
                }
            }
            if !session.keyFileStatus.isEmpty {
                Text(session.keyFileStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(session.keyFileStatusIsError ? Palette.error(dark: colorScheme == .dark) : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("keyfile-status")
            }
        }
        .controlSize(.regular)
    }

    private var keyFileDescription: String {
        if !VaultFormat.writesKDBX(session.databaseURL) {
            return "Only a KeePass .kdbx database can have a key file."
        }
        if session.locked {
            return "Unlock the database to add, change or remove its key file."
        }
        guard session.databaseUsesKeyFile else {
            return "A second key that stays on this Mac. A copy of the database that leaks from a cloud folder cannot be opened with the master password alone."
        }
        let name = session.keyFileName.isEmpty ? "its key file" : session.keyFileName
        if session.keyFileRemembered {
            return "This database needs \(name) and the master password. This Mac keeps the key file in its keychain, so unlocking needs only the password or Touch ID."
        }
        return "This database needs \(name) and the master password. This Mac does not keep the key file: the lock screen asks for it."
    }

    private var masterPassword: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("The password that unlocks this database").fontWeight(.medium)
                Text(session.databaseUsesKeyFile && !session.locked
                     ? "Changing it keeps the key file."
                     : "Changes the password for this database.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button("Change Master Password…") { recorder.stop(); session.changeMasterPassword() }
                .disabled(!session.canChangeKeys)
                .help(session.locked ? "Unlock this database first." : "Change the master password")
        }
        .controlSize(.regular)
    }

    #if PP_DIRECT
    private var chromeReplacesCopy: String { "Newer Chrome passwords replace saved ones. Chrome isn't changed." }

    private var chromeSync: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sync Chrome passwords").fontWeight(.medium)
                    Text("Reads the passwords saved in Chrome on this Mac and searches them with your own. Opening PasswordPie checks those files again, and reads them only when they have changed. PasswordPie never changes Chrome. macOS asks once for the Chrome Safe Storage key: choose Always Allow. Reading the files also needs Google Chrome turned on for PasswordPie under Privacy & Security → Files & Folders.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(chromeReplacesCopy)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("Sync Chrome passwords", isOn: Binding(
                    get: { session.chromeSyncEnabled },
                    set: { recorder.stop(); session.setChromeSync($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(session.locked)
                .accessibilityLabel("Sync Chrome passwords")
                .help(session.locked ? "Unlock this database first." : "Read passwords saved in Chrome")
            }
            if session.chromeSyncEnabled {
                HStack(spacing: 10) {
                    if !session.chromeStatus.isEmpty {
                        Text(session.chromeStatus)
                            .font(.system(size: 11))
                            .foregroundStyle(session.chromeStatusIsError ? Palette.error(dark: colorScheme == .dark) : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    if session.chromeNeedsSettings {
                        Button("Open Files & Folders") {
                            recorder.stop()
                            session.openChromeFileAccessSettings()
                        }
                    }
                    Button(session.chromeBusy ? "Reading…" : "Refresh") {
                        recorder.stop()
                        session.refreshChrome()
                    }
                    .disabled(session.locked || session.chromeBusy)
                }
            }
        }
        .controlSize(.regular)
    }
    #endif

    private var touchIDDescription: String {
        if session.touchIDEnabled && !session.touchIDHardware {
            return "On for this database, but Touch ID is not available on this Mac."
        }
        if !session.touchIDHardware { return "Touch ID is not available on this Mac." }
        if session.touchIDEnabled { return "On for this database. It works for 7 days after a master-password unlock." }
        if session.locked { return "Unlock with this file's password. PasswordPie then saves it for Touch ID for 7 days." }
        return "Available for 7 days after you unlock with this file's password."
    }
}

/// One row of the pane list: the selected one is drawn like the selected row of the menu.
private struct PaneRow: View {
    let pane: PreferencesPane
    let selected: Bool
    let action: () -> Void

    @State private var hovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: pane.symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? Palette.selectionInk : Palette.accentText(dark: colorScheme == .dark))
                    .frame(width: 20, height: 20)
                    .background(
                        selected ? Palette.selectionInk.opacity(0.14) : Palette.brandAccent.opacity(0.2),
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                Text(pane.title)
                    .fontWeight(selected ? .medium : .regular)
                    .foregroundStyle(selected ? Palette.selectionInk : Palette.text(dark: colorScheme == .dark))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 30)
            .background(
                selected ? Palette.selectionFill : Color.primary.opacity(hovered ? 0.06 : 0),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(pane.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("pane-\(pane.rawValue)")
    }
}

/// The gear menu's and the menu bar icon's way to "Browsers" in Preferences.
let browserExtensionsMenuTitle = "Browser Extensions…"
/// The gear menu's way to "Import". The empty database's row has the same words.
let importPasswordsMenuTitle = "Import Passwords…"

/// Where each browser's extension stands, and the way to add it or turn it on. Always here, whatever app is in front:
/// the line above the search box shows only over a browser that is missing it (docs/UX.md, "Getting the extension").
struct BrowserExtensionsSection: View {
    @ObservedObject var bridge: BrowserBridge

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if BrowserBridge.chromeSupported {
                row(
                    browser: "Chrome",
                    bundleID: BrowserBridge.chromeBundleID,
                    detail: "Fills sign-in forms in Chrome, and lists the accounts for the site you are on first. Chrome keeps extensions per profile: to add it to another profile, bring that profile's window to the front in Chrome, then add it here.",
                    status: .chrome(profiles: bridge.chromeProfiles),
                    button: ExtensionBanner.addChrome.title
                ) { bridge.install(.addChrome) }
                Divider()
            }
            row(
                browser: "Safari",
                bundleID: BrowserBridge.safariBundleID,
                detail: "The same in Safari. Turn it on in Safari's Extensions settings.",
                status: .safari(enabled: bridge.safariEnabled),
                button: safariExtensionButtonTitle(enabled: bridge.safariEnabled)
            ) { bridge.install(.enableSafari) }
        }
        .controlSize(.regular)
        .onAppear { bridge.refreshSafariState() }
        // Coming back from Safari's settings: the switch there may have changed.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in bridge.refreshSafariState() }
    }

    private func row(browser: String, bundleID: String, detail: String, status: ExtensionStatus, button: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                    .resizable()
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(browser).fontWeight(.medium)
                    if status.on {
                        Label(status.text, systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(status.text)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                Text(detail)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The text takes the width the button leaves, instead of sharing it with the spacer.
            .layoutPriority(1)
            Spacer(minLength: 8)
            Button(button, action: action)
                .fixedSize()
        }
    }
}

#if PP_DIRECT
/// "Updates" in Preferences, downloaded app only. See "Updates that install themselves" in docs/UX.md.
struct UpdatesSection: View {
    @ObservedObject var updates: UpdateCoordinator
    @Environment(\.colorScheme) private var colorScheme

    static let detail = "Once a week, a separate updater asks GitHub for a newer PasswordPie, checks that it is signed by Image AI, LLC and notarized by Apple, and installs it while PasswordPie is locked. PasswordPie itself never connects to the network."

    private var failed: Bool {
        if case .failed = updates.state { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Update automatically").fontWeight(.medium)
                    Text(Self.detail)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("Update automatically", isOn: $updates.automatic)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(updates.state == .unavailable)
                    .accessibilityLabel("Update automatically")
                    .accessibilityHint(Self.detail)
            }
            HStack(spacing: 10) {
                Text(updates.statusLine)
                    .font(.system(size: 11))
                    .foregroundStyle(failed ? Palette.error(dark: colorScheme == .dark) : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                switch updates.state {
                case .ready:
                    Button("Restart to Update") { updates.restartToUpdate() }
                case .available:
                    Button("Download…") { NSWorkspace.shared.open(ReleaseFeed.releasesPage) }
                default:
                    EmptyView()
                }
                if updates.state != .unavailable {
                    Button(updates.state == .checking ? "Checking…" : "Check Now") { updates.checkNow() }
                        .disabled(updates.state == .checking)
                }
            }
        }
        .controlSize(.regular)
    }
}
#endif
