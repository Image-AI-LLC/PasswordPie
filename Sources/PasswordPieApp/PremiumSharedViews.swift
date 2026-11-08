import AppKit
import PasswordPieCore
import SwiftUI

/// The pie and the line at the top of the Premium window, in both channels.
struct PremiumWindowHeader: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
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
