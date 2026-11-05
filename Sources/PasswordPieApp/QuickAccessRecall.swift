import Foundation
import PasswordPieCore

/// One row of a list, in a form that survives a rebuild. Search order changes after every use, so an index would point at
/// another account, and two accounts can share a title.
enum MenuRowRef: Equatable {
    case entry(UUID)
    case named(String)

    init(_ row: MenuRow) {
        self = row.entryID.map(Self.entry) ?? .named(row.title)
    }

    func matches(_ row: MenuRow) -> Bool {
        row.isSelectable && self == Self(row)
    }
}

/// Where the keyboard is in the menu: the query, and the selected row of each open level from the root down.
struct MenuPlace: Equatable {
    var query: String
    var path: [MenuRowRef]
}

/// What the menu showed when it closed. `searchText` is the field as typed; `place.query` is trimmed.
struct QuickAccessSnapshot: Equatable {
    var searchText: String
    var place: MenuPlace
}

/// Keeps the last snapshot for 10 seconds after the menu closes. See `docs/UX.md`, "Pick up where you left off".
/// In memory only. The panel forgets it on lock and when Escape closes the menu.
struct QuickAccessRecall {
    static let window: TimeInterval = 10
    private var saved: (snapshot: QuickAccessSnapshot, at: Date)?

    mutating func remember(_ snapshot: QuickAccessSnapshot, at now: Date) {
        saved = (snapshot, now)
    }

    /// Wall-clock time on purpose: uptime stops during sleep, so a closed lid would not count towards the 10 seconds.
    mutating func take(at now: Date) -> QuickAccessSnapshot? {
        defer { saved = nil }
        guard let saved else { return nil }
        let elapsed = now.timeIntervalSince(saved.at)
        return elapsed >= 0 && elapsed < Self.window ? saved.snapshot : nil
    }

    mutating func forget() {
        saved = nil
    }
}
