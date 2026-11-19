import PasswordPieCore
import SwiftUI

/// The items that were changed on two Macs before either had the other's change (docs/UX.md, "The same database on two
/// Macs"). The later change is the item; this window is where the earlier one is found and brought back. Titles, times
/// and field names only: no value is ever shown here.
struct ChangedOnBothView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var session: VaultSession
    var close: () -> Void
    /// The items whose history is showing.
    @State private var opened: Set<String>
    @State private var failure = ""

    init(session: VaultSession, opened: Set<String> = [], close: @escaping () -> Void) {
        self.session = session
        self.close = close
        _opened = State(initialValue: opened)
    }

    static let windowTitle = "Changed on Both Macs"
    static let explanation = "Each of these was changed on two Macs before either had the other's change. The later change is the item now. The earlier one is in its history: Restore brings it back, and can be taken back the same way."

    static func when(_ date: Date?) -> String {
        guard let date else { return "an unknown time" }
        return date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().second())
    }

    /// As tall as what it lists, within what a window should take.
    static func listHeight(_ items: [ChangedOnBothItem], opened: Set<String>) -> CGFloat {
        let rows = items.reduce(CGFloat(0)) { height, item in
            height + 74 + (opened.contains(item.id) ? CGFloat(max(item.versions.count, 1)) * 40 : 0)
        }
        return min(max(rows, 90), 380)
    }

    static func summary(of item: ChangedOnBothItem) -> String {
        let versions = "the change of \(when(item.kept)). In its history: the change of \(when(item.older))."
        return item.trashed ? "In the Recycle Bin, as of " + versions : "Now: " + versions
    }

    static func differs(_ names: [String]) -> String {
        names.isEmpty ? "Same fields as now" : "Differs in " + names.joined(separator: ", ")
    }

    var body: some View {
        let items = session.itemsChangedOnBoth()
        VStack(alignment: .leading, spacing: 12) {
            Text(items.isEmpty ? "No item was changed on both Macs" : MergeSummary.changedOnBoth(items.count))
                .font(.system(size: 13, weight: .semibold))
            Text(Self.explanation)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in row(item) }
                }
            }
            .frame(height: Self.listHeight(items, opened: opened))
            if !failure.isEmpty {
                Text(failure).font(.system(size: 11)).foregroundStyle(Palette.error(dark: colorScheme == .dark))
            }
            HStack {
                Spacer()
                Button("Done", action: close)
                    .buttonStyle(BrandPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 460)
        .background(Palette.windowSurface(dark: colorScheme == .dark))
        .onChange(of: session.locked) { _, locked in
            if locked { close() }
        }
    }

    @ViewBuilder
    private func row(_ item: ChangedOnBothItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title.isEmpty ? "Untitled" : item.title).font(.system(size: 13)).lineLimit(1)
                    if !item.username.isEmpty {
                        Text(item.username).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Button(opened.contains(item.id) ? "Hide History" : "History") {
                    if !opened.insert(item.id).inserted { opened.remove(item.id) }
                }
                .controlSize(.small)
                Button("Show Item") { session.pinEntry(item.listID) }
                    .controlSize(.small)
                    .disabled(item.trashed)
            }
            Text(Self.summary(of: item))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if opened.contains(item.id) {
                if item.versions.isEmpty {
                    Text("The database keeps no earlier versions of this item.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ForEach(item.versions) { version in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Self.when(version.modified) + (version.isTheEarlierChange ? " · the earlier change" : ""))
                                .font(.system(size: 12))
                            Text(Self.differs(version.differing))
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        // Nothing to bring back when the fields are the item's own, and no item to bring it back to
                        // while it is in the Recycle Bin.
                        Button("Restore") { restore(version, of: item) }
                            .controlSize(.small)
                            .disabled(session.savesPending || version.differing.isEmpty || item.trashed)
                    }
                    .padding(.leading, 12)
                    .padding(.top, 3)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 7)
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5) }
    }

    private func restore(_ version: ChangedOnBothItem.Version, of item: ChangedOnBothItem) {
        failure = ""
        session.restoreVersion(version.id, of: item.listID) { restored in
            if !restored { failure = session.message.isEmpty ? "That version could not be restored." : session.message }
        }
    }
}
