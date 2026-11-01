import AppKit
import ImageIO

/// Google's public favicon service. `https://www.google.com/s2/favicons?domain=…&sz=64`
/// redirects to `faviconV2`. An unknown site comes back as HTTP 404 with a generic globe, so only 200 is an icon.
enum GoogleFavicon {
    static let pixelSize = 64

    /// A public DNS name. Local and private names stay on the letter tile: Google has no icon for them, and the query would publish the vault's internal hosts.
    static func isPublicSite(_ host: String) -> Bool {
        guard !host.isEmpty, host.contains(".") else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy(isDNSLabel) else { return false }
        if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return false }
        let blocked = [
            "local", "localhost", "localdomain", "home.arpa", "internal", "lan", "intranet",
            "invalid", "test", "onion", "home", "corp",
        ]
        return !blocked.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static func isDNSLabel(_ label: Substring) -> Bool {
        guard (1...63).contains(label.count), label.first != "-", label.last != "-" else { return false }
        return label.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "-")
        }
    }

    static func requestURL(forHost host: String) -> URL? {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isPublicSite(host) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.google.com"
        components.path = "/s2/favicons"
        components.queryItems = [
            URLQueryItem(name: "domain", value: host),
            URLQueryItem(name: "sz", value: String(pixelSize)),
        ]
        return components.url
    }

    /// PNG (or other bitmap) bytes when Google has an icon. Nil for the 404 globe and for anything that is not an image.
    static func imageData(status: Int, body: Data) -> Data? {
        guard status == 200, !body.isEmpty else { return nil }
        guard let source = CGImageSourceCreateWithData(body as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { return nil }
        return body
    }
}

private enum FaviconHTTP {
    /// Ephemeral, and it neither sends nor stores cookies. The shared cookie jar can hold a Google login, which would tie these domain lookups to that account.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        config.waitsForConnectivity = false
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }()

    static func fetch(_ url: URL) async throws -> (Int, Data) {
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, data)
    }
}

/// Fetches site icons and keeps them in memory, with a disk cache for the next launch.
/// A miss keeps the letter tile. Network failures are remembered for this session so a menu redraw does not retry immediately.
@MainActor
final class SiteIconStore {
    static let shared = SiteIconStore(
        fetch: FaviconHTTP.fetch,
        cacheDirectory: SiteIconStore.defaultCacheDirectory,
        allowsNetwork: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    )

    private static var defaultCacheDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.oldcai.passwordpie", isDirectory: true)
            .appendingPathComponent("favicons", isDirectory: true)
    }

    private let fetch: (URL) async throws -> (Int, Data)
    private let cacheDirectory: URL?
    private let allowsNetwork: Bool
    private let maxActive: Int
    private var images: [String: NSImage] = [:]
    private var missing: Set<String> = []
    private var loading: Set<String> = []
    private var queued: Set<String> = []
    private var queue: [String] = []
    private var active = 0
    private var waiters: [String: [() -> Void]] = [:]
    private var observers: [ObjectIdentifier: ObserverBox] = [:]

    private final class ObserverBox {
        weak var owner: AnyObject?
        let body: () -> Void
        init(owner: AnyObject, body: @escaping () -> Void) {
            self.owner = owner
            self.body = body
        }
    }

    private enum Outcome {
        case image(Data)
        case absent
        case failed
    }

    init(fetch: @escaping (URL) async throws -> (Int, Data), cacheDirectory: URL?, allowsNetwork: Bool = true, maxActive: Int = 6) {
        self.fetch = fetch
        self.cacheDirectory = cacheDirectory
        self.allowsNetwork = allowsNetwork
        self.maxActive = max(1, maxActive)
    }

    func image(forHost host: String?) -> NSImage? {
        guard let host = normalize(host) else { return nil }
        return images[host]
    }

    /// Redraw `owner` when an icon arrives. Replaces any earlier callback for the same owner.
    func observe(_ owner: AnyObject, _ body: @escaping () -> Void) {
        observers[ObjectIdentifier(owner)] = ObserverBox(owner: owner, body: body)
    }

    /// Load icons for `hosts`. `visible` is read from disk before the view draws, so a cached icon does not flash the letter tile.
    func prepare(_ hosts: [String], visible: [String] = []) {
        for host in visible { warm(normalize(host)) }
        guard allowsNetwork else { return }
        for host in hosts { enqueue(normalize(host)) }
    }

    func load(_ host: String?) async -> NSImage? {
        guard let host = normalize(host) else { return nil }
        if let image = images[host] { return image }
        if missing.contains(host) || !allowsNetwork { return nil }
        warm(host)
        if let image = images[host] { return image }
        return await withCheckedContinuation { continuation in
            waiters[host, default: []].append { [weak self] in
                continuation.resume(returning: self?.images[host])
            }
            enqueue(host)
        }
    }

    private func normalize(_ host: String?) -> String? {
        guard let host else { return nil }
        let cleaned = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return cleaned.isEmpty ? nil : cleaned
    }

    private func warm(_ host: String?) {
        guard let host, images[host] == nil, !missing.contains(host) else { return }
        guard let data = readDisk(host), let image = makeImage(data) else { return }
        images[host] = image
    }

    private func enqueue(_ host: String?) {
        guard let host else { return }
        if images[host] != nil || missing.contains(host) || loading.contains(host) || queued.contains(host) {
            if images[host] != nil || missing.contains(host) { flush(host) }
            return
        }
        queued.insert(host)
        queue.append(host)
        pump()
    }

    private func pump() {
        while active < maxActive, !queue.isEmpty {
            let host = queue.removeFirst()
            queued.remove(host)
            guard images[host] == nil, !missing.contains(host), !loading.contains(host) else {
                flush(host)
                continue
            }
            loading.insert(host)
            active += 1
            Task { await self.run(host) }
        }
    }

    private func run(_ host: String) async {
        let outcome = await retrieve(host)
        finish(host, outcome)
    }

    private func retrieve(_ host: String) async -> Outcome {
        if let data = readDisk(host) { return .image(data) }
        guard let url = GoogleFavicon.requestURL(forHost: host) else { return .absent }
        do {
            let (status, data) = try await fetch(url)
            guard let image = GoogleFavicon.imageData(status: status, body: data) else { return .absent }
            writeDisk(host, image)
            return .image(image)
        } catch {
            return .failed
        }
    }

    private func finish(_ host: String, _ outcome: Outcome) {
        active -= 1
        loading.remove(host)
        var stored = false
        switch outcome {
        case .image(let data):
            if let image = makeImage(data) {
                images[host] = image
                stored = true
            } else {
                missing.insert(host)
            }
        case .absent, .failed:
            missing.insert(host)
        }
        flush(host)
        if stored { publish() }
        pump()
    }

    private func flush(_ host: String) {
        let callbacks = waiters.removeValue(forKey: host) ?? []
        callbacks.forEach { $0() }
    }

    private func publish() {
        observers = observers.filter { $0.value.owner != nil }
        for box in observers.values { box.body() }
    }

    private func makeImage(_ data: Data) -> NSImage? {
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        return image
    }

    /// Only a dotted hostname is a cache file name. Anything else stays in memory, so `..` cannot escape the cache directory.
    private func fileURL(_ host: String) -> URL? {
        guard let cacheDirectory else { return nil }
        guard host.range(of: #"^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?)*$"#, options: .regularExpression) != nil else {
            return nil
        }
        return cacheDirectory.appendingPathComponent(host).appendingPathExtension("png")
    }

    private func readDisk(_ host: String) -> Data? {
        guard let file = fileURL(host) else { return nil }
        return try? Data(contentsOf: file)
    }

    private func writeDisk(_ host: String, _ data: Data) {
        guard let file = fileURL(host), !data.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            // The icon is already in memory. A cache miss on the next launch just fetches it again.
        }
    }
}
