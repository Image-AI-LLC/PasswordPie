#if !PP_DIRECT
import AppKit
import PasswordPieCore
import SwiftUI

/// The small window a locked two-step code opens. It closes by itself when Premium arrives.
struct PaywallView: View {
    @ObservedObject var store: PremiumStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                PasswordPieMark(size: 40)
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("PasswordPie Premium").font(.system(size: 16, weight: .semibold))
                    Text("Two-step codes, right beside your passwords. Everything else stays free.")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.secondaryText(dark: colorScheme == .dark))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            PremiumPlansView(store: store, style: .cards)
            PremiumActionsView(store: store)
            PremiumDisclosureView(store: store)
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
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let summary = store.status.summary { $0.formatted(date: .long, time: .omitted) }
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.title).fontWeight(.medium)
                Text(summary.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Lifetime is the end of the road. Below it there is still something to buy.
            if !store.ownedPlans.contains(.lifetime) {
                Divider()
                PremiumPlansView(store: store, style: .rows)
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
        .controlSize(.regular)
        .task { await store.loadProductsIfNeeded() }
    }
}

/// The plans from the store, or why there are none. Every name and price here comes from Apple.
private struct PremiumPlansView: View {
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

/// How a purchase or restore ended. Orange is never a status: red for failure, secondary for everything else.
private struct PremiumMessageView: View {
    var message: String
    var isError: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(message)
            .font(.system(size: 11))
            .foregroundStyle(isError ? Palette.error(dark: colorScheme == .dark) : Palette.secondaryText(dark: colorScheme == .dark))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
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
