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
            if store.isSignedIn {
                AccountLine(store: store)
                PremiumOffer(store: store, style: .cards)
            } else {
                AccountSignInView(store: store)
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(Palette.windowSurface(dark: colorScheme == .dark))
        .tint(Palette.brandAccent)
        .task { await store.loadProductsIfNeeded() }
        .onAppear { store.clearMessage() }
        .premiumMoveConfirmation(store: store)
    }
}

/// The Account section of Preferences: who is signed in, their Premium, and what can still be done about it.
struct AccountPreferencesSection: View {
    @ObservedObject var store: PremiumStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.isSignedIn {
                AccountLine(store: store)
                PremiumOffer(store: store, style: .rows)
            } else {
                AccountSignInView(store: store)
            }
        }
        .controlSize(.regular)
        .task { await store.loadProductsIfNeeded() }
        .premiumMoveConfirmation(store: store)
    }
}

/// What the signed-in account has, and Sign Out.
private struct AccountLine: View {
    @ObservedObject var store: PremiumStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let summary = store.summary()
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "person.crop.circle")
                    .foregroundStyle(Palette.secondaryText(dark: colorScheme == .dark))
                    .accessibilityHidden(true)
                Text(store.email ?? "Signed in")
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Button("Sign Out") { Task { await store.signOut() } }
                    .controlSize(.small)
                    .disabled(store.activity.isBusy)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.title).fontWeight(.medium)
                if !summary.detail.isEmpty {
                    Text(summary.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondaryText(dark: colorScheme == .dark))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note = store.subscriptionNote() {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondaryText(dark: colorScheme == .dark))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Signing in, Sign in with Apple first (App Store guideline 4.8, and one click when Safari knows the Apple Account).
struct AccountSignInView: View {
    @ObservedObject var store: PremiumStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Premium belongs to your PasswordPie account, so it works on every Mac and in the browser extension. Sign in to use it here.")
                .font(.system(size: 13))
                .foregroundStyle(Palette.secondaryText(dark: colorScheme == .dark))
                .fixedSize(horizontal: false, vertical: true)
            SignInWithAppleStyleButton(waiting: store.signInState == .waiting(.apple)) {
                Task { await store.signIn(with: .apple) }
            }
            .disabled(isWaiting)
            Button(store.signInState == .waiting(nil) ? "Waiting for passwordpie.com…" : "Other Ways to Sign In…") {
                Task { await store.signIn(with: nil) }
            }
            .controlSize(.regular)
            .disabled(isWaiting)
            if let message = store.signInState.message ?? store.activity.message {
                PremiumMessageView(message: message, isError: store.signInState == .failed || store.activity.isError)
            }
        }
    }

    private var isWaiting: Bool {
        if case .waiting = store.signInState { return true }
        return false
    }
}

/// Black on light, white on dark, with the Apple logo: Apple's own look for the button.
private struct SignInWithAppleStyleButton: View {
    var waiting: Bool
    var action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "applelogo").font(.system(size: 14, weight: .medium))
                Text(waiting ? "Waiting for Apple…" : "Sign in with Apple").font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(dark ? Color.black : Color.white)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(dark ? Color.white : Color.black, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sign in with Apple")
    }
}

/// What a signed-in account can do about Premium in this channel.
private struct PremiumOffer: View {
    @ObservedObject var store: PremiumStore
    var style: PremiumPlansView.Style

    var body: some View {
        if store.sellsInApp {
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
        } else {
            #if PP_DIRECT
            if !store.accountHasPremium {
                Divider()
                DirectPremiumLinks(store: store)
            }
            #endif
            if let message = store.activity.message {
                PremiumMessageView(message: message, isError: store.activity.isError)
            }
        }
    }
}

private extension View {
    /// Asks before a purchase leaves another account: a purchase can move once a year.
    func premiumMoveConfirmation(store: PremiumStore) -> some View {
        alert(
            PremiumMoveText.confirmTitle,
            isPresented: Binding(get: { store.moveRequest != nil }, set: { if !$0 { store.cancelMove() } }),
            presenting: store.moveRequest
        ) { _ in
            Button("Cancel", role: .cancel) { store.cancelMove() }
            Button(PremiumMoveText.confirmButton, role: .destructive) { Task { await store.confirmMove() } }
        } message: { request in
            Text(PremiumMoveText.confirmMessage(previousAccountEmailMasked: request.previousAccountEmailMasked))
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

/// How a purchase or restore ended. Orange is never a status: red for failure, secondary for everything else.
struct PremiumMessageView: View {
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
            Button(store.activity == .restoring || store.activity == .moving ? "Restoring…" : "Restore Purchases") {
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
