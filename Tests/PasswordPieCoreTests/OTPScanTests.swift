import CoreImage
import Foundation
import XCTest
@testable import PasswordPieCore

final class OTPAuthParsingTests: XCTestCase {
    private let demo = "otpauth://totp/Demo:ada?secret=JBSWY3DPEHPK3PXP&issuer=Demo"

    // MARK: Stored entries (`TOTP.parseOTPAuth`)

    func testARepeatedParameterTakesTheFirstValueInsteadOfCrashing() {
        let settings = TOTP.parseOTPAuth("otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&secret=AAAAAAAA&digits=8&digits=6")
        XCTAssertEqual(settings?.secret, TOTP.base32Decode("JBSWY3DPEHPK3PXP"))
        XCTAssertEqual(settings?.digits, 8)
    }

    func testAStoredHOTPLinkIsNotATimeCode() {
        XCTAssertNil(TOTP.parseOTPAuth("otpauth://hotp/Demo:ada?secret=JBSWY3DPEHPK3PXP&counter=1"))
        XCTAssertNil(TOTP.parseOTPAuth("otpauth://?secret=JBSWY3DPEHPK3PXP"))
        XCTAssertNotNil(TOTP.parseOTPAuth("otpauth://TOTP/Demo:ada?secret=JBSWY3DPEHPK3PXP"))
    }

    func testAStoredEntryWithAnHOTPLinkHasNoCode() {
        var entry = VaultEntry()
        entry.otp = "otpauth://hotp/Demo:ada?secret=JBSWY3DPEHPK3PXP&counter=1"
        XCTAssertFalse(OneTimeCodes.hasCode(entry))
    }

    // MARK: Scanned input (`OTPAuthImport.parse`)

    func testAGoodLinkGivesItsIssuerAccountAndSettings() throws {
        let scan = try OTPAuthImport.parse(demo).get()
        XCTAssertEqual(scan.issuer, "Demo")
        XCTAssertEqual(scan.account, "ada")
        XCTAssertEqual(scan.settings, OTPSettings(secret: TOTP.base32Decode("JBSWY3DPEHPK3PXP")!))
        XCTAssertEqual(scan.uri, "otpauth://totp/Demo:ada?secret=JBSWY3DPEHPK3PXP&issuer=Demo&period=30&digits=6")
    }

    func testTheNormalizedLinkParsesBackToTheSameSettings() throws {
        let raw = "otpauth://totp/ACME%20Co:jane%40acme.com?SECRET=jbsw%20y3dp%20ehpk%203pxp====&algorithm=sha256&digits=8&period=60"
        let scan = try OTPAuthImport.parse(raw).get()
        XCTAssertEqual(scan.issuer, "ACME Co")
        XCTAssertEqual(scan.account, "jane@acme.com")
        XCTAssertEqual(scan.settings, OTPSettings(secret: TOTP.base32Decode("JBSWY3DPEHPK3PXP")!, digits: 8, period: 60, algorithm: .sha256))
        XCTAssertEqual(TOTP.parseOTPAuth(scan.uri), scan.settings)
        XCTAssertEqual(try OTPAuthImport.parse(scan.uri).get(), scan)
    }

    func testTheIssuerParameterWinsOverTheLabelPrefix() throws {
        let scan = try OTPAuthImport.parse("otpauth://totp/Old:ada?secret=JBSWY3DPEHPK3PXP&issuer=New").get()
        XCTAssertEqual(scan.issuer, "New")
        XCTAssertEqual(scan.account, "ada")
        let bare = try OTPAuthImport.parse("otpauth://totp/ada?secret=JBSWY3DPEHPK3PXP").get()
        XCTAssertEqual(bare.issuer, "")
        XCTAssertEqual(bare.account, "ada")
        XCTAssertEqual(bare.uri, "otpauth://totp/ada?secret=JBSWY3DPEHPK3PXP&period=30&digits=6")
    }

    func testRepeatedScanParametersTakeTheFirst() throws {
        let scan = try OTPAuthImport.parse("otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&secret=GEZDGNBV&issuer=A&issuer=B").get()
        XCTAssertEqual(scan.settings.secret, TOTP.base32Decode("JBSWY3DPEHPK3PXP"))
        XCTAssertEqual(scan.issuer, "A")
    }

    func testEachRefusalHasItsOwnReason() {
        let cases: [(String, OTPImportError)] = [
            ("hello world", .notOTPAuth),
            ("https://example.com/?secret=JBSWY3DPEHPK3PXP", .notOTPAuth),
            ("otpauth://hotp/Demo:ada?secret=JBSWY3DPEHPK3PXP&counter=0", .hotp),
            ("otpauth://steam/x?secret=JBSWY3DPEHPK3PXP", .notOTPAuth),
            ("otpauth-migration://offline?data=CjEKCkhlbGxvId6tvu8SBXRlc3QxGgZJc3N1ZXIgASgBMAIQARgBIAA%3D", .migration),
            ("otpauth://totp/x", .badSecret),
            ("otpauth://totp/x?secret=", .badSecret),
            ("otpauth://totp/x?secret=JBSWY3DP1HPK", .badSecret),
            ("otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&digits=5", .digits("5")),
            ("otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&digits=9", .digits("9")),
            ("otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&digits=six", .digits("six")),
            ("otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&period=0", .period("0")),
            ("otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&period=-30", .period("-30")),
            ("otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&period=soon", .period("soon")),
            ("otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&algorithm=MD5", .algorithm("MD5")),
            ("otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&algorithm=", .algorithm("")),
        ]
        for (raw, expected) in cases {
            switch OTPAuthImport.parse(raw) {
            case .success: XCTFail("accepted \(raw)")
            case .failure(let error): XCTAssertEqual(error, expected, raw)
            }
        }
    }

    func testTheEdgesOfDigitsAndPeriodAreAccepted() throws {
        for digits in [6, 7, 8] {
            XCTAssertEqual(try OTPAuthImport.parse("otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&digits=\(digits)").get().settings.digits, digits)
        }
        XCTAssertEqual(try OTPAuthImport.parse("otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&period=1").get().settings.period, 1)
        XCTAssertEqual(try OTPAuthImport.parse("otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&algorithm=SHA512").get().settings.algorithm, .sha512)
    }

    func testEveryRefusalSaysWhyInOneSentence() {
        let errors: [OTPImportError] = [.notOTPAuth, .hotp, .migration, .badSecret, .digits("9"), .period("0"), .algorithm("MD5")]
        for error in errors {
            XCTAssertFalse(error.message.isEmpty)
            XCTAssertTrue(error.message.hasSuffix("."), error.message)
        }
        XCTAssertTrue(OTPImportError.algorithm("MD5").message.contains("MD5"))
        XCTAssertTrue(OTPImportError.digits("9").message.contains("9"))
        XCTAssertEqual(Set(errors.map(\.message)).count, errors.count)
    }
}

final class OTPScanMatchTests: XCTestCase {
    private func entry(_ title: String, user: String, url: String = "", trashed: Bool = false) -> VaultEntry {
        var entry = VaultEntry(trashed: trashed)
        entry.title = title
        entry.username = user
        entry.url = url
        return entry
    }

    func testTheSameSiteComesFirstAndTheAccountFirstInsideIt() {
        let other = entry("GitHub", user: "ada", url: "https://github.com")
        let siteOnly = entry("Demo work", user: "bob", url: "https://demo.example.com/login")
        let exact = entry("Demo", user: "Ada", url: "https://www.example.com")
        let trashed = entry("Demo old", user: "ada", url: "https://example.com", trashed: true)
        let ranked = OTPScanMatch.candidates(in: [other, siteOnly, exact, trashed], issuer: "Demo", account: "ada", pageURL: "https://example.com/2fa/setup")
        XCTAssertEqual(ranked.map(\.id), [exact.id, siteOnly.id])
    }

    func testAnotherWebsiteOfTheItemCountsForTheSite() {
        var merged = entry("Shop", user: "ada", url: "https://shop.test")
        merged.fields.append(VaultField(key: "URL (2)", value: "https://example.com"))
        let ranked = OTPScanMatch.candidates(in: [merged], issuer: "", account: "ada", pageURL: "https://example.com")
        XCTAssertEqual(ranked.map(\.id), [merged.id])
    }

    func testWithoutAPageTheIssuerFindsItems() {
        let byTitle = entry("demo", user: "x")
        let byHost = entry("Work", user: "ada", url: "https://login.demo.io")
        let unrelated = entry("Other", user: "ada", url: "https://other.io")
        let ranked = OTPScanMatch.candidates(in: [unrelated, byTitle, byHost], issuer: "Demo", account: "ada", pageURL: nil)
        XCTAssertEqual(ranked.map(\.id), [byHost.id, byTitle.id])
    }

    func testAnEmptyIssuerAndNoPageFindsNothing() {
        XCTAssertEqual(OTPScanMatch.candidates(in: [entry("A", user: "ada")], issuer: "", account: "ada", pageURL: nil), [])
    }
}

final class QRCodeReaderTests: XCTestCase {
    private func qrImage(_ text: String, scale: CGFloat = 8) throws -> CGImage {
        let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        let output = try XCTUnwrap(filter.outputImage).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // A white margin, as a screenshot of a web page has.
        let padded = output.composited(over: CIImage(color: .white).cropped(to: output.extent.insetBy(dx: -40, dy: -40)))
        return try XCTUnwrap(CIContext().createCGImage(padded, from: padded.extent))
    }

    func testAGeneratedQRCodeReadsBack() throws {
        let text = "otpauth://totp/Demo:ada?secret=JBSWY3DPEHPK3PXP&issuer=Demo"
        XCTAssertEqual(try QRCodeReader.payloads(in: qrImage(text)), [text])
    }

    func testAnImageWithoutACodeReadsNothing() throws {
        let blank = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 200))
        let image = try XCTUnwrap(CIContext().createCGImage(blank, from: blank.extent))
        XCTAssertEqual(try QRCodeReader.payloads(in: image), [])
    }

    func testTheFirstTwoStepCodeAmongPayloadsWins() {
        let result = OTPAuthImport.firstScan(in: ["https://example.com", "otpauth://totp/A:b?secret=JBSWY3DPEHPK3PXP", "otpauth://totp/C:d?secret=GEZDGNBV"])
        XCTAssertEqual(try result?.get().issuer, "A")
        XCTAssertEqual(OTPAuthImport.firstScan(in: ["https://example.com"]).map { r in (try? r.get()) == nil }, true)
        XCTAssertNil(OTPAuthImport.firstScan(in: []))
    }
}
