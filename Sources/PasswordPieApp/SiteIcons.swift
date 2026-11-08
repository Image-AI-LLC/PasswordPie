import AppKit
import Combine
import CryptoKit
import ImageIO
import PasswordPieCore

/// Site icons, with no network. In order: the icons bundled for the top sites (`Contents/Resources/SiteIcons`, made by
/// `Scripts/fetch_site_icons.py`), then the ones the browser extension handed over, kept in the cache folder. A host with
/// neither keeps its letter tile. Each is looked up under the host, then under its registrable domain. docs/UX.md, "Site icons".
@MainActor
final class SiteIconStore: ObservableObject {
    static let shared = SiteIconStore(
        bundledDirectory: Bundle.main.resourceURL?.appendingPathComponent("SiteIcons", isDirectory: true),
        cacheDirectory: SiteIconStore.defaultCacheDirectory
    )

    /// Not in the database: writing icons there would change the user's KDBX file under every other KeePass app.
    private static var defaultCacheDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.oldcai.passwordpie", isDirectory: true)
            .appendingPathComponent("favicons", isDirectory: true)
    }

    /// Cached files written before icons came from the extension may be this large.
    static let maxCachedBytes = 262_144
    static let maxCachedPixels = 512

    /// Bumped when an icon arrives, so SwiftUI views redraw.
    @Published private(set) var revision = 0

    private let bundledDirectory: URL?
    private let cacheDirectory: URL?
    /// Every lookup, found or not, until an icon arrives.
    private var resolved: [String: NSImage?] = [:]
    private var observers: [ObjectIdentifier: ObserverBox] = [:]

    private final class ObserverBox {
        weak var owner: AnyObject?
        let body: () -> Void
        init(owner: AnyObject, body: @escaping () -> Void) {
            self.owner = owner
            self.body = body
        }
    }

    init(bundledDirectory: URL?, cacheDirectory: URL?) {
        self.bundledDirectory = bundledDirectory
        self.cacheDirectory = cacheDirectory
    }

    /// Cache file name for a public host. The host itself is not in the name, so a directory listing is not a site list.
    static func cacheFileName(forHost host: String) -> String? {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard SiteIconRules.isPublicSite(host) else { return nil }
        let digest = SHA256.hash(data: Data(host.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return hex + ".png"
    }

    /// The icon for `host`: bundled first, then cached, each for the host and then for its registrable domain.
    func image(forHost host: String?) -> NSImage? {
        let hosts = SiteIconRules.lookupHosts(forHost: host)
        guard let key = hosts.first else { return nil }
        if let known = resolved[key] { return known }
        let found = hosts.lazy.compactMap { self.bundled($0) }.first ?? hosts.lazy.compactMap { self.cached($0) }.first
        resolved[key] = .some(found)
        return found
    }

    func hasIcon(forHost host: String?) -> Bool {
        image(forHost: host) != nil
    }

    /// Redraw `owner` when an icon arrives. Replaces any earlier callback for the same owner.
    func observe(_ owner: AnyObject, _ body: @escaping () -> Void) {
        observers[ObjectIdentifier(owner)] = ObserverBox(owner: owner, body: body)
    }

    /// Keeps an icon from the extension: under the tab's host, and under its registrable domain when that has no icon yet,
    /// so every account on the site finds it. True when it was stored.
    @discardableResult
    func store(_ delivery: SiteIconDelivery) -> Bool {
        guard SiteIconRules.isAcceptableIcon(delivery.png), makeImage(delivery.png) != nil,
              let host = delivery.hosts.first else { return false }
        var targets = [host]
        for other in delivery.hosts.dropFirst() where !hasIcon(forHost: other) { targets.append(other) }
        var stored = false
        for target in targets where writeDisk(target, delivery.png) { stored = true }
        guard stored else { return false }
        resolved = [:]
        revision &+= 1
        observers = observers.filter { $0.value.owner != nil }
        for box in observers.values { box.body() }
        return true
    }

    // MARK: Files

    /// `<host>.png` (64 px) and `<host>@2x.png` (128 px). Only public DNS names reach here, so a host never walks out of
    /// the folder.
    private func bundled(_ host: String) -> NSImage? {
        guard let bundledDirectory else { return nil }
        let reps = ["", "@2x"].compactMap { suffix -> NSBitmapImageRep? in
            let file = bundledDirectory.appendingPathComponent(host + suffix + ".png")
            guard let data = try? Data(contentsOf: file) else { return nil }
            return NSBitmapImageRep(data: data)
        }
        guard !reps.isEmpty else { return nil }
        let image = NSImage(size: NSSize(width: 32, height: 32))
        for rep in reps {
            rep.size = image.size
            image.addRepresentation(rep)
        }
        return image
    }

    private func cached(_ host: String) -> NSImage? {
        guard let file = fileURL(host), let data = try? Data(contentsOf: file), (1...Self.maxCachedBytes).contains(data.count),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              (1...Self.maxCachedPixels).contains(width), (1...Self.maxCachedPixels).contains(height) else { return nil }
        return makeImage(data)
    }

    private func makeImage(_ data: Data) -> NSImage? {
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        return image
    }

    /// A public host caches under the hash of its name. `..` and other non-names never become a path.
    private func fileURL(_ host: String) -> URL? {
        guard let cacheDirectory, let name = Self.cacheFileName(forHost: host) else { return nil }
        return cacheDirectory.appendingPathComponent(name)
    }

    private func writeDisk(_ host: String, _ data: Data) -> Bool {
        guard let file = fileURL(host), !data.isEmpty else { return false }
        do {
            let directory = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return true
        } catch {
            NSLog("PasswordPie: could not cache a site icon (%@)", String(describing: error))
            return false
        }
    }
}
