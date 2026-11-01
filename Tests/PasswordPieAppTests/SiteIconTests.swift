import AppKit
import PasswordPieCore
import XCTest
@testable import PasswordPie

@MainActor
final class SiteIconTests: XCTestCase {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    private actor Probe {
        var count = 0
        var urls: [URL] = []
        var status = 200
        var body = Data()
        var thrown: Error?

        func set(status: Int, body: Data, thrown: Error? = nil) {
            self.status = status
            self.body = body
            self.thrown = thrown
        }

        func call(_ url: URL) async throws -> (Int, Data) {
            count += 1
            urls.append(url)
            if let thrown { throw thrown }
            return (status, body)
        }
    }

    private actor Inflight {
        private(set) var current = 0
        private(set) var maxSeen = 0
        func enter() {
            current += 1
            maxSeen = max(maxSeen, current)
        }
        func leave() { current -= 1 }
    }

    func testRequestUsesGooglesFaviconService() throws {
        let url = try XCTUnwrap(GoogleFavicon.requestURL(forHost: "GitHub.com"))
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.scheme, "https")
        XCTAssertEqual(parts.host, "www.google.com")
        XCTAssertEqual(parts.path, "/s2/favicons")
        let items = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(items["domain"], "github.com")
        XCTAssertEqual(items["sz"], "64")
        XCTAssertNil(GoogleFavicon.requestURL(forHost: " "))
        XCTAssertNil(GoogleFavicon.requestURL(forHost: "github.com/login"))
    }

    func testPrivateHostsAreNotSentToGoogle() {
        for host in ["localhost", "printer", "127.0.0.1", "10.1.2.3", "192.168.1.1", "172.16.0.1", "169.254.1.1", "nas.local", "router.lan", "db.internal", "home.arpa", "::1"] {
            XCTAssertNil(GoogleFavicon.requestURL(forHost: host), host)
        }
        XCTAssertNotNil(GoogleFavicon.requestURL(forHost: "github.com"))
        XCTAssertNotNil(GoogleFavicon.requestURL(forHost: "mail.google.com"))
        XCTAssertNil(GoogleFavicon.requestURL(forHost: "git hub.com"))
        XCTAssertNil(GoogleFavicon.requestURL(forHost: "github..com"))
    }

    func testANetworkFailureRetriesAfterThePause() async {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var time = start
        let probe = Probe()
        await probe.set(status: 503, body: Data())
        let store = SiteIconStore(
            fetch: { try await probe.call($0) },
            cacheDirectory: nil,
            now: { time },
            initialRetry: 30
        )
        let first = await store.load("github.com")
        XCTAssertNil(first)
        time = start.addingTimeInterval(29)
        let early = await store.load("github.com")
        XCTAssertNil(early)
        var count = await probe.count
        XCTAssertEqual(count, 1)

        time = start.addingTimeInterval(30)
        let second = await store.load("github.com")
        XCTAssertNil(second)
        count = await probe.count
        XCTAssertEqual(count, 2)

        time = start.addingTimeInterval(89)
        let stillWaiting = await store.load("github.com")
        XCTAssertNil(stillWaiting)
        count = await probe.count
        XCTAssertEqual(count, 2)

        time = start.addingTimeInterval(90)
        await probe.set(status: 200, body: png)
        let image = await store.load("github.com")
        XCTAssertNotNil(image)
        count = await probe.count
        XCTAssertEqual(count, 3)
    }

    func testOnlyTheOpenListAsksForIcons() {
        let hidden = MenuRow(kind: .entry(UUID()), title: "GitHub", siteHost: "github.com")
        let folder = MenuRow(kind: .submenu, title: "Work", children: [hidden])
        let shown = MenuRow(kind: .entry(UUID()), title: "Apple", siteHost: "apple.com")
        XCTAssertEqual(MenuListView.visibleSiteHosts(in: [folder, shown]), ["apple.com"])
    }

    func testAPrivateHostIsNotFetched() async {
        let probe = Probe()
        await probe.set(status: 200, body: png)
        let store = SiteIconStore(fetch: { try await probe.call($0) }, cacheDirectory: nil)
        store.prepare(["localhost", "10.0.0.1", "nas.local"])
        let image = await store.load("localhost")
        XCTAssertNil(image)
        let count = await probe.count
        XCTAssertEqual(count, 0)
    }

    func testAStoreThatCannotUseTheNetworkDoesNotFetch() async {
        let probe = Probe()
        await probe.set(status: 200, body: png)
        let store = SiteIconStore(fetch: { try await probe.call($0) }, cacheDirectory: nil, allowsNetwork: false)
        store.prepare(["github.com"], visible: ["github.com"])
        let image = await store.load("github.com")
        XCTAssertNil(image)
        let count = await probe.count
        XCTAssertEqual(count, 0)
    }

    func testOnlyARealBitmapIsAnIcon() {
        XCTAssertEqual(GoogleFavicon.imageData(status: 200, body: png), png)
        XCTAssertNil(GoogleFavicon.imageData(status: 404, body: png))
        XCTAssertNil(GoogleFavicon.imageData(status: 200, body: Data("nope".utf8)))
        XCTAssertNil(GoogleFavicon.imageData(status: 200, body: Data()))
    }

    func testARealIconIsCachedAndAMissIsNotFetchedAgain() async {
        let probe = Probe()
        await probe.set(status: 200, body: png)
        let store = SiteIconStore(fetch: { try await probe.call($0) }, cacheDirectory: nil)
        let image = await store.load("github.com")
        XCTAssertNotNil(image)
        XCTAssertNotNil(store.image(forHost: "github.com"))
        let again = await store.load("github.com")
        XCTAssertNotNil(again)
        let countAfterHit = await probe.count
        XCTAssertEqual(countAfterHit, 1)

        await probe.set(status: 404, body: png)
        let missing = await store.load("missing.example")
        XCTAssertNil(missing)
        let missingAgain = await store.load("missing.example")
        XCTAssertNil(missingAgain)
        let countAfterMiss = await probe.count
        XCTAssertEqual(countAfterMiss, 2)

        await probe.set(status: 200, body: png, thrown: URLError(.notConnectedToInternet))
        let offline = await store.load("offline.example")
        XCTAssertNil(offline)
        let offlineAgain = await store.load("offline.example")
        XCTAssertNil(offlineAgain)
        let countAfterFailure = await probe.count
        XCTAssertEqual(countAfterFailure, 3)
    }

    func testTwoWaitersShareOneLookup() async throws {
        let probe = Probe()
        await probe.set(status: 200, body: png)
        let store = SiteIconStore(fetch: { url in
            try await Task.sleep(nanoseconds: 30_000_000)
            return try await probe.call(url)
        }, cacheDirectory: nil)
        async let first = store.load("github.com")
        async let second = store.load("github.com")
        let (a, b) = await (first, second)
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        let count = await probe.count
        XCTAssertEqual(count, 1)
        let urls = await probe.urls
        let url = try XCTUnwrap(urls.first)
        XCTAssertFalse(url.absoluteString.contains("secret"))
        XCTAssertTrue(url.query?.contains("domain=github.com") == true)
    }

    func testAtMostSixLookupsRunAtOnce() async {
        let gate = Inflight()
        let png = png
        let store = SiteIconStore(fetch: { _ in
            await gate.enter()
            try await Task.sleep(nanoseconds: 80_000_000)
            await gate.leave()
            return (200, png)
        }, cacheDirectory: nil, maxActive: 6)
        let hosts = (0..<8).map { "site\($0).example" }
        await withTaskGroup(of: NSImage?.self) { group in
            for host in hosts {
                group.addTask { await store.load(host) }
            }
            for await image in group {
                XCTAssertNotNil(image)
            }
        }
        let maxSeen = await gate.maxSeen
        XCTAssertLessThanOrEqual(maxSeen, 6)
        XCTAssertGreaterThan(maxSeen, 1)
    }

    func testACachedFileIsUsedWithoutAFetch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("passwordpie-favicons-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = try XCTUnwrap(SiteIconStore.cacheFileName(forHost: "github.com"))
        try png.write(to: directory.appendingPathComponent(name))
        let probe = Probe()
        await probe.set(status: 500, body: Data())
        let store = SiteIconStore(fetch: { try await probe.call($0) }, cacheDirectory: directory)
        store.prepare(["github.com"], visible: ["github.com"])
        XCTAssertNotNil(store.image(forHost: "github.com"))
        let loaded = await store.load("github.com")
        XCTAssertNotNil(loaded)
        let count = await probe.count
        XCTAssertEqual(count, 0)
    }

    func testAFetchedIconIsWrittenForTheNextLaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("passwordpie-favicons-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = Probe()
        await probe.set(status: 200, body: png)
        let store = SiteIconStore(fetch: { try await probe.call($0) }, cacheDirectory: directory)
        let image = await store.load("github.com")
        XCTAssertNotNil(image)
        let name = try XCTUnwrap(SiteIconStore.cacheFileName(forHost: "github.com"))
        XCTAssertFalse(name.contains("github"))
        let saved = try Data(contentsOf: directory.appendingPathComponent(name))
        XCTAssertEqual(saved, png)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("github.com.png").path))
        let fileMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(fileMode.uint16Value, 0o600)
        let directoryMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(directoryMode.uint16Value, 0o700)

        let short = await store.load("a.io")
        XCTAssertNotNil(short)
        let shortName = try XCTUnwrap(SiteIconStore.cacheFileName(forHost: "a.io"))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(shortName)), png)

        let next = SiteIconStore(fetch: { _ in throw URLError(.cancelled) }, cacheDirectory: directory)
        next.prepare(["github.com"], visible: ["github.com"])
        XCTAssertNotNil(next.image(forHost: "github.com"))
    }

    func testAPathLikeHostIsNotACacheFile() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("passwordpie-favicons-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = Probe()
        await probe.set(status: 200, body: png)
        let store = SiteIconStore(fetch: { try await probe.call($0) }, cacheDirectory: directory)
        let image = await store.load("..")
        XCTAssertNil(image)
        let count = await probe.count
        XCTAssertEqual(count, 0)
        var isDirectory: ObjCBool = false
        let escaped = directory.deletingLastPathComponent().appendingPathComponent("..png")
        XCTAssertFalse(FileManager.default.fileExists(atPath: escaped.path, isDirectory: &isDirectory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("..png").path))
    }
}
