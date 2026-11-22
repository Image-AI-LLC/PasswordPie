import Foundation
import PasswordPieCore

/// What the bubble at the bottom of the screen says. See "An account remembers its app" in docs/UX.md.
enum AppLinkNotice: Equatable {
    /// The account was just linked to the app. The bubble offers Undo.
    case linked(entry: UUID, title: String, app: LinkedApp)
    /// A click on the app in the account's details took the link off. The bubble offers Undo.
    case unlinked(entry: UUID, title: String, app: LinkedApp)
    /// Three distinct auto-added links were undone in `app`, so automatic adding stopped for it.
    case autoStopped(app: LinkedApp)

    var message: String {
        switch self {
        case .linked(_, let title, let app): "\(title) is now shown first in \(app.name)"
        case .unlinked(_, let title, let app): "\(title) is no longer shown first in \(app.name)"
        case .autoStopped(let app): "Stopped adding \(app.name) automatically"
        }
    }

    var action: String {
        switch self {
        case .linked, .unlinked: "Undo"
        case .autoStopped: "Turn Back On"
        }
    }

    var entry: UUID? {
        switch self {
        case .linked(let entry, _, _), .unlinked(let entry, _, _): entry
        case .autoStopped: nil
        }
    }

    var app: LinkedApp {
        switch self {
        case .linked(_, _, let app), .unlinked(_, _, let app), .autoStopped(let app): app
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
    /// If the user removed this app from this account before, or if automatic adding is off for the app (after 3 undos
    /// or excluded in Preferences), copying stays completely silent.
    func noteCopy(_ target: CopyTarget, of entry: VaultEntry) {
        guard target == .password, let app = copyTargetApp?(), !AppLinks.isLinked(entry, to: app) else { return }
        if AppLinks.refuses(entry, app) { return }
        if appLinkAutoExclusions.isExcluded(bundleID: app.bundleID) { return }
        let title = Self.linkTitle(of: entry)
        linkApp(app, to: entry.id, manual: false) { [weak self] saved in
            if saved { self?.onAppLink?(.linked(entry: entry.id, title: title, app: app)) }
        }
    }

    /// Links `app` to the account. Manual additions (`manual == true`) do not count toward the 3-undo app exclusion
    /// if later removed, and clear any pending strike for this account.
    func linkApp(_ app: LinkedApp, to id: UUID, manual: Bool = true, then done: @escaping (Bool) -> Void = { _ in }) {
        onActivity?()
        changeEntry(id, { AppLinks.link(app, to: &$0, manual: manual) }, then: { [weak self] saved in
            if saved, let self {
                var updated = self.appLinkAutoExclusions
                let before = updated
                updated.clearUndo(bundleID: app.bundleID, entryID: id)
                if updated != before { self.saveAppLinkAutoExclusions(updated) }
            }
            done(saved)
        })
    }

    /// Undo on the bubble, or a click on the app in the account's details. The refusal is kept with the account.
    /// If the removed link was added automatically, records an undo for `app`; on the 3rd distinct account undone
    /// in the same app, automatic adding stops for that app and announces `.autoStopped`.
    func unlinkApp(_ app: LinkedApp, from id: UUID, announce: Bool = false, then done: @escaping (Bool) -> Void = { _ in }) {
        onActivity?()
        let existing = entry(id)
        let title = existing.map(Self.linkTitle) ?? ""
        let wasAuto = existing.map { AppLinks.isLinked($0, to: app) && !AppLinks.isManual($0, to: app) } ?? false
        changeEntry(id, { AppLinks.unlink(app, from: &$0) }, then: { [weak self] saved in
            guard let self else { done(saved); return }
            if saved {
                var stoppedApp = false
                if wasAuto {
                    var updated = self.appLinkAutoExclusions
                    stoppedApp = updated.recordAutoUndo(app: app, entryID: id)
                    self.saveAppLinkAutoExclusions(updated)
                }
                if stoppedApp {
                    self.onAppLink?(.autoStopped(app: app))
                } else if announce {
                    self.onAppLink?(.unlinked(entry: id, title: title, app: app))
                }
            }
            done(saved)
        })
    }

    /// Proactively excludes `app` from automatic linking (Preferences › General). Manual linking still works.
    func excludeAppFromAutoLink(_ app: LinkedApp) {
        var updated = appLinkAutoExclusions
        guard updated.excludeManually(app) else { return }
        saveAppLinkAutoExclusions(updated)
    }

    /// Re-enables automatic linking for `bundleID` and resets its undo counter.
    func reenableAutoLink(bundleID: String) {
        var updated = appLinkAutoExclusions
        guard updated.reenable(bundleID: bundleID) else { return }
        saveAppLinkAutoExclusions(updated)
    }

    private func saveAppLinkAutoExclusions(_ updated: AppLinkAutoExclusions) {
        appLinkAutoExclusions = updated
        guard let url = appLinkExclusionsURL else { return }
        try? updated.encoded().write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Apps previously removed from this account, for the quiet "Removed earlier" note in the picker.
    func refusedApps(of id: UUID) -> [LinkedApp] {
        guard let entry = entry(id) else { return [] }
        return AppLinks.refusedApps(of: entry)
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
