import AppKit
import PasswordPieCore
import SwiftUI
import UniformTypeIdentifiers

/// Preferences > Import: the sources, then one source's export steps and its file (docs/UX.md, "Import with a guide").
struct ImportPane: View {
    @ObservedObject var flow: ImportFlow
    @ObservedObject var session: VaultSession

    var body: some View {
        if let tile = flow.tile {
            ImportSourcePage(flow: flow, session: session, tile: tile)
        } else {
            ImportSourcesPage(flow: flow, session: session)
        }
    }
}

// MARK: - Icons

/// A source's icon: the app's own when it is installed, then the one bundled for it (`Contents/Resources/ImportIcons`,
/// made by `Scripts/fetch_site_icons.py --import-sources`), then a letter tile. Nothing is fetched.
struct ImportIcon: View {
    let tile: ImportTile
    var size: CGFloat = 32

    @Environment(\.colorScheme) private var colorScheme

    @MainActor private static var icons: [String: NSImage?] = [:]
    @MainActor private static var bundled: [String: NSImage?] = [:]

    /// The folder of bundled icons. Tests point it at the repository's.
    @MainActor static var bundledDirectory = Bundle.main.resourceURL?.appendingPathComponent("ImportIcons", isDirectory: true)

    /// The icon of the first of the tile's apps that is on this Mac.
    @MainActor
    static func appIcon(_ tile: ImportTile) -> NSImage? {
        #if DEBUG
        // Screenshots of what a Mac without these apps shows.
        if ProcessInfo.processInfo.environment["PASSWORDPIE_IMPORT_NO_APPS"] != nil { return nil }
        #endif
        if let known = icons[tile.id] { return known }
        let found = tile.bundleIDs.lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .first
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        icons[tile.id] = .some(found)
        return found
    }

    /// `<id>.png` (64 px) and `<id>@2x.png` (128 px).
    @MainActor
    static func bundledIcon(_ tile: ImportTile) -> NSImage? {
        let key = (bundledDirectory?.path ?? "") + "/" + tile.id
        if let known = bundled[key] { return known }
        var found: NSImage?
        if let bundledDirectory {
            let reps = ["", "@2x"].compactMap { suffix -> NSBitmapImageRep? in
                guard let data = try? Data(contentsOf: bundledDirectory.appendingPathComponent(tile.id + suffix + ".png")) else { return nil }
                return NSBitmapImageRep(data: data)
            }
            if !reps.isEmpty {
                let image = NSImage(size: NSSize(width: 64, height: 64))
                for rep in reps {
                    rep.size = image.size
                    image.addRepresentation(rep)
                }
                found = image
            }
        }
        bundled[key] = .some(found)
        return found
    }

    var body: some View {
        Group {
            if let icon = Self.appIcon(tile) {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else if let icon = Self.bundledIcon(tile) {
                // On a white plate, as an app icon: some of these are dark shapes that vanish on the dark surface.
                RoundedRectangle(cornerRadius: size * 0.2)
                    .fill(Color.white)
                    .overlay(RoundedRectangle(cornerRadius: size * 0.2).strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5))
                    .overlay(
                        Image(nsImage: icon).resizable().interpolation(.high)
                            .padding(size * 0.13)
                    )
                    .padding(size * 0.09)
            } else if let symbol = tile.symbol {
                // As an empty database's action rows: an outline on the orange tile.
                RoundedRectangle(cornerRadius: size * 0.24)
                    .fill(Palette.brandAccent.opacity(0.2))
                    .overlay(
                        Image(systemName: symbol)
                            .font(.system(size: size * 0.46, weight: .medium))
                            .foregroundStyle(Palette.accentText(dark: colorScheme == .dark))
                    )
                    .padding(size * 0.09)
            } else {
                LetterTile(name: tile.name, size: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The letter tile of an item with no site icon, at the size of an app icon.
private struct LetterTile: View {
    let name: String
    let size: CGFloat

    private var hue: Double {
        var hash: UInt32 = 2166136261
        for byte in name.lowercased().utf8 { hash = (hash ^ UInt32(byte)) &* 16777619 }
        return Double(MenuPalette.tileHues[Int(hash % UInt32(MenuPalette.tileHues.count))])
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24)
            .fill(LinearGradient(
                colors: [Color(hue: hue, saturation: 0.45, brightness: 0.95), Color(hue: hue, saturation: 0.7, brightness: 0.78)],
                startPoint: .top,
                endPoint: .bottom
            ))
            .overlay(
                Text(name.first.map { String($0).uppercased() } ?? "•")
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(.white)
            )
            // An app icon keeps a margin inside its square.
            .padding(size * 0.09)
    }
}

// MARK: - Sources

private struct ImportSourcesPage: View {
    @ObservedObject var flow: ImportFlow
    @ObservedObject var session: VaultSession
    @Environment(\.colorScheme) private var colorScheme

    /// Five across at the window's first size, so the browsers fill one row.
    private let columns = [GridItem(.adaptive(minimum: 92), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaneHeader(title: "Import", subtitle: "Choose where your passwords are now.")
            ForEach(ImportTile.Group.allCases, id: \.self) { group in
                VStack(alignment: .leading, spacing: 7) {
                    PaneGroupLabel(group.rawValue)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                        ForEach(ImportTile.all.filter { $0.group == group }) { tile in
                            ImportTileButton(tile: tile) { flow.choose(tile) }
                        }
                    }
                }
            }
            Text("Passwords are added to “\(session.databaseURL.lastPathComponent)”. The file you choose is read on this Mac, and nothing is sent anywhere.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ImportTileButton: View {
    let tile: ImportTile
    let action: () -> Void

    @State private var hovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ImportIcon(tile: tile, size: 32)
                Text(tile.name)
                    .font(.system(size: 11, weight: .medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 84, maxHeight: 84)
            .background(Palette.card(dark: colorScheme == .dark), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(hovered ? Palette.brandAccent : Color.primary.opacity(0.07), lineWidth: hovered ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("Import from \(tile.name)")
    }
}

// MARK: - One source

private struct ImportSourcePage: View {
    @ObservedObject var flow: ImportFlow
    @ObservedObject var session: VaultSession
    let tile: ImportTile

    @State private var targeted = false
    @Environment(\.colorScheme) private var colorScheme

    private var dark: Bool { colorScheme == .dark }

    private var guide: ImportGuide {
        ImportGuide.guide(
            for: tile,
            exchange: VaultSession.credentialExchangeAvailable,
            macOS: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        )
    }

    var body: some View {
        let guide = guide
        VStack(alignment: .leading, spacing: 14) {
            Button {
                flow.showSources()
            } label: {
                Label("All Sources", systemImage: "chevron.left")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Back to the list of sources")

            heading
            if let intro = guide.intro {
                Text(intro)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if tile.kind == .keePass {
                Button("Open Database…") { session.chooseDatabase() }
            }
            if let withoutFile = guide.withoutFile {
                ImportCard(number: nil, title: withoutFile.title) {
                    steps(withoutFile)
                    if flow.reading {
                        Text("Reading Apple Passwords…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                PaneGroupLabel("Or with a file")
            }
            if let export = guide.export {
                ImportCard(number: 1, title: export.title) { steps(export) }
                ImportCard(number: 2, title: "Add the file here") {
                    fileZone(guide)
                }
                if !guide.after.isEmpty, !isDone {
                    Text(guide.after)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            guard tile.source != nil, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in flow.take(url) }
            }
            return true
        }
    }

    private var isDone: Bool {
        if case .done = flow.stage { return true }
        return false
    }

    private var heading: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                ImportIcon(tile: tile, size: 32)
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                PasswordPieMark(size: 27)
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Palette.card(dark: dark), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
            VStack(alignment: .leading, spacing: 2) {
                Text(tile.kind == .keePass ? "Coming from KeePass" : "Import from \(tile.name)")
                    .font(.system(size: 16, weight: .semibold))
                Text("Into “\(session.databaseURL.lastPathComponent)”")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func steps(_ steps: ImportGuide.Steps) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(steps.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(index + 1).")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 16, alignment: .trailing)
                    // Markdown: the names of menus and buttons are bold.
                    Text(LocalizedStringKey(step))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        let opens = steps.opens.flatMap { installedApp == nil ? nil : $0 }
        if steps.address != nil || opens != nil {
            VStack(alignment: .leading, spacing: 6) {
                if steps.address != nil {
                    Text("Or go straight there: paste this address into \(tile.name).")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    if let address = steps.address {
                        Text(address)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .fixedSize()
                            .textSelection(.enabled)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                        CopyAddressButton(address: address)
                    }
                    if let opens {
                        Button("Open \(opens)") { open() }
                    }
                }
            }
            .padding(.leading, 22)
            .padding(.top, 2)
        }
    }

    private var installedApp: URL? {
        tile.bundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    private func open() {
        guard let url = installedApp else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: The file

    @ViewBuilder
    private func fileZone(_ guide: ImportGuide) -> some View {
        switch flow.stage {
        case .waiting:
            dropZone(guide)
        case .protected(let fileName):
            fileRow(symbol: "lock.doc", title: fileName, detail: "This file is protected. Type its password to read it.") {
                HStack(spacing: 8) {
                    SecureField("Password for this file", text: $flow.passwordDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .onSubmit { flow.unlockFile() }
                    Button("Unlock") { flow.unlockFile() }
                        .disabled(flow.passwordDraft.isEmpty)
                    Button("Choose Another File") { flow.startOver() }
                        .buttonStyle(.link)
                        .foregroundStyle(Palette.accentText(dark: dark))
                }
            }
        case .found(let fileName, let count):
            let source = tile.source ?? .csv
            fileRow(symbol: "doc.fill", title: "\(ImportFlow.counted(count, from: source)) in \(fileName)", detail: "Nothing is in your database yet.") {
                HStack(spacing: 12) {
                    Button("Import \(ImportFlow.counted(count, from: source, capitalized: true))") { flow.commit() }
                        .buttonStyle(BrandPrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                    Button("Choose Another File") { flow.startOver() }
                        .buttonStyle(.link)
                        .foregroundStyle(Palette.accentText(dark: dark))
                }
            }
        case .done(let outcome):
            done(outcome)
        }
        if !flow.error.isEmpty {
            Text(flow.error)
                .font(.system(size: 11))
                .foregroundStyle(Palette.error(dark: dark))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("import-error")
        }
    }

    private func dropZone(_ guide: ImportGuide) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(session.locked ? "Unlock PasswordPie to import" : "Drop the file here")
            Text(guide.files)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Choose File…") { flow.chooseFile() }
                .disabled(session.locked)
                .padding(.top, 4)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 116)
        .background(targeted ? Palette.brandAccent.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    targeted ? Palette.brandAccent : Palette.border(dark: dark),
                    style: StrokeStyle(lineWidth: 1.5, dash: targeted ? [] : [6, 4])
                )
        )
    }

    private func fileRow<Actions: View>(symbol: String, title: String, detail: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.medium).lineLimit(2).truncationMode(.middle)
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                actions().padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
    }

    private func done(_ outcome: ImportFlow.Outcome) -> some View {
        fileRow(symbol: "checkmark.circle.fill", title: ImportFlow.summaryText(outcome), detail: ImportFlow.fileText(outcome)) {
            HStack(spacing: 8) {
                if outcome.file == .ask {
                    Button("Delete File") { flow.deleteFile() }
                    Button("Keep File") { flow.keepFile() }
                } else {
                    Button("Import Another File") { flow.startOver() }
                    Button("All Sources") { flow.showSources() }
                }
            }
        }
        .foregroundStyle(outcome.file == .deleteFailed ? Palette.error(dark: dark) : Palette.text(dark: dark))
    }
}

private struct CopyAddressButton: View {
    let address: String
    @State private var copied = false

    var body: some View {
        Button(copied ? "Copied" : "Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(address, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        }
        .controlSize(.small)
        .accessibilityLabel("Copy the address")
    }
}

/// A numbered card of the source's page.
private struct ImportCard<Content: View>: View {
    let number: Int?
    let title: String
    @ViewBuilder var content: () -> Content

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let number {
                    Text("\(number)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.accentText(dark: colorScheme == .dark))
                        .frame(width: 20, height: 20)
                        .background(Palette.brandAccent.opacity(0.2), in: Circle())
                        .accessibilityHidden(true)
                }
                Text(title).fontWeight(.medium)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card(dark: colorScheme == .dark), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
    }
}
