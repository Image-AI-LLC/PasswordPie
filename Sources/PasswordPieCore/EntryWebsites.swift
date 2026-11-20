import Foundation

/// The website a pick on a sign-in page adds to the account, and takes off again on Undo. See "An account you pick on
/// another site's sign-in page" in docs/UX.md, and "A site added by a pick" in docs/BROWSER_EXTENSION.md.
public enum EntryWebsites {
    /// What is kept for the page the person was on: its origin (`https://portal.example.com`), which is all the
    /// extension reports. Nil for anything that is not a web page, and for plain http other than this Mac's own
    /// loopback: an address added by one keypress never undoes "No downgrade".
    public static func address(forPage pageURL: String) -> String? {
        guard let page = BrowserSite(url: pageURL), page.scheme == "https" || page.isLoopback else { return nil }
        return page.origin
    }

    /// What the bubble calls the website: its host, with the port when it has one, as the address bar shows them.
    public static func label(of website: String) -> String {
        guard let site = BrowserSite(url: website) else { return website }
        return String(site.origin.dropFirst(site.scheme.count + 3))
    }

    /// Adds `website` after the websites the entry has, or as its website when it has none. False, and nothing changed,
    /// when it is not a web address or the entry already fills that site.
    @discardableResult
    public static func add(_ website: String, to entry: inout VaultEntry) -> Bool {
        guard let page = BrowserSite(url: website),
              !entryFillSites(entry).contains(where: { BrowserSite(url: $0)?.allowsFill(on: page) == true }) else { return false }
        if entry.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            entry.url = website
            return true
        }
        // Numbered as the editor numbers a website it adds, past every name in use, whatever its case.
        let taken = Set(entry.fields.map { $0.key.lowercased() })
        var number = 2
        while taken.contains("url (\(number))") { number += 1 }
        entry.fields.append(VaultField(key: "URL (\(number))", value: website))
        return true
    }

    /// Takes `website` off again: the last of the entry's other websites that is exactly it, else the main one when
    /// it is. An address the person has changed since is left alone. False when there was nothing to take off.
    @discardableResult
    public static func remove(_ website: String, from entry: inout VaultEntry) -> Bool {
        let others = Set(EntryMerge.otherWebsites(entry).map(\.key))
        if let index = entry.fields.lastIndex(where: { others.contains($0.key) && $0.value == website }) {
            entry.fields.remove(at: index)
            return true
        }
        guard entry.url == website, let index = entry.fields.firstIndex(where: { $0.key == "URL" }) else { return false }
        // An account that had no website had no such field: put it back as it was.
        entry.fields.remove(at: index)
        return true
    }
}
