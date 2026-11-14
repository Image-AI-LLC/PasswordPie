import AppKit
import PasswordPieCore
import SwiftUI
#if PP_DIRECT
import PasswordPieUpdate
#endif

/// A section other parts of the app open Preferences at.
enum PreferencesSection: Hashable {
    case importPasswords
    case browserExtensions
    #if PP_DIRECT
    case chrome
    #endif
}

/// Where Preferences should scroll next. Set it, and the open (or opening) window scrolls there once.
@MainActor
final class PreferencesNavigator: ObservableObject {
    @Published var target: PreferencesSection?
}

struct PreferencesView: View {
    @ObservedObject var session: VaultSession
    @ObservedObject var navigator: PreferencesNavigator
    /// The browser extensions' state, for "Browser extensions". Nil leaves the section out.
    var bridge: BrowserBridge?
    #if PP_DIRECT
    /// The downloaded app's updater, for "Updates". Nil leaves the section out.
    var updates: UpdateCoordinator?
    #endif
    @StateObject private var recorder = ShortcutRecorder()
    @Environment(\.colorScheme) private var colorScheme

    private var cardColor: Color { Palette.card(dark: colorScheme == .dark) }

    var body: some View {
        ScrollViewReader { proxy in
            scrollingContent
                .onAppear {
                    // A new window lays out first; scrolling before that lands nowhere.
                    DispatchQueue.main.async { scroll(proxy) }
                }
                .onChange(of: navigator.target) { _, _ in scroll(proxy) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let target = navigator.target else { return }
        withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(target, anchor: .top) }
        navigator.target = nil
    }

    private var scrollingContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                section("Premium") { PremiumPreferencesSection(store: session.premium) }
                section("Quick access") { shortcut }
                section("Security") { security }
                section("Everyday") { everyday }
                section("Database") { database }
                if let bridge {
                    section("Browser extensions") { BrowserExtensionsSection(bridge: bridge) }
                        .id(PreferencesSection.browserExtensions)
                }
                section("Import passwords") { importPasswords }
                    .id(PreferencesSection.importPasswords)
                #if PP_DIRECT
                section("Chrome") { chromeSync }
                    .id(PreferencesSection.chrome)
                if let updates {
                    section("Updates") { UpdatesSection(updates: updates) }
                }
                #endif
            }
            .padding(24)
        }
        .font(.system(size: 13))
        .background(Palette.windowSurface(dark: colorScheme == .dark))
        .tint(Palette.brandAccent)
        .frame(minWidth: 560, idealWidth: 560, maxWidth: .infinity,
               minHeight: 480, idealHeight: 800, maxHeight: .infinity)
        .onDisappear { recorder.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in recorder.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in recorder.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in recorder.stop() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            PasswordPieMark(size: 40)
                .frame(width: 46, height: 48)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Preferences").font(.system(size: 24, weight: .semibold))
                Text("Make PasswordPie feel at home.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 2)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
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
            Divider()
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Touch ID").fontWeight(.medium)
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
            Divider()
            keyFile
            Divider()
            masterPassword
        }
        .controlSize(.regular)
    }

    /// Key file actions for the open database. See "A key file that stays on this Mac" in docs/UX.md.
    private var keyFile: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Key file").fontWeight(.medium)
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
                Text("Master password").fontWeight(.medium)
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
    }

    private var importPasswords: some View {
        VStack(alignment: .leading, spacing: 12) {
            importRow(
                "Chrome",
                steps: "In Chrome, open chrome://password-manager/settings and choose Export passwords. Then pick the file here.",
                source: .chrome
            )
            Divider()
            if VaultSession.credentialExchangeAvailable {
                applePasswordsRow
            } else {
                importRow(
                    "Apple Passwords",
                    steps: "In the Passwords app, choose File > Export All Passwords. Then pick the file here.",
                    source: .applePasswords
                )
            }
            Text("Passwords go into a \"Chrome\" or \"Apple Passwords\" group. Import again to update them: new sites are added, changed passwords are updated, and sites that are gone move to the Recycle Bin. Your own entries are never changed.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !session.importStatus.isEmpty {
                Text(session.importStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(session.importStatusIsError ? Palette.error(dark: colorScheme == .dark) : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

    /// macOS 26+: Passwords sends the items to this app directly, with no file. The file import stays as a fallback.
    private var applePasswordsRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Apple Passwords").fontWeight(.medium)
                Text("In the Passwords app, choose File > Export All Items to App, then pick PasswordPie. No file is saved. Do this again whenever you want to update.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Import from a CSV file instead…") {
                    recorder.stop()
                    session.importPasswords(from: .applePasswords)
                }
                .buttonStyle(.link)
                .foregroundStyle(Palette.accentText(dark: colorScheme == .dark))
                .font(.system(size: 11))
                .disabled(session.locked)
            }
            Spacer(minLength: 4)
            Button("Open Passwords") {
                recorder.stop()
                session.openPasswordsApp()
            }
            .disabled(session.locked)
            .help(session.locked ? "Unlock this database first." : "Open the Passwords app")
        }
    }

    private func importRow(_ title: String, steps: String, source: BrowserImportSource) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.medium)
                Text(steps)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button("Import…") {
                recorder.stop()
                session.importPasswords(from: source)
            }
            .disabled(session.locked)
            .help(session.locked ? "Unlock this database first." : "Choose the exported CSV file")
        }
    }

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

/// The gear menu's and the menu bar icon's way to "Browser extensions" in Preferences.
let browserExtensionsMenuTitle = "Browser Extensions…"

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
