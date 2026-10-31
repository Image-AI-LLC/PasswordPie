import AppKit
import SwiftUI

/// Animation state of the doors: the pie scales up, then the doors part.
@MainActor
final class LockModel: ObservableObject {
    @Published var turned = false
    @Published var open = false
    let fields = LockFields()
}

/// Native password fields behind the lock screen, so the panel can make one the first responder itself.
@MainActor
final class LockFields {
    private(set) var primary: NSSecureTextField?
    private(set) var confirm: NSSecureTextField?

    func register(_ field: NSSecureTextField, isConfirm: Bool) {
        if isConfirm { confirm = field } else { primary = field }
    }

    func unregister(_ field: NSSecureTextField) {
        if primary === field { primary = nil }
        if confirm === field { confirm = nil }
    }
}

/// The vault door: two grey halves that part at the seam when the database unlocks.
struct DoorsView: View {
    @ObservedObject var session: VaultSession
    @ObservedObject var lock: LockModel

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            ZStack(alignment: .topLeading) {
                BottomDoor(session: session, fields: lock.fields, height: height - Metrics.doorHeight)
                    .frame(width: Metrics.width, height: height - Metrics.doorHeight)
                    .offset(y: Metrics.doorHeight + (lock.open ? height : 0))
                TopDoor(open: lock.open)
                    .frame(width: Metrics.width, height: Metrics.doorHeight)
                    .offset(y: lock.open ? -Metrics.doorHeight - 20 : 0)
                PasswordPieMark(size: 96, turn: lock.turned ? 1 : 0)
                    .scaleEffect(lock.open ? 1.25 : 1)
                    .opacity(lock.open ? 0 : 1)
                    .position(x: Metrics.width / 2, y: Metrics.doorHeight)
            }
        }
        .animation(.easeIn(duration: 0.3), value: lock.open)
    }
}

private struct TopDoor: View {
    var open: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            Palette.door
            VStack(spacing: 0) {
                Rectangle().fill(Color(hex: 0xEFEFEF)).frame(height: 0.5)
                Rectangle().fill(Color(hex: 0x737373)).frame(height: 1)
                Rectangle().fill(Palette.band).frame(height: 18)
                Rectangle().fill(Palette.bandHighlight).frame(height: 1)
                Rectangle().fill(Palette.bandLine).frame(height: 0.5)
            }
            .frame(height: 21)
        }
        .shadow(color: .black.opacity(open ? 0.35 : 0), radius: 6, y: 1)
    }
}

private struct BottomDoor: View {
    @ObservedObject var session: VaultSession
    var fields: LockFields
    var height: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            Palette.door
            VStack(spacing: 0) {
                Rectangle().fill(Palette.bandLine).frame(height: 0.5)
                Rectangle().fill(Palette.bandHighlight).frame(height: 1)
                Rectangle().fill(Palette.band).frame(height: 18.5)
                Rectangle().fill(Color(hex: 0xEFEFEF)).frame(height: 1)
                Spacer(minLength: 0)
            }
            VStack(spacing: 0) {
                Text(session.databaseURL.lastPathComponent)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x555555))
                    .shadow(color: .white.opacity(0.7), radius: 0, y: 1)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 20)
                    .padding(.top, 58)
                Text(session.creating ? "Choose a Master Password for the new database." : "Enter Master Password to unlock.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: 0x6F6F6F))
                    .shadow(color: .white.opacity(0.7), radius: 0, y: 1)
                    .padding(.top, 4)
                form.padding(.top, 12)
                Text(session.message.isEmpty ? " " : session.message)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.danger)
                    .shadow(color: .white.opacity(0.6), radius: 0, y: 1)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                Spacer(minLength: 0)
                HStack(spacing: 14) {
                    Button("Open Database…") { session.chooseDatabase() }
                    if session.showsKeyFile {
                        Button(session.keyFileName.isEmpty ? "Key File…" : session.keyFileName) { session.chooseKeyFile() }
                            .lineLimit(1)
                    }
                    Button("New Database…") { session.newDatabase() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(Color(hex: 0x6F6F6F))
                .padding(.bottom, 12)
            }
        }
    }

    private var form: some View {
        VStack(spacing: 8) {
            if session.creating {
                row(PasswordField(placeholder: "Master Password", text: $session.passwordDraft, fields: fields, isConfirm: false) {
                    fields.confirm?.window?.makeFirstResponder(fields.confirm)
                }, unlock: false)
                row(PasswordField(placeholder: "Repeat Password", text: $session.confirmDraft, fields: fields, isConfirm: true) {
                    session.unlock()
                }, unlock: true)
            } else {
                row(PasswordField(placeholder: "Master Password", text: $session.passwordDraft, fields: fields, isConfirm: false) {
                    session.unlock()
                }, unlock: true)
            }
        }
    }

    private func row(_ field: some View, unlock: Bool) -> some View {
        let touch = unlock && session.touchIDAvailable && !session.creating
        return HStack(spacing: 0) {
            if touch {
                DoorButton(width: 38, action: session.unlockWithTouchID) {
                    Image(systemName: "touchid").font(.system(size: 19, weight: .light))
                }
                Rectangle().fill(Color(hex: 0x3A3A3A)).frame(width: 1)
            }
            field
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(
                    ZStack(alignment: .top) {
                        Color.white
                        LinearGradient(colors: [Color.black.opacity(0.22), .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: 6)
                    }
                )
            if unlock {
                Rectangle().fill(Color(hex: 0x3A3A3A)).frame(width: 1)
                DoorButton(width: 40, action: session.unlock) {
                    Image(systemName: "lock.open.fill").font(.system(size: 16))
                }
            }
        }
        .frame(width: 260, height: 42)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(hex: 0x2B2B2B), lineWidth: 1))
        .shadow(color: .white.opacity(0.9), radius: 0, y: 1)
    }
}

private struct DoorButton<Label: View>: View {
    var width: CGFloat
    var action: () -> Void
    @ViewBuilder var label: Label
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            label
                .foregroundStyle(Color(hex: 0x8C8C8C))
                .frame(width: width, height: 42)
                .background(
                    LinearGradient(
                        colors: pressed ? [Color(hex: 0xD2D2D2), Color(hex: 0xE6E6E6)] : [Color(hex: 0xFCFCFC), Color(hex: 0xE2E2E2)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .buttonStyle(.plain)
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in pressed = true }.onEnded { _ in pressed = false })
    }
}

/// A native secure field. Typing clears a pending error, Return submits, and the panel focuses it directly.
struct PasswordField: NSViewRepresentable {
    var placeholder: String
    @Binding var text: String
    var fields: LockFields
    var isConfirm: Bool
    var submit: () -> Void

    func makeNSView(context: Context) -> NSSecureTextField {
        let field = NSSecureTextField()
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14)
        field.delegate = context.coordinator
        field.cell?.usesSingleLineMode = true
        fields.register(field, isConfirm: isConfirm)
        return field
    }

    func updateNSView(_ field: NSSecureTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    static func dismantleNSView(_ field: NSSecureTextField, coordinator: Coordinator) {
        coordinator.parent.fields.unregister(field)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PasswordField

        init(_ parent: PasswordField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSecureTextField else { return }
            parent.text = field.stringValue
            AppDelegate.shared?.passwordTyped()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            parent.submit()
            return true
        }
    }
}
