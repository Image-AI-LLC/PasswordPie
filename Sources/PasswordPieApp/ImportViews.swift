import AppKit
import PasswordPieCore
import SwiftUI
import UniformTypeIdentifiers

/// Preferences > Import: the sources, then one source's export steps and its file (docs/UX.md, "Import with a guide").
struct ImportPane: View {
    @ObservedObject var flow: ImportFlow
    @ObservedObject var session: VaultSession

    var body: some View {
        if let tile = flow.tile, tile.kind == .envFolder {
            DotenvImportPage(flow: flow, folder: flow.folder, session: session, tile: tile)
        } else if let tile = flow.tile {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PaneHeader(title: "Import", subtitle: "Into “\(session.databaseURL.lastPathComponent)”")
            // One list, in two columns by kind. A source whose app is on this Mac shows that app's icon.
            HStack(alignment: .top, spacing: 28) {
                column("Browsers", ImportTile.all.filter { $0.group == .browser })
                column("Password managers", ImportTile.all.filter { $0.group == .manager && $0.source != .csv })
            }
            VStack(alignment: .leading, spacing: 0) {
                PaneRule()
                ForEach(ImportTile.all.filter { $0.source == .csv } + [ImportTile.envFolder]) { tile in
                    ImportSourceRow(tile: tile, detail: tile.hint) { flow.choose(tile) }
                }
            }
            Text("The file or folder you choose is read on this Mac. Nothing is sent anywhere.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func column(_ title: String, _ tiles: [ImportTile]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneGroupLabel(title).padding(.bottom, 6)
            PaneRule()
            ForEach(tiles) { tile in
                ImportSourceRow(tile: tile, detail: tile.format) { flow.choose(tile) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// One source: its icon, its name, and the file it takes. The whole row is the button.
private struct ImportSourceRow: View {
    let tile: ImportTile
    let detail: String
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ImportIcon(tile: tile, size: 26)
                Text(tile.name).lineLimit(1)
                Spacer(minLength: 4)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40)
            .background(hovered ? Palette.brandAccent.opacity(0.14) : Color.clear)
            .overlay(alignment: .bottom) { PaneRule() }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("Import from \(tile.name)")
        .accessibilityHint(tile.hint)
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
        VStack(alignment: .leading, spacing: 20) {
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
                ImportSection(title: withoutFile.title) {
                    steps(withoutFile)
                    if flow.reading {
                        Text("Reading Apple Passwords…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    PaneGroupLabel("Or with a file")
                    PaneRule()
                }
            }
            if let export = guide.export {
                ImportSection(title: export.title) { steps(export) }
                ImportSection(title: "Add the file") {
                    fileZone(guide)
                    // What importing does, beside the button that does it.
                    if !guide.after.isEmpty, !isDone {
                        Text(guide.after)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            guard tile.source != nil, let provider = providers.first else { return false }
            // The file arrives later. It belongs to the source it was dropped on, not to one chosen since.
            let dropped = tile
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    guard flow.tile == dropped else { return }
                    flow.take(url)
                }
            }
            return true
        }
    }

    private var isDone: Bool {
        if case .done = flow.stage { return true }
        return false
    }

    private var heading: some View {
        HStack(spacing: 10) {
            ImportIcon(tile: tile, size: 34)
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
        let opens = steps.opens.flatMap { installedApp == nil ? nil : $0 }
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(steps.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 12, alignment: .leading)
                    VStack(alignment: .leading, spacing: 6) {
                        // Markdown: the names of menus and buttons are bold.
                        Text(LocalizedStringKey(step))
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                        // The first step is in the other app: the button takes you there.
                        if index == 0, let opens {
                            Button("Open \(opens)") { open() }
                                .fixedSize()
                                .padding(.bottom, 2)
                        }
                    }
                }
            }
        }
        if let address = steps.address {
            // The quiet way round the first steps: one line, after them.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Text("Or paste into \(tile.name)’s address bar:")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    addressField(address)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Or paste into \(tile.name)’s address bar:")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    addressField(address)
                }
            }
            .padding(.leading, 20)
        }
    }

    /// The address and its copy button, as one field.
    @ViewBuilder
    private func addressField(_ address: String?) -> some View {
        if let address {
            HStack(spacing: 2) {
                Text(address)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .fixedSize()
                    .textSelection(.enabled)
                    .padding(.leading, 8)
                CopyAddressButton(address: address)
            }
            .frame(height: 26)
            .background(Palette.card(dark: dark).opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.14)))
        }
    }

    private var installedApp: URL? {
        tile.opensBundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    private func open() {
        guard let url = installedApp else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: The file

    /// The page's one container: the place the file goes, then what was read from it, then what importing did.
    @ViewBuilder
    private func fileZone(_ guide: ImportGuide) -> some View {
        Group {
            if case .waiting = flow.stage {
                dropZone(guide)
            } else {
                fileState.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(
            targeted ? Palette.brandAccent.opacity(0.12) : Palette.card(dark: dark).opacity(0.7),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(targeted ? Palette.brandAccent : Color.primary.opacity(0.12), lineWidth: targeted ? 1.5 : 1)
        )
        if !flow.error.isEmpty {
            Text(flow.error)
                .font(.system(size: 11))
                .foregroundStyle(Palette.error(dark: dark))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("import-error")
        }
    }

    @ViewBuilder
    private var fileState: some View {
        switch flow.stage {
        case .waiting:
            EmptyView()
        case .reading(let fileName):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Reading \(fileName)…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
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
    }

    /// One row: what to drop, and the button for those who would rather choose.
    private func dropZone(_ guide: ImportGuide) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.locked ? "Unlock PasswordPie to import" : "Drop the file here")
                    .fontWeight(.medium)
                Text(guide.files)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Choose File…") { flow.chooseFile() }
                .buttonStyle(BrandPrimaryButtonStyle())
                .disabled(session.locked)
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 76)
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
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(address, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied" : "Copy")
        .accessibilityLabel("Copy the address")
        .accessibilityValue(copied ? "Copied" : "")
    }
}

/// A part of the source's page: its title, then what is under it. No box: the page has one, for the file.
struct ImportSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .fontWeight(.semibold)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
