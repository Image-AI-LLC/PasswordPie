import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PasswordPieCore

final class SiteIconExchangeTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ url: String, title: String = "Account") -> VaultEntry {
        var entry = VaultEntry()
        entry.title = title
        entry.username = "me"
        entry.password = "pw"
        entry.url = url
        return entry
    }

    static func png(side: Int, padTo bytes: Int = 0) -> Data {
        let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        var out = data as Data
        if out.count < bytes { out.append(Data(count: bytes - out.count)) }
        return out
    }

    // MARK: Hosts

    func testLookupHostsGoFromTheHostToItsSite() {
        XCTAssertEqual(SiteIconRules.lookupHosts(forHost: "gist.github.com"), ["gist.github.com", "github.com"])
        XCTAssertEqual(SiteIconRules.lookupHosts(forHost: "GitHub.com"), ["github.com"])
        XCTAssertEqual(SiteIconRules.lookupHosts(forHost: "www.bbc.co.uk"), ["www.bbc.co.uk", "bbc.co.uk"])
        XCTAssertEqual(SiteIconRules.lookupHosts(forHost: "localhost"), [])
        XCTAssertEqual(SiteIconRules.lookupHosts(forHost: "printer.local"), [])
        XCTAssertEqual(SiteIconRules.lookupHosts(forHost: "../etc"), [])
        XCTAssertEqual(SiteIconRules.lookupHosts(forHost: nil), [])
    }

    func testPublicSitesOnly() {
        XCTAssertTrue(SiteIconRules.isPublicSite("github.com"))
        XCTAssertTrue(SiteIconRules.isPublicSite("mail.google.com"))
        for host in ["", "localhost", "192.168.1.1", "nas.lan", "router.home", "a.example", "git hub.com", "github..com", "x/y.com"] {
            XCTAssertFalse(SiteIconRules.isPublicSite(host), host)
        }
    }

    // MARK: Validation

    func testAcceptsASmallPNG() {
        XCTAssertTrue(SiteIconRules.isAcceptableIcon(Self.png(side: 64)))
        XCTAssertTrue(SiteIconRules.isAcceptableIcon(Self.png(side: 128)))
        XCTAssertTrue(SiteIconRules.isAcceptableIcon(Self.png(side: 16)))
    }

    func testRejectsOversizedOrNonImages() {
        XCTAssertFalse(SiteIconRules.isAcceptableIcon(Self.png(side: 129)), "too many pixels")
        XCTAssertFalse(SiteIconRules.isAcceptableIcon(Self.png(side: 32, padTo: SiteIconRules.maxBytes + 1)), "too many bytes")
        XCTAssertFalse(SiteIconRules.isAcceptableIcon(Data("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8)))
        XCTAssertFalse(SiteIconRules.isAcceptableIcon(Data()))
        var truncated = Self.png(side: 64)
        truncated.removeLast(truncated.count / 2)
        XCTAssertFalse(SiteIconRules.isAcceptableIcon(truncated), "a PNG header with no image behind it")
    }

    func testRejectsAnotherImageFormatDressedAsPNG() throws {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        CGImageDestinationFinalize(destination)
        XCTAssertFalse(SiteIconRules.isAcceptableIcon(data as Data))
    }

    // MARK: wantIcon

    func testAsksOnlyWhenTheSiteHasAnAccountWithoutAnIcon() {
        var ledger = SiteIconLedger()
        let entries = [entry("https://news.ycombinator.com/login"), entry("https://github.com")]
        XCTAssertTrue(ledger.shouldAsk(browser: .chrome, pageURL: "https://news.ycombinator.com/", entries: entries, hasIcon: { _ in false }, now: start))
        var other = SiteIconLedger()
        XCTAssertFalse(other.shouldAsk(browser: .chrome, pageURL: "https://example.org/", entries: entries, hasIcon: { _ in false }, now: start),
                       "no account on this site: the extension is told nothing")
        XCTAssertFalse(other.shouldAsk(browser: .chrome, pageURL: "https://github.com/", entries: entries, hasIcon: { _ in true }, now: start),
                       "the account already has an icon")
    }

    func testAnAccountOnAnotherHostOfTheSiteCounts() {
        var ledger = SiteIconLedger()
        var checked: [String] = []
        let asked = ledger.shouldAsk(browser: .safari, pageURL: "https://www.ycombinator.com/", entries: [entry("news.ycombinator.com")],
                                     hasIcon: { checked.append($0); return false }, now: start)
        XCTAssertTrue(asked)
        XCTAssertEqual(checked, ["news.ycombinator.com"])
    }

    func testTrashedAccountsAndPrivateSitesNeverAsk() {
        var ledger = SiteIconLedger()
        var trashed = entry("https://news.ycombinator.com")
        trashed.trashed = true
        XCTAssertFalse(ledger.shouldAsk(browser: .chrome, pageURL: "https://news.ycombinator.com/", entries: [trashed], hasIcon: { _ in false }, now: start))
        XCTAssertFalse(ledger.shouldAsk(browser: .chrome, pageURL: "http://localhost:3000/", entries: [entry("http://localhost:3000")], hasIcon: { _ in false }, now: start))
        XCTAssertFalse(ledger.shouldAsk(browser: .chrome, pageURL: "chrome://settings/", entries: [entry("https://news.ycombinator.com")], hasIcon: { _ in false }, now: start))
    }

    func testDoesNotAskTheSameSiteAgainForAWhile() {
        var ledger = SiteIconLedger()
        let entries = [entry("https://news.ycombinator.com")]
        XCTAssertTrue(ledger.shouldAsk(browser: .chrome, pageURL: "https://news.ycombinator.com/", entries: entries, hasIcon: { _ in false }, now: start))
        XCTAssertFalse(ledger.shouldAsk(browser: .chrome, pageURL: "https://news.ycombinator.com/", entries: entries, hasIcon: { _ in false }, now: start.addingTimeInterval(5)))
        XCTAssertTrue(ledger.shouldAsk(browser: .chrome, pageURL: "https://news.ycombinator.com/", entries: entries, hasIcon: { _ in false },
                                       now: start.addingTimeInterval(SiteIconLedger.askAgainAfter + 1)))
    }

    // MARK: icon request

    private func asked(_ origin: String = "https://news.ycombinator.com", browser: BridgeBrowser = .chrome) -> SiteIconLedger {
        var ledger = SiteIconLedger()
        XCTAssertTrue(ledger.shouldAsk(browser: browser, pageURL: origin + "/", entries: [entry(origin)], hasIcon: { _ in false }, now: start))
        return ledger
    }

    func testAcceptsTheIconItAskedFor() throws {
        var ledger = asked()
        let png = Self.png(side: 64)
        let delivery = try ledger.accept(browser: .chrome, origin: "https://news.ycombinator.com", png: png.base64EncodedString(), now: start.addingTimeInterval(2)).get()
        XCTAssertEqual(delivery.png, png)
        XCTAssertEqual(delivery.hosts, ["news.ycombinator.com", "ycombinator.com"])
    }

    func testTheHostLosesItsWww() throws {
        var ledger = asked("https://www.wolframalpha.com")
        let delivery = try ledger.accept(browser: .chrome, origin: "https://www.wolframalpha.com", png: Self.png(side: 32).base64EncodedString(), now: start).get()
        XCTAssertEqual(delivery.hosts, ["wolframalpha.com"])
    }

    func testRejectsAnOriginItDidNotAskFor() {
        var ledger = asked()
        let png = Self.png(side: 64).base64EncodedString()
        XCTAssertEqual(ledger.accept(browser: .chrome, origin: "https://evil.example.com", png: png, now: start).failure, .notAsked)
        XCTAssertEqual(ledger.accept(browser: .chrome, origin: "http://news.ycombinator.com", png: png, now: start).failure, .notAsked, "another scheme is another origin")
        XCTAssertEqual(ledger.accept(browser: .chrome, origin: "https://ycombinator.com", png: png, now: start).failure, .notAsked, "another host of the same site")
        XCTAssertEqual(ledger.accept(browser: .safari, origin: "https://news.ycombinator.com", png: png, now: start).failure, .notAsked, "asked Chrome, not Safari")
    }

    func testAnAnswerIsUsedOnceAndOnlySoon() {
        var ledger = asked()
        let png = Self.png(side: 64).base64EncodedString()
        XCTAssertNotNil(ledger.accept(browser: .chrome, origin: "https://news.ycombinator.com", png: png, now: start).success)
        XCTAssertEqual(ledger.accept(browser: .chrome, origin: "https://news.ycombinator.com", png: png, now: start).failure, .notAsked)

        var late = asked()
        XCTAssertEqual(late.accept(browser: .chrome, origin: "https://news.ycombinator.com", png: png,
                                   now: start.addingTimeInterval(SiteIconLedger.answerWindow + 1)).failure, .notAsked)
    }

    func testRejectsBadImages() {
        let origin = "https://news.ycombinator.com"
        var big = asked()
        XCTAssertEqual(big.accept(browser: .chrome, origin: origin, png: Self.png(side: 256).base64EncodedString(), now: start).failure, .notAnIcon)
        var heavy = asked()
        XCTAssertEqual(heavy.accept(browser: .chrome, origin: origin, png: Self.png(side: 32, padTo: 70_000).base64EncodedString(), now: start).failure, .notAnIcon)
        var text = asked()
        XCTAssertEqual(text.accept(browser: .chrome, origin: origin, png: Data("hello".utf8).base64EncodedString(), now: start).failure, .notAnIcon)
        var garbage = asked()
        XCTAssertEqual(garbage.accept(browser: .chrome, origin: origin, png: "%%% not base64 %%%", now: start).failure, .notAnIcon)
        // A rejected answer uses up the ask too.
        XCTAssertEqual(text.accept(browser: .chrome, origin: origin, png: Self.png(side: 32).base64EncodedString(), now: start).failure, .notAsked)
    }

    func testLockingForgetsTheAsks() {
        var ledger = asked()
        ledger.clear()
        XCTAssertEqual(ledger.accept(browser: .chrome, origin: "https://news.ycombinator.com", png: Self.png(side: 32).base64EncodedString(), now: start).failure, .notAsked)
    }

    // MARK: Messages

    func testTabAnswerCarriesWantIcon() throws {
        var response = BridgeResponse(type: "tab", id: 4)
        response.wantIcon = true
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(response), encoding: .utf8))
        XCTAssertTrue(json.contains("\"wantIcon\":true"), json)
        let plain = try XCTUnwrap(String(data: JSONEncoder().encode(BridgeResponse(type: "tab", id: 4)), encoding: .utf8))
        XCTAssertFalse(plain.contains("wantIcon"), plain)
    }

    func testDecodesTheIconRequest() throws {
        let frame = Data(#"{"type":"icon","id":7,"origin":"https://news.ycombinator.com","png":"iVBO"}"#.utf8)
        let request = try JSONDecoder().decode(BridgeIconRequest.self, from: frame)
        XCTAssertEqual(request.id, 7)
        XCTAssertEqual(request.origin, "https://news.ycombinator.com")
        XCTAssertEqual(request.png, "iVBO")
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }

    var success: Success? {
        if case .success(let value) = self { return value }
        return nil
    }
}
