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
#endif
