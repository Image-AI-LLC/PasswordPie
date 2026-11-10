import AppKit
import PasswordPieCore
import SwiftUI

/// The Add Two-Step Code window: what the browser extension scanned, the item it goes to, and Add. After Add, the code.
/// Nothing is written before Add (docs/UX.md, "Scan a two-step QR code").
struct OTPScanConfirmView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: OTPScanModel
    @ObservedObject var session: VaultSession
    /// Observed so the code row unlocks the moment Premium arrives.
    @ObservedObject var premium: PremiumStore
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.phase {
            case .choosing, .confirmReplace, .failed:
                if let scan = model.scan { choosing(scan) } else { expired }
            case .added(let id):
                added(id)
            case .expired, .idle:
                expired
            }
        }
        .padding(16)
        .frame(width: 380)
        .background(Palette.windowSurface(dark: colorScheme == .dark))
        .alert("Replace the existing code?", isPresented: replaceBinding) {
            Button("Replace", role: .destructive) { model.add() }
            Button("Cancel", role: .cancel) { model.keepChoosing() }
        } message: {
            Text("\(targetTitle) already has a two-step code. The old one stays in the item's history in the database file.")
        }
    }

    private var replaceBinding: Binding<Bool> {
        Binding(get: { model.phase == .confirmReplace }, set: { if !$0, model.phase == .confirmReplace { model.keepChoosing() } })
    }

    private var targetTitle: String {
        guard case .entry(let id)? = model.target else { return "This item" }
        return session.storedEntry(id)?.title ?? "This item"
    }

    // MARK: Choosing

    @ViewBuilder
    private func choosing(_ scan: OTPScanModel.Scan) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "qrcode")
                .font(.system(size: 22))
                .foregroundStyle(Palette.brandAccent)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(scan.otp.issuer.isEmpty ? "Two-step code" : scan.otp.issuer).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if !scan.otp.account.isEmpty {
                    Text(scan.otp.account).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                }
                if let host = scan.origin.flatMap({ BrowserSite(url: $0)?.host }) {
                    Text("Scanned on \(host)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        Text("Add to").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.candidates) { entry in row(entry) }
                TextField("Search other items", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .padding(.vertical, 6)
                ForEach(model.searchResults) { entry in row(entry) }
                targetRow(.newItem, title: "New Item", detail: "\u{201C}\(model.newItemTitle)\u{201D}", systemImage: "plus.circle")
            }
        }
        .frame(height: 220)
        if case .failed(let text) = model.phase {
            Text(text).font(.system(size: 11)).foregroundStyle(Palette.error(dark: colorScheme == .dark)).fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            Spacer()
            Button("Cancel") {
                model.cancel()
                close()
            }
            .keyboardShortcut(.cancelAction)
            Button("Add") { model.add() }
                .buttonStyle(BrandPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(model.target == nil)
        }
    }

    private func row(_ entry: VaultEntry) -> some View {
        let hasCode = OneTimeCodes.hasCode(entry) || !entry.otp.isEmpty
        let detail = [entry.username, hasCode ? "has a code" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
        return targetRow(.entry(entry.id), title: entry.title, detail: detail, systemImage: "key")
    }

    private func targetRow(_ target: OTPScanModel.Target, title: String, detail: String, systemImage: String) -> some View {
        let selected = model.target == target
        return Button {
            model.target = target
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Palette.brandAccent : .secondary)
                    .accessibilityHidden(true)
                Image(systemName: systemImage).frame(width: 16).foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13)).lineLimit(1)
                    if !detail.isEmpty {
                        Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Added

    @ViewBuilder
    private func added(_ id: UUID) -> some View {
        let entry = session.entry(id)
        Text("Added to \(entry?.title ?? "the item")").font(.system(size: 13, weight: .semibold))
        if let entry {
            let access = session.oneTimeCodeAccess(for: entry)
            HStack(spacing: 10) {
                OneTimeCodeView(access: access)
                Spacer()
                if access.isAvailable {
                    Button("Copy") { session.copy(.oneTimePassword, of: id) }
                } else if access == .locked {
                    Button("Upgrade") { session.requestPremium() }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            Text(access.isAvailable
                 ? "Type it on the website to finish turning on two-step sign-in. If the page has a field for it, it fills in."
                 : "The secret is saved. Showing and filling codes needs PasswordPie Premium.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            Spacer()
            Button("Done") {
                model.cancel()
                close()
            }
            .buttonStyle(BrandPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Expired

    @ViewBuilder
    private var expired: some View {
        Text(OTPScanModel.expiredText).font(.system(size: 13))
        HStack {
            Spacer()
            Button("Close") {
                model.cancel()
                close()
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}
