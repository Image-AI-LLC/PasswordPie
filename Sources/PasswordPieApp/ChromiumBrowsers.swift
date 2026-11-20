import AppKit
import PasswordPieBridge

/// Browsers built on Chromium: Chrome, Edge, Brave, Arc, Vivaldi, ego lite and the rest. They all run the Chrome Web
/// Store extension and start the same native messaging host, so nothing here lists them: an app is one when its bundle
/// says so (`BrowserCrApplication`), and its profiles folder is found from the browser itself. See
/// docs/BROWSER_EXTENSION.md, "Other Chromium browsers".
enum ChromiumBrowsers {
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var known: [String: Bool] = [:]

        func value(_ bundleID: String, compute: () -> Bool?) -> Bool {
            lock.lock()
            if let value = known[bundleID] {
                lock.unlock()
                return value
            }
            lock.unlock()
            // Not cached when the app is not found: it may be installed later.
            guard let value = compute() else { return false }
            lock.lock()
            known[bundleID] = value
            lock.unlock()
            return value
        }

        func set(_ bundleID: String, _ value: Bool?) {
            lock.lock()
            known[bundleID] = value
            lock.unlock()
        }
    }

    private static let cache = Cache()

    /// True for Google Chrome, and for any installed app whose bundle says it is built on Chromium. Asked often (each time
    /// the panel opens), so each app's answer is kept.
    nonisolated static func isChromium(bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        if bundleID == BrowserBridge.chromeBundleID { return true }
        return cache.value(bundleID) {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map(isChromium(bundleURL:))
        }
    }

    nonisolated static func isChromium(bundleURL: URL) -> Bool {
        ChromiumBrowserCheck.isChromium(info: info(of: bundleURL))
    }

    /// Tests stand in an answer for an app that is not installed; nil goes back to asking the app.
    nonisolated static func assume(_ bundleID: String, isChromium: Bool?) {
        cache.set(bundleID, isChromium)
    }

    /// The Info.plist read from disk each time: `Bundle` keeps what it read first, and a browser updates in place.
    nonisolated static func info(of bundleURL: URL) -> [String: Any]? {
        let url = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    // MARK: Profiles folder

    /// The folders under `~/Library/Application Support` of browsers that do not name theirs in Info.plist. Chromium
    /// builds it in; a browser not here and without `CrProductDirName` is found while it runs (`runningFolder`).
    static let knownFolders: [String: String] = [
        "com.google.Chrome": "Google/Chrome",
        "com.google.Chrome.beta": "Google/Chrome Beta",
        "com.google.Chrome.dev": "Google/Chrome Dev",
        "com.google.Chrome.canary": "Google/Chrome Canary",
        "org.chromium.Chromium": "Chromium",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.microsoft.edgemac.Beta": "Microsoft Edge Beta",
        "com.microsoft.edgemac.Dev": "Microsoft Edge Dev",
        "com.microsoft.edgemac.Canary": "Microsoft Edge Canary",
        "com.brave.Browser": "BraveSoftware/Brave-Browser",
        "com.brave.Browser.beta": "BraveSoftware/Brave-Browser-Beta",
        "com.brave.Browser.nightly": "BraveSoftware/Brave-Browser-Nightly",
        "com.vivaldi.Vivaldi": "Vivaldi",
        "company.thebrowser.Browser": "Arc/User Data",
        "com.operasoftware.Opera": "com.operasoftware.Opera"
    ]

    static func supportFolder(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    /// Where the browser keeps its profiles, from its bundle: the `CrProductDirName` it names in Info.plist (ego lite:
    /// `Citro Labs/ego lite`), else the known folder for its bundle ID. Nil when neither says.
    static func folder(bundleID: String?, info: [String: Any]?, home: URL) -> URL? {
        let support = supportFolder(home: home)
        if let name = info?["CrProductDirName"] as? String, isRelativeName(name) {
            return support.appendingPathComponent(name, isDirectory: true)
        }
        if let bundleID, let known = knownFolders[bundleID] {
            return support.appendingPathComponent(known, isDirectory: true)
        }
        return nil
    }

    /// A folder name inside Application Support: not absolute, and never climbing out of it.
    private static func isRelativeName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("/") && !name.split(separator: "/").contains("..")
    }

    /// The profiles folder a running browser holds: Chromium keeps `SingletonLock` there, a symbolic link to
    /// `<host name>-<pid>`. Looked for up to three levels under Application Support.
    static func runningFolder(pid: pid_t, home: URL) -> URL? {
        let fileManager = FileManager.default
        var level = [supportFolder(home: home)]
        for _ in 0..<3 {
            var next: [URL] = []
            for folder in level {
                guard let children = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { continue }
                for child in children {
                    let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                    if locks(child, pid: pid) { return child }
                    next.append(child)
                }
            }
            level = next
        }
        return nil
    }

    static func locks(_ folder: URL, pid: pid_t) -> Bool {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: folder.appendingPathComponent("SingletonLock").path),
              let last = target.split(separator: "-").last else { return false }
        return last == "\(pid)"
    }

    /// The profiles folders of the browsers built on Chromium on this Mac that have been opened at least once: Google
    /// Chrome's, those of the installed browsers that say where theirs is, and those of the ones running now.
    static func folders(home: URL, installed: [URL], running: [(pid: pid_t, bundleURL: URL?)]) -> [URL] {
        var found: [URL] = [supportFolder(home: home).appendingPathComponent(knownFolders[BrowserBridge.chromeBundleID]!, isDirectory: true)]
        for app in installed {
            let info = info(of: app)
            guard ChromiumBrowserCheck.isChromium(info: info),
                  let folder = folder(bundleID: info?["CFBundleIdentifier"] as? String, info: info, home: home) else { continue }
            found.append(folder)
        }
        for app in running {
            guard let bundleURL = app.bundleURL, isChromium(bundleURL: bundleURL) else { continue }
            let info = info(of: bundleURL)
            if let folder = folder(bundleID: info?["CFBundleIdentifier"] as? String, info: info, home: home) ?? runningFolder(pid: app.pid, home: home) {
                found.append(folder)
            }
        }
        var seen = Set<String>()
        return found.filter { folder in
            let path = folder.standardizedFileURL.path
            guard seen.insert(path).inserted else { return false }
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
        }
    }

    /// Every app that opens web pages, as Launch Services knows them.
    static func installedBrowsers() -> [URL] {
        guard let page = URL(string: "https://passwordpie.com") else { return [] }
        return NSWorkspace.shared.urlsForApplications(toOpen: page)
    }

    static func runningApps() -> [(pid: pid_t, bundleURL: URL?)] {
        NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0.bundleURL) }
    }
}
