import AppKit
import PasswordPieCore
import SwiftUI
import UniformTypeIdentifiers

/// Preferences > Import > A Folder of .env Files: choose the folder, look at what was found, import (docs/UX.md, "A folder
/// of .env files becomes items"). The page shows names and counts. A value is never drawn.
struct DotenvImportPage: View {
    @ObservedObject var flow: ImportFlow
    @ObservedObject var folder: DotenvImportFlow
    @ObservedObject var session: VaultSession
    let tile: ImportTile

    @State private var targeted = false
    @State private var opened: Set<String> = []
    @State private var listsLeftAlone = false
    @Environment(\.colorScheme) private var colorScheme

    private var dark: Bool { colorScheme == .dark }

    var body: some View {
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

            HStack(spacing: 10) {
                ImportIcon(tile: tile, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import a folder of .env files").font(.system(size: 16, weight: .semibold))
                    Text("Into “\(session.databaseURL.lastPathComponent)”")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .accessibilityElement(children: .combine)

            Text("Each .env file becomes an item named after it, in a folder named after the folder it is in: stripe/work.env is the item work in the folder stripe. Every variable is a protected field, comment lines are the notes, and key files beside it are attached. The folder is only read: nothing in it is changed.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch folder.stage {
            case .waiting, .reading:
                ImportSection(title: "Choose the folder") { zone }
            case .found:
                found
            case .done(let outcome):
                ImportSection(title: "Done") { box { done(outcome) } }
            }
            if !folder.error.isEmpty {
                Text(folder.error)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.error(dark: dark))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("import-error")
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    guard flow.tile?.kind == .envFolder else { return }
                    folder.take(url)
                }
            }
            return true
        }
    }

    // MARK: The folder

    private func box<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                targeted ? Palette.brandAccent.opacity(0.12) : Palette.card(dark: dark).opacity(0.7),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(targeted ? Palette.brandAccent : Color.primary.opacity(0.12), lineWidth: targeted ? 1.5 : 1)
            )
    }

    @ViewBuilder
    private var zone: some View {
        box {
            if case .reading(let name) = folder.stage {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Reading \(name)…").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            } else {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.locked ? "Unlock PasswordPie to import" : "Drop the folder here")
                            .fontWeight(.medium)
                        Text("The folder that holds the .env files, with its subfolders")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("Choose Folder…") { folder.chooseFolder() }
                        .buttonStyle(BrandPrimaryButtonStyle())
                        .disabled(session.locked)
                        .fixedSize()
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 76)
            }
        }
    }

    // MARK: What was found

    @ViewBuilder
    private var found: some View {
        let skipped = folder.plan?.skipped ?? []
        let remarks = folder.plan?.remarks ?? []
        ImportSection(title: "\(DotenvImportFlow.counted(folder.rows.count, "item")) in “\(folder.plan?.folderName ?? "")”") {
            Text("Nothing is in your database yet. Untick an item to leave it out. Click one to see the names in it.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 0) {
                PaneRule()
                ForEach(folder.rows) { row in
                    itemRow(row)
                    PaneRule()
                }
            }
        }
        ImportSection(title: "Put them inside") {
            HStack(spacing: 8) {
                TextField("No folder: at the top of the database", text: $folder.parentDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                    .accessibilityLabel("Put them inside the folder")
                Text("A folder name, such as Agents")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        if !skipped.isEmpty { leftAlone(skipped) }
        if !remarks.isEmpty {
            ImportSection(title: "To check") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(remarks.enumerated()), id: \.offset) { _, remark in
                        Text(DotenvImportFlow.remarkText(remark))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        HStack(spacing: 12) {
            Button(folder.importTitle) { folder.commit() }
                .buttonStyle(BrandPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(folder.pendingCount == 0)
            Button("Choose Another Folder") { folder.startOver() }
                .buttonStyle(.link)
                .foregroundStyle(Palette.accentText(dark: dark))
            if let nothing = folder.nothingToImport {
                Text(nothing).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func itemRow(_ row: DotenvImportFlow.Row) -> some View {
        let isOpen = opened.contains(row.id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(get: { folder.isIncluded(row.id) }, set: { _ in folder.toggle(row.id) }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .accessibilityLabel("Import \(row.place)")
                Button {
                    if isOpen { opened.remove(row.id) } else { opened.insert(row.id) }
                } label: {
                    HStack(spacing: 8) {
                        Text(row.place).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 6)
                        Text(DotenvImportFlow.contents(row))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(DotenvImportFlow.statusText(row.status))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(row.status == .upToDate ? Palette.secondaryText(dark: dark) : Palette.accentText(dark: dark))
                            .lineLimit(1)
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 10)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(isOpen ? "Hides the names" : "Shows the names of its fields and key files")
            }
            if isOpen {
                VStack(alignment: .leading, spacing: 2) {
                    if !row.fieldNames.isEmpty {
                        Text("Fields: " + row.fieldNames.joined(separator: ", "))
                    }
                    if !row.fileNames.isEmpty {
                        Text("Key files: " + row.fileNames.joined(separator: ", "))
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.leading, 26)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 6)
        .opacity(folder.isIncluded(row.id) ? 1 : 0.55)
    }

    @ViewBuilder
    private func leftAlone(_ skipped: [DotenvPlan.Skipped]) -> some View {
        let holding = skipped.filter { !$0.holds.isEmpty }
        ImportSection(title: "Left alone") {
            Text(DotenvImportFlow.leftAlone(skipped).joined(separator: " · "))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !holding.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(holding.count == 1 ? "1 of them holds" : "\(holding.count) of them hold") values from these files, in plain text:")
                        .font(.system(size: 11, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(holding, id: \.path) { file in
                        Text("\(file.path)\(file.isFolder ? "/" : ""): \(file.holds.joined(separator: ", "))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Button(listsLeftAlone ? "Hide the List" : "Show the List") { listsLeftAlone.toggle() }
                .buttonStyle(.link)
                .foregroundStyle(Palette.accentText(dark: dark))
            if listsLeftAlone {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(skipped, id: \.path) { file in
                        Text("\(file.path)\(file.isFolder ? "/" : "")  (\(DotenvImportFlow.reasonText(file)))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }

    // MARK: Done

    private func done(_ outcome: DotenvImportFlow.Outcome) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(DotenvImportFlow.summaryText(outcome)).fontWeight(.medium)
                Text(DotenvImportFlow.folderText(outcome))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Import Another Folder") { folder.startOver() }
                    Button("All Sources") { flow.showSources() }
                }
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }
}
