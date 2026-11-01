import SwiftUI

/// Copy for the About window. The Majestic Million list is CC BY 3.0, not CC BY-SA.
enum AboutCopy {
    static let menuTitle = "About PasswordPie"
    static let repositoryURL = URL(string: "https://github.com/Image-AI-LLC/PasswordPie")!
    static let repositoryLabel = "github.com/Image-AI-LLC/PasswordPie"
    static let attribution = "Site popularity in search comes from the [Majestic Million](https://majestic.com/reports/majestic-million), licensed under [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/)."

    static var attributionText: AttributedString {
        (try? AttributedString(markdown: attribution)) ?? AttributedString(attribution)
    }

    static func versionLabel(short: String?, build: String?) -> String {
        let short = short?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let build = build?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if short.isEmpty { return "Version 0.1.0" }
        if build.isEmpty || build == short { return "Version \(short)" }
        return "Version \(short) (\(build))"
    }

    static func versionLabel(bundle: Bundle = .main) -> String {
        versionLabel(
            short: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }
}

/// Credits and the source repository, kept off Preferences so that window stays a list of settings.
struct AboutView: View {
    var version = AboutCopy.versionLabel()
    @Environment(\.colorScheme) private var colorScheme

    private var cardColor: Color {
        colorScheme == .dark ? Color(nsColor: .controlBackgroundColor) : .white
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            card("Repository") { repository }
            card("Credits") { credits }
        }
        .padding(24)
        .frame(width: 440)
        .font(.system(size: 13))
        .background(Color(nsColor: .windowBackgroundColor))
        .fixedSize(horizontal: true, vertical: true)
    }

    private var header: some View {
        HStack(spacing: 14) {
            PasswordPieMark(size: 40)
                .frame(width: 46, height: 48)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("PasswordPie").font(.system(size: 24, weight: .semibold))
                Text(version)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
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

    private var repository: some View {
        Link(destination: AboutCopy.repositoryURL) {
            Text(AboutCopy.repositoryLabel)
        }
        .accessibilityLabel("GitHub repository")
        .accessibilityValue(AboutCopy.repositoryURL.absoluteString)
    }

    private var credits: some View {
        Text(AboutCopy.attributionText)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("about-attribution")
    }
}
