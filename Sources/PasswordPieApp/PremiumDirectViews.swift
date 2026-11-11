#if PP_DIRECT
import AppKit
import PasswordPieCore
import SwiftUI

// The downloaded app's Premium UI. There is no sign-in: Premium is bought on passwordpie.com and reaches this Mac with
// Activate there. It sends people to passwordpie.com to buy or redeem a key, so it is not compiled
// into the App Store channel, which may not point anywhere else to buy (guideline 3.1.1).

/// The passwordpie.com pages the downloaded app opens in the browser. The app itself sends them nothing.
enum DirectPremiumSite {
    static let base = URL(string: "https://passwordpie.com")!
    static var pricing: URL { base.appendingPathComponent("pricing") }
    static var redeem: URL { base.appendingPathComponent("redeem") }
    /// The account settings, where Activate is.
    static var activate: URL { base.appendingPathComponent("settings/premium") }
}

/// What the Premium window says about Premium, and which actions it offers. Words only; the views lay them out.
struct DirectPremiumCopy: Equatable {
    var title: String
    var detail: String
    /// An activation ends within `warningDays`: say so before the codes stop.
    var warning: String?
    /// Get Premium, Redeem a Key, and how Premium bought already reaches this Mac.
    var offersPremium: Bool
    /// Open Account Settings, where Activate is.
    var showsActivate: Bool

    static let warningDays: TimeInterval = 30

    static func make(
        status: DirectPremiumStatus,
        lapse: PremiumLapse?,
        now: Date,
        dateText: (Date) -> String = { $0.formatted(date: .long, time: .omitted) }
    ) -> DirectPremiumCopy {
        switch status {
        case .activation(let until):
            let ending = until.timeIntervalSince(now) <= warningDays * 86400
            return DirectPremiumCopy(
                title: "Premium is on",
                detail: "Activated through \(dateText(until)). To renew it, press Activate in your account settings on passwordpie.com again, at any time.",
                warning: ending ? "Premium on this Mac ends on \(dateText(until)). Renew it before then to keep your two-step codes." : nil,
                offersPremium: false, showsActivate: true
            )
        case .none:
            let off = "Premium is off"
            let detail: (String, String)
            switch lapse {
            case nil:
                detail = ("Free", "Two-step codes need Premium. Everything else in PasswordPie is free.")
            case .activationRanOut(let ended):
                detail = (off, "The activation from passwordpie.com ended on \(dateText(ended)). Press Activate in your account settings to renew it.")
            }
            return DirectPremiumCopy(title: detail.0, detail: detail.1, warning: nil, offersPremium: true, showsActivate: true)
        }
    }
}

extension DirectPremiumStore {
    func copy(dateText: (Date) -> String = { $0.formatted(date: .long, time: .omitted) }) -> DirectPremiumCopy {
        DirectPremiumCopy.make(status: status, lapse: lapse, now: now(), dateText: dateText)
    }
}

/// The small window a locked two-step code or an activation link opens. It closes by itself when Premium arrives, unless
/// it has something to say.
struct PaywallView: View {
    @ObservedObject var store: PremiumStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PremiumWindowHeader()
            DirectPremiumContent(store: store)
        }
        .padding(20)
        .frame(width: 400)
        .background(Palette.windowSurface(dark: colorScheme == .dark))
        .tint(Palette.brandAccent)
        .onAppear { store.clearMessage() }
    }
}

/// The Premium section of Preferences: the same as the window, without its header.
struct PremiumPreferencesSection: View {
    @ObservedObject var store: PremiumStore

    var body: some View {
        DirectPremiumContent(store: store)
            .controlSize(.regular)
    }
}

/// What this Mac has, what a link just did, and what can be done about it.
private struct DirectPremiumContent: View {
    @ObservedObject var store: PremiumStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let copy = store.copy()
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(copy.title).fontWeight(.medium)
                small(copy.detail)
            }
            if let warning = copy.warning {
                Text(warning)
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = store.activity.message {
                PremiumMessageView(message: message, isError: store.activity.isError)
            }
            if copy.offersPremium {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    small("Get Premium on passwordpie.com, once or yearly, or redeem a key there.")
                    HStack(spacing: 8) {
                        SplitActionButton(title: "Get Premium", size: .regular, prominence: .primary) {
                            NSWorkspace.shared.open(DirectPremiumSite.pricing)
                        }
                        Button("Redeem a Key") { NSWorkspace.shared.open(DirectPremiumSite.redeem) }
                    }
                }
                Divider()
                small("Already have Premium? Press Activate in your account settings on passwordpie.com.")
            }
            if copy.showsActivate {
                Button("Open Account Settings") { NSWorkspace.shared.open(DirectPremiumSite.activate) }
            }
        }
        .controlSize(.regular)
    }

    private func small(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Palette.secondaryText(dark: colorScheme == .dark))
            .fixedSize(horizontal: false, vertical: true)
    }
}
#endif
