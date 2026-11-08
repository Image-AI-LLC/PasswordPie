#if PP_DIRECT
import AppKit
import PasswordPieCore
import SwiftUI

/// The downloaded app cannot sell through Apple, so it sends people to passwordpie.com to buy or redeem a key. Not
/// compiled into the App Store channel, which may not point anywhere else to buy (guideline 3.1.1).
struct DirectPremiumLinks: View {
    @ObservedObject var store: PremiumStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Get Premium on passwordpie.com, or redeem a key there. It shows up here straight after.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                SplitActionButton(title: "Get Premium", size: .regular, prominence: .primary) {
                    NSWorkspace.shared.open(store.site.base.appendingPathComponent("pricing"))
                }
                Button("Redeem a Key") {
                    NSWorkspace.shared.open(store.site.base.appendingPathComponent("redeem"))
                }
                Spacer(minLength: 4)
                Button("Check Again") { Task { await store.refresh(force: true) } }
            }
            .controlSize(.regular)
        }
    }
}

/// The small window a locked two-step code opens. It closes by itself when Premium arrives.
struct PaywallView: View {
    @ObservedObject var store: PremiumStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PremiumWindowHeader()
            if store.isSignedIn {
                AccountLine(store: store)
                DirectOffer(store: store)
            } else {
                AccountSignInView(store: store)
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(Palette.windowSurface(dark: colorScheme == .dark))
        .tint(Palette.brandAccent)
        .onAppear { store.clearMessage() }
    }
}

/// The Account section of Preferences: who is signed in, their Premium, and what can still be done about it.
struct AccountPreferencesSection: View {
    @ObservedObject var store: PremiumStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.isSignedIn {
                AccountLine(store: store)
                DirectOffer(store: store)
            } else {
                AccountSignInView(store: store)
            }
        }
        .controlSize(.regular)
    }
}

/// What a signed-in account can still do about Premium.
private struct DirectOffer: View {
    @ObservedObject var store: PremiumStore

    var body: some View {
        if !store.accountHasPremium {
            Divider()
            DirectPremiumLinks(store: store)
        }
        if let message = store.activity.message {
            PremiumMessageView(message: message, isError: false)
        }
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
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.title).fontWeight(.medium)
                if !summary.detail.isEmpty {
                    Text(summary.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondaryText(dark: colorScheme == .dark))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Signing in, Sign in with Apple first: one click when Safari knows the Apple Account.
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
                PremiumMessageView(message: message, isError: store.signInState == .failed)
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
#endif
