import Foundation
import PasswordPieCore

/// What the bubble at the bottom of the screen says. See "An account remembers its app" in docs/UX.md.
enum AppLinkNotice: Equatable {
    /// The account was just linked to the app. The bubble offers Undo.
    case linked(entry: UUID, title: String, app: LinkedApp)
    /// The user took this link back before, so a password copied over the app only asks. The bubble offers Show first.
    case offer(entry: UUID, title: String, app: LinkedApp)
    /// A click on the app in the account's details took the link off. The bubble offers Undo.
    case unlinked(entry: UUID, title: String, app: LinkedApp)

    var message: String {
        switch self {
        case .linked(_, let title, let app): "\(title) is now shown first in \(app.name)"
        case .offer(_, let title, let app): "Show \(title) first in \(app.name) again?"
        case .unlinked(_, let title, let app): "\(title) is no longer shown first in \(app.name)"
        }
    }

    var action: String {
        switch self {
        case .linked, .unlinked: "Undo"
        case .offer: "Show first"
        }
    }

    var entry: UUID {
        switch self {
        case .linked(let entry, _, _), .offer(let entry, _, _), .unlinked(let entry, _, _): entry
        }
    }

    var app: LinkedApp {
        switch self {
        case .linked(_, _, let app), .offer(_, _, let app), .unlinked(_, _, let app): app
        }
    }
}

/// What the bubble says after a pick on a sign-in page added the page's site to the account. See "An account you pick
/// on another site's sign-in page" in docs/UX.md.
enum SiteNotice: Equatable {
    /// `website` was just added to the account. The bubble offers Undo.
    case added(entry: UUID, title: String, website: String)

    var message: String {
        switch self {
        case .added(_, let title, let website): "\(EntryWebsites.label(of: website)) is now a website of \(title)"
        }
    }

    var action: String { "Undo" }

    var entry: UUID {
        switch self {
        case .added(let entry, _, _): entry
        }
    }

    var website: String {
        switch self {
        case .added(_, _, let website): website
        }
    }
}

extension VaultSession {
    /// A pick on a sign-in page of a site the account does not list: the site becomes one of its websites, and the
    /// bubble says so. `done` gets true once the file holds it; only then may the page be filled.
    func addWebsite(_ website: String, to id: UUID, then done: @escaping (Bool) -> Void = { _ in }) {
        onActivity?()
        changeEntry(id, { EntryWebsites.add(website, to: &$0) }, then: { [weak self] saved in
            if saved, let self, let entry = self.entry(id) {
                self.onSiteNotice?(.added(entry: id, title: Self.linkTitle(of: entry), website: website))
            }
            done(saved)
        })
    }

    /// Undo on the bubble: takes off exactly the website that was added, if it is still there as it was added.
    func removeWebsite(_ website: String, from id: UUID, then done: @escaping (Bool) -> Void = { _ in }) {
        onActivity?()
        changeEntry(id, { EntryWebsites.remove(website, from: &$0) }, then: done)
    }

    /// The one rule that links an account to an app without asking: its password was copied while the app was in front.
    /// The username is not asked for, because many apps already show it. A wrong guess costs one click on Undo or on
    /// the app in the account's details, and after that the same copy only asks.
    func noteCopy(_ target: CopyTarget, of entry: VaultEntry) {
        guard target == .password, let app = copyTargetApp?(), !AppLinks.isLinked(entry, to: app) else { return }
        let title = Self.linkTitle(of: entry)
        if AppLinks.refuses(entry, app) {
            onAppLink?(.offer(entry: entry.id, title: title, app: app))
            return
        }
        linkApp(app, to: entry.id) { [weak self] saved in
            if saved { self?.onAppLink?(.linked(entry: entry.id, title: title, app: app)) }
        }
    }

    func linkApp(_ app: LinkedApp, to id: UUID, then done: @escaping (Bool) -> Void = { _ in }) {
        onActivity?()
        changeEntry(id, { AppLinks.link(app, to: &$0) }, then: done)
    }

    /// Undo on the bubble, or a click on the app in the account's details. The refusal is kept with the account.
    /// `announce` is for the click: the bubble then says what went, with Undo, because a click can be a slip.
    func unlinkApp(_ app: LinkedApp, from id: UUID, announce: Bool = false, then done: @escaping (Bool) -> Void = { _ in }) {
        onActivity?()
        let title = entry(id).map(Self.linkTitle) ?? ""
        changeEntry(id, { AppLinks.unlink(app, from: &$0) }, then: { [weak self] saved in
            if saved, announce { self?.onAppLink?(.unlinked(entry: id, title: title, app: app)) }
            done(saved)
        })
    }

    /// What the bubble calls the account.
    static func linkTitle(of entry: VaultEntry) -> String {
        if !entry.title.isEmpty { return entry.title }
        return entry.username.isEmpty ? "Untitled" : entry.username
    }

    /// The accounts for the top of the menu when `app` is in front.
    func appEntries(for app: LinkedApp) -> [VaultEntry] {
        AppLinks.entries(allEntries, linkedTo: app, lastUsed: lastUsedMap)
    }

    /// Whether Return on this account should copy for the app in front and not open a website.
    func isLinked(_ id: UUID, to app: LinkedApp?) -> Bool {
        guard let app, let entry = entry(id) else { return false }
        return AppLinks.isLinked(entry, to: app)
    }
}
