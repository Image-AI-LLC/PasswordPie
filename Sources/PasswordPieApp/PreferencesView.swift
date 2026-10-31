import AppKit
import PasswordPieCore
import SwiftUI

struct PreferencesView: View {
    @ObservedObject var session: VaultSession
    @StateObject private var recorder = ShortcutRecorder()
    @Environment(\.colorScheme) private var colorScheme

    private var cardColor: Color {
        colorScheme == .dark ? Color(nsColor: .controlBackgroundColor) : .white
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    section("Quick access") { shortcut }
                    section("Security") { security }
                    section("Everyday") { everyday }
                    section("Database") { database }
                }
                .padding(24)
            }
            Text("Changes are saved automatically.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.bottom, 14)
                .padding(.top, 4)
        }
        .font(.system(size: 13))
        .background(Color(nsColor: .windowBackgroundColor))
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
                            Text("Press a shortcut…").font(.system(size: 14, weight: .medium)).foregroundStyle(Color.accentColor)
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
                recorder.isRecording ? Color.accentColor : Color.primary.opacity(0.16),
                lineWidth: recorder.isRecording ? 2 : 1))

            Text(shortcutHint)
                .font(.system(size: 11))
                .foregroundStyle(!recorder.isRecording && !session.hotKeyActive ? Color(nsColor: .systemRed) : .secondary)
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
            settingToggle("When screen saver starts", value: $session.autoLock.lockOnScreenSaver)
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
                            .foregroundStyle(session.touchIDStatusIsError ? Palette.danger : Color.secondary)
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
