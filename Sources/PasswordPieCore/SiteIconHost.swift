import Foundation

/// Host used to fetch a site icon.
/// One leading `www` is removed, so `https://www.github.com/login` and `github.com` share an icon.
/// Subdomains stay, because `mail.google.com` and `google.com` are different sites.
public func websiteHost(forWebsite raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
    guard let url = URL(string: candidate),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          let parsed = url.host else { return nil }
    var host = parsed.lowercased()
    while host.hasSuffix(".") { host.removeLast() }
    if host.hasPrefix("www.") {
        let rest = String(host.dropFirst(4))
        if !rest.isEmpty { host = rest }
    }
    return host.isEmpty ? nil : host
}

/// The entry's website host. Only the website field is used, so a note titled `backup.zip` is not looked up.
public func websiteHost(of entry: VaultEntry) -> String? {
    websiteHost(forWebsite: entry.url)
}
