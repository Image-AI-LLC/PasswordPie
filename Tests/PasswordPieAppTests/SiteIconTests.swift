import AppKit
import PasswordPieCore
import XCTest
@testable import PasswordPie

@MainActor
final class SiteIconTests: XCTestCase {
    private var directory: URL!
    private var bundled: URL!
    private var cache: URL!
    /// The bridge holds its session unowned.
    private var session: VaultSession?

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("passwordpie-icons-\(UUID().uuidString)", isDirectory: true)
        bundled = directory.appendingPathComponent("SiteIcons", isDirectory: true)
        cache = directory.appendingPathComponent("favicons", isDirectory: true)
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        unsetenv("PASSWORDPIE_DB")
        unsetenv("PASSWORDPIE_USAGE")
        session = nil
        try? FileManager.default.removeItem(at: directory)
    }

    /// A square PNG of one color, so a test can tell which file an image came from.
    private func png(side: Int, red: CGFloat) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(deviceRed: red, green: 0, blue: 0, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    private func red(of image: NSImage?) -> CGFloat? {
        guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB)?.redComponent
    }

    private func store() -> SiteIconStore {
        SiteIconStore(bundledDirectory: bundled, cacheDirectory: cache)
    }

    private func writeBundled(_ host: String, red: CGFloat) throws {
        try png(side: 64, red: red).write(to: bundled.appendingPathComponent("\(host).png"))
        try png(side: 128, red: red).write(to: bundled.appendingPathComponent("\(host)@2x.png"))
    }

    private func writeCached(_ host: String, red: CGFloat) throws {
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let name = try XCTUnwrap(SiteIconStore.cacheFileName(forHost: host))
        try png(side: 64, red: red).write(to: cache.appendingPathComponent(name))
    }

    // MARK: Lookup order

    func testBundledIconHasBothResolutions() throws {
        try writeBundled("github.com", red: 1)
        let image = try XCTUnwrap(store().image(forHost: "github.com"))
        let widths = image.representations.map(\.pixelsWide).sorted()
        XCTAssertEqual(widths, [64, 128])
        XCTAssertEqual(image.size, NSSize(width: 32, height: 32))
    }

    func testBundledWinsOverCached() throws {
        try writeBundled("github.com", red: 1)
        try writeCached("github.com", red: 0)
        XCTAssertEqual(try XCTUnwrap(red(of: store().image(forHost: "github.com"))), 1, accuracy: 0.05)
    }

    func testCachedIsUsedWhenNothingIsBundled() throws {
        try writeCached("news.ycombinator.com", red: 0.5)
        XCTAssertEqual(try XCTUnwrap(red(of: store().image(forHost: "news.ycombinator.com"))), 0.5, accuracy: 0.15)
    }

    func testFallsBackToTheRegistrableDomain() throws {
        try writeBundled("github.com", red: 1)
        XCTAssertNotNil(store().image(forHost: "gist.github.com"))
        try writeCached("ycombinator.com", red: 0.5)
        XCTAssertNotNil(store().image(forHost: "news.ycombinator.com"))
    }

    func testABundledParentWinsOverACachedHost() throws {
        try writeBundled("github.com", red: 1)
        try writeCached("gist.github.com", red: 0)
        XCTAssertEqual(try XCTUnwrap(red(of: store().image(forHost: "gist.github.com"))), 1, accuracy: 0.05)
    }

    func testNothingFoundKeepsTheLetterTile() {
        XCTAssertNil(store().image(forHost: "news.ycombinator.com"))
        XCTAssertNil(store().image(forHost: nil))
        XCTAssertNil(store().image(forHost: "localhost"))
    }

    func testAPathLikeHostNeverReadsOutsideTheFolders() throws {
        try png(side: 64, red: 1).write(to: directory.appendingPathComponent("x.png"))
        XCTAssertNil(store().image(forHost: "../x"))
        XCTAssertNil(store().image(forHost: ".."))
        XCTAssertNil(SiteIconStore.cacheFileName(forHost: ".."))
    }

    // MARK: Icons from the extension

    func testAStoredIconIsCachedUnderAHashedNameForTheNextLaunch() throws {
        let icons = store()
        let png = png(side: 64, red: 0.5)
        XCTAssertTrue(icons.store(SiteIconDelivery(png: png, hosts: ["news.ycombinator.com", "ycombinator.com"])))
        XCTAssertNotNil(icons.image(forHost: "news.ycombinator.com"))

        let name = try XCTUnwrap(SiteIconStore.cacheFileName(forHost: "news.ycombinator.com"))
        XCTAssertFalse(name.contains("ycombinator"))
        XCTAssertEqual(try Data(contentsOf: cache.appendingPathComponent(name)), png)
        let siteName = try XCTUnwrap(SiteIconStore.cacheFileName(forHost: "ycombinator.com"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.appendingPathComponent(siteName).path), "the site gets it too")
        let fileMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: cache.appendingPathComponent(name).path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(fileMode.uint16Value, 0o600)
        let directoryMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: cache.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(directoryMode.uint16Value, 0o700)

        XCTAssertNotNil(store().image(forHost: "news.ycombinator.com"), "a fresh store reads it from disk")
        XCTAssertNotNil(store().image(forHost: "hn.ycombinator.com"), "another host of the site falls back to it")
    }

    func testAStoredIconDoesNotReplaceTheSitesBundledOne() throws {
        try writeBundled("google.com", red: 1)
        let icons = store()
        XCTAssertTrue(icons.store(SiteIconDelivery(png: png(side: 64, red: 0), hosts: ["accounts.google.com", "google.com"])))
        let siteName = try XCTUnwrap(SiteIconStore.cacheFileName(forHost: "google.com"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathComponent(siteName).path))
    }

    func testAStoredIconRedrawsTheListAndReplacesAMiss() {
        let icons = store()
        XCTAssertNil(icons.image(forHost: "news.ycombinator.com"))
        var redraws = 0
        let owner = NSObject()
        icons.observe(owner) { redraws += 1 }
        let revision = icons.revision
        icons.store(SiteIconDelivery(png: png(side: 64, red: 0.5), hosts: ["news.ycombinator.com"]))
        XCTAssertEqual(redraws, 1)
        XCTAssertGreaterThan(icons.revision, revision)
        XCTAssertNotNil(icons.image(forHost: "news.ycombinator.com"), "the remembered miss is forgotten")
    }

    func testStoreRefusesWhatIsNotAnIcon() {
        let icons = store()
        XCTAssertFalse(icons.store(SiteIconDelivery(png: Data("nope".utf8), hosts: ["news.ycombinator.com"])))
        XCTAssertFalse(icons.store(SiteIconDelivery(png: png(side: 256, red: 1), hosts: ["news.ycombinator.com"])))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
    }

    // MARK: Through the bridge

    private func unlockedBridge(with websites: [String]) -> (BrowserBridge, VaultSession) {
        setenv("PASSWORDPIE_DB", directory.appendingPathComponent("test.kdbx").path, 1)
        setenv("PASSWORDPIE_USAGE", directory.appendingPathComponent("usage.json").path, 1)
        let session = VaultSession()
        session.restore()
        session.passwordDraft = "pw"
        session.confirmDraft = "pw"
        session.unlock()
        for website in websites {
            var entry = VaultEntry()
            entry.title = website
            entry.url = website
            entry.username = "me"
            session.saveEditing(entry)
        }
        self.session = session
        let bridge = BrowserBridge(session: session)
        let icons = store()
        bridge.icons = { icons }
        return (bridge, session)
    }

    private func send(_ bridge: BrowserBridge, _ object: [String: Any], from browser: BridgeBrowser = .chrome) throws -> [String: Any] {
        let frame = try JSONSerialization.data(withJSONObject: object)
        let answer = try XCTUnwrap(bridge.answer(frame, from: browser))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: answer) as? [String: Any])
    }

    func testTabAnswerAsksForAMissingIconAndTakesIt() throws {
        let (bridge, _) = unlockedBridge(with: ["https://news.ycombinator.com/login"])
        let tab = try send(bridge, ["type": "tab", "id": 1, "url": "https://news.ycombinator.com/", "reason": "activated"])
        XCTAssertEqual(tab["wantIcon"] as? Bool, true)

        let icon = try send(bridge, ["type": "icon", "id": 2, "origin": "https://news.ycombinator.com", "png": png(side: 64, red: 0.5).base64EncodedString()])
        XCTAssertEqual(icon["type"] as? String, "icon")
        XCTAssertEqual(icon["id"] as? Int, 2)
        XCTAssertNotNil(bridge.icons().image(forHost: "news.ycombinator.com"))

        let again = try send(bridge, ["type": "tab", "id": 3, "url": "https://news.ycombinator.com/", "reason": "activated"])
        XCTAssertNil(again["wantIcon"], "it has the icon now")
    }

    func testTabAnswerNeverAsksWithoutAnAccountOrWithAnIcon() throws {
        try writeBundled("github.com", red: 1)
        let (bridge, _) = unlockedBridge(with: ["https://github.com"])
        XCTAssertNil(try send(bridge, ["type": "tab", "id": 1, "url": "https://github.com/", "reason": "activated"])["wantIcon"])
        XCTAssertNil(try send(bridge, ["type": "tab", "id": 2, "url": "https://example.org/", "reason": "activated"])["wantIcon"])
    }

    func testLockedNeverAsks() throws {
        let (bridge, session) = unlockedBridge(with: ["https://news.ycombinator.com"])
        session.lock()
        XCTAssertNil(try send(bridge, ["type": "tab", "id": 1, "url": "https://news.ycombinator.com/", "reason": "activated"])["wantIcon"])
    }

    func testIconRequestsAreRefusedUnlessAskedForThatOriginAndValid() throws {
        let (bridge, _) = unlockedBridge(with: ["https://news.ycombinator.com"])
        let good = png(side: 64, red: 0.5).base64EncodedString()

        let unasked = try send(bridge, ["type": "icon", "id": 1, "origin": "https://news.ycombinator.com", "png": good])
        XCTAssertEqual(unasked["type"] as? String, "error")
        XCTAssertEqual(unasked["code"] as? String, "bad-icon")

        _ = try send(bridge, ["type": "tab", "id": 2, "url": "https://news.ycombinator.com/", "reason": "activated"])
        let elsewhere = try send(bridge, ["type": "icon", "id": 3, "origin": "https://evil.example.org", "png": good])
        XCTAssertEqual(elsewhere["code"] as? String, "bad-icon")
        let fromSafari = try send(bridge, ["type": "icon", "id": 4, "origin": "https://news.ycombinator.com", "png": good], from: .safari)
        XCTAssertEqual(fromSafari["code"] as? String, "bad-icon")
        let tooBig = try send(bridge, ["type": "icon", "id": 5, "origin": "https://news.ycombinator.com", "png": png(side: 512, red: 1).base64EncodedString()])
        XCTAssertEqual(tooBig["code"] as? String, "bad-icon")
        XCTAssertNil(bridge.icons().image(forHost: "news.ycombinator.com"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
    }
}
