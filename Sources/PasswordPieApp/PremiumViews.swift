#if !PP_DIRECT
import AppKit
import PasswordPieCore
import SwiftUI

// The App Store channel's Premium UI. No account and no sign-in anywhere in it, and no word about buying elsewhere.

/// The small window a locked two-step code opens. It closes by itself when Premium arrives.
struct PaywallView: View {
    @ObservedObject var store: PremiumStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PremiumWindowHeader()
            PremiumStatusView(store: store)
            PremiumOffer(store: store, style: .cards)
        }
        .padding(20)
        .frame(width: 400)
        .background(Palette.windowSurface(dark: colorScheme == .dark))
        .tint(Palette.brandAccent)
        .task { await store.loadProductsIfNeeded() }
        .onAppear { store.clearMessage() }
    }
}

/// The Premium section of Preferences.
struct PremiumPreferencesSection: View {
    @ObservedObject var store: PremiumStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PremiumStatusView(store: store)
            PremiumOffer(store: store, style: .rows)
        }
        .controlSize(.regular)
        .task { await store.loadProductsIfNeeded() }
    }
}

/// What this Mac has, and until when.
private struct PremiumStatusView: View {
    @ObservedObject var store: PremiumStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let status = store.statusLine()
        VStack(alignment: .leading, spacing: 3) {
            Text(status.title).fontWeight(.medium)
            if !status.detail.isEmpty {
                small(status.detail)
            }
            if let note = store.subscriptionNote() {
                small(note)
            }
        }
    }

    private func small(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Palette.secondaryText(dark: colorScheme == .dark))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// What can still be bought, and the things App Store rules ask for beside it.
private struct PremiumOffer: View {
    @ObservedObject var store: PremiumStore
    var style: PremiumPlansView.Style

    var body: some View {
        // Lifetime is the end of the road. Below it there is still something to buy.
        if !store.ownedPlans.contains(.lifetime) {
            Divider()
            PremiumPlansView(store: store, style: style)
        } else if let message = store.activity.message {
            PremiumMessageView(message: message, isError: store.activity.isError)
        }
        Divider()
        PremiumActionsView(store: store)
        if !store.ownedPlans.contains(.lifetime) {
            PremiumDisclosureView(store: store)
        } else {
            PremiumLegalLinks()
        }
    }
}

/// The plans from the store, or why there are none. Every name and price here comes from Apple.
struct PremiumPlansView: View {
    enum Style {
        /// Each plan on its own card, for the warm window.
        case cards
        /// Plans divided by hairlines, inside a Preferences card.
        case rows
    }

    @ObservedObject var store: PremiumStore
    var style: Style
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: style == .cards ? 8 : 10) {
            switch store.products {
            case .idle, .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Asking the App Store for the plans…")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.secondaryText(dark: colorScheme == .dark))
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            case .failed:
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("The App Store did not return the plans. Check your connection and try again.")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.error(dark: colorScheme == .dark))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Try Again") { Task { await store.loadProducts() } }
                }
            case .loaded(let products):
                ForEach(Array(products.enumerated()), id: \.element.id) { index, product in
                    if style == .rows, index > 0 { Divider() }
                    planRow(product)
                }
            }
            if let message = store.activity.message {
                PremiumMessageView(message: message, isError: store.activity.isError)
            }
        }
    }

    @ViewBuilder
    private func planRow(_ product: PremiumProduct) -> some View {
        let row = PremiumPlanRow(store: store, product: product)
        switch style {
        case .cards:
            row
                .padding(12)
                .background(Palette.card(dark: colorScheme == .dark), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
        case .rows:
            row
        }
    }
}

private struct PremiumPlanRow: View {
    @ObservedObject var store: PremiumStore
    var product: PremiumProduct
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(product.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(product.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondaryText(dark: colorScheme == .dark))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            action
        }
    }

    @ViewBuilder
    private var action: some View {
        if store.ownedPlans.contains(product.plan) {
            Text("Owned")
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondaryText(dark: colorScheme == .dark))
        } else {
            SplitActionButton(
                title: store.activity == .purchasing(product.plan) ? "Waiting…" : product.buttonTitle,
                size: .regular,
                prominence: product.plan == .lifetime ? .primary : .quiet
            ) {
                Task { await store.purchase(product.plan) }
            }
            .disabled(store.activity.isBusy)
            .opacity(store.activity.isBusy ? 0.5 : 1)
        }
    }
}

/// Restore Purchases and Manage Subscription. Both windows offer them: App Store rule 3.1.1 asks for restore.
private struct PremiumActionsView: View {
    @ObservedObject var store: PremiumStore

    var body: some View {
        HStack(spacing: 8) {
            Button(store.activity == .restoring ? "Restoring…" : "Restore Purchases") {
                Task { await store.restore() }
            }
            .disabled(store.activity.isBusy)
            Button("Manage Subscription") {
                NSWorkspace.shared.open(PremiumLinks.manageSubscriptions)
            }
        }
        .controlSize(.small)
    }
}

/// The terms guideline 3.1.2 asks for, built from what the store said, and the two links.
private struct PremiumDisclosureView: View {
    @ObservedObject var store: PremiumStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if case .loaded(let products) = store.products {
                ForEach(products.compactMap(\.renewalDisclosure), id: \.self) { disclosure in
                    Text(disclosure)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondaryText(dark: colorScheme == .dark))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            PremiumLegalLinks()
        }
    }
}

private struct PremiumLegalLinks: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            link("Terms of Service", PremiumLinks.termsOfService)
            link("Privacy Policy", PremiumLinks.privacyPolicy)
        }
    }

    /// A plain button, because `Link` paints itself in the system accent, and a Mac set to blue would bring blue back.
    private func link(_ title: String, _ url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Text(title)
                .font(.system(size: 11))
                .underline()
                .foregroundStyle(Palette.accentText(dark: colorScheme == .dark))
        }
        .buttonStyle(.plain)
        .help(url.absoluteString)
    }
}
#endif
