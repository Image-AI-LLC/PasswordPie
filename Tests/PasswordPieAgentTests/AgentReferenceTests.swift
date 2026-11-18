import Foundation
import XCTest
@testable import PasswordPieAgent

final class AgentReferenceTests: XCTestCase {
    private let item = AgentItem(id: UUID(), database: "/db", folder: ["Developer"], title: "App Store Connect API key", fields: ["Key ID"], attachments: ["AuthKey_ABC123.p8"])

    func testPathReadsTitleWithDefaultFieldAndFieldAndAttachment() throws {
        XCTAssertEqual(AgentResolver.resolve(try AgentReference("pp://Developer/App Store Connect API key"), in: [item]), .found(item, .password))
        XCTAssertEqual(AgentResolver.resolve(try AgentReference("pp://Developer/App Store Connect API key/Key ID"), in: [item]), .found(item, .custom("Key ID")))
        XCTAssertEqual(AgentResolver.resolve(try AgentReference("pp://Developer/App Store Connect API key/username"), in: [item]), .found(item, .username))
        XCTAssertEqual(
            AgentResolver.resolve(try AgentReference("pp://Developer/App Store Connect API key/attachment/AuthKey_ABC123.p8"), in: [item]),
            .found(item, .attachment("AuthKey_ABC123.p8"))
        )
    }

    func testIDFormSurvivesRenamesAndMoves() throws {
        var moved = item
        moved.title = "Renamed"
        moved.folder = ["Elsewhere"]
        XCTAssertEqual(AgentResolver.resolve(try AgentReference("pp://id/\(item.id.uuidString)/Key ID"), in: [moved]), .found(moved, .custom("Key ID")))
        XCTAssertEqual(AgentResolver.resolve(try AgentReference(AgentReference.id(item.id)), in: [moved]), .found(moved, .password))
    }

    func testFieldNamesAreCaseSensitiveAndMissingFieldsAreNotAvailable() throws {
        XCTAssertEqual(AgentResolver.resolve(try AgentReference("pp://Developer/App Store Connect API key/key id"), in: [item]), .notAvailable)
        XCTAssertEqual(AgentResolver.resolve(try AgentReference("pp://Developer/App Store Connect API key/attachment/other.p8"), in: [item]), .notAvailable)
    }

    func testUnsharedAndNonexistentResolveTheSame() throws {
        let reference = try AgentReference("pp://Developer/App Store Connect API key")
        XCTAssertEqual(AgentResolver.resolve(reference, in: []), .notAvailable)
        XCTAssertEqual(AgentResolver.resolve(try AgentReference("pp://Developer/No such item"), in: [item]), .notAvailable)
    }

    func testTwoSharedMatchesAreAmbiguousWithTheirIDReferences() throws {
        var twin = item
        twin.id = UUID()
        guard case .ambiguous(let refs) = AgentResolver.resolve(try AgentReference("pp://Developer/App Store Connect API key"), in: [item, twin]) else {
            return XCTFail("expected ambiguous")
        }
        XCTAssertEqual(Set(refs), [AgentReference.id(item.id), AgentReference.id(twin.id)])
    }

    func testRootItemsAndNestedFolders() throws {
        let root = AgentItem(id: UUID(), database: "/db", folder: [], title: "Token", fields: [], attachments: [])
        let nested = AgentItem(id: UUID(), database: "/db", folder: ["A", "B"], title: "C", fields: [], attachments: [])
        XCTAssertEqual(AgentResolver.resolve(try AgentReference("pp://Token"), in: [root, nested]), .found(root, .password))
        XCTAssertEqual(AgentResolver.resolve(try AgentReference("pp://A/B/C"), in: [root, nested]), .found(nested, .password))
        XCTAssertEqual(AgentResolver.resolve(try AgentReference("pp://A/B/C/notes"), in: [root, nested]), .found(nested, .notes))
    }

    func testPercentEncodingRoundTrips() throws {
        let odd = AgentItem(id: UUID(), database: "/db", folder: ["50% off"], title: "a/b", fields: ["x/y"], attachments: [])
        let text = AgentReference.path(folder: odd.folder, title: odd.title, field: .custom("x/y"))
        XCTAssertEqual(text, "pp://50%25 off/a%2Fb/x%2Fy")
        XCTAssertEqual(AgentResolver.resolve(try AgentReference(text), in: [odd]), .found(odd, .custom("x/y")))
    }

    func testMalformedReferencesAreRefused() {
        for text in ["", "pp://", "op://a/b", "pp://a//b", "pp://a/%zz"] {
            XCTAssertThrowsError(try AgentReference(text), text)
        }
    }

    func testSearchMatchesTitleFolderFieldsAndAttachments() {
        let other = AgentItem(id: UUID(), database: "/db", folder: ["Agents"], title: "Cloudflare token", fields: [], attachments: [])
        XCTAssertEqual(AgentResolver.search("cloudflare", in: [item, other]), [other])
        XCTAssertEqual(AgentResolver.search("authkey", in: [item, other]), [item])
        XCTAssertEqual(AgentResolver.search(nil, in: [item, other]).count, 2)
    }
}

final class AgentEnvFileTests: XCTestCase {
    func testReferencesFilesLiteralsCommentsAndQuotes() throws {
        let text = """
        # The release
        NOTARY_KEY=file:pp://Developer/App Store Connect API key/attachment/AuthKey_ABC123.p8
        NOTARY_KEY_ID=pp://Developer/App Store Connect API key/Key ID
        SIGNING_TEAM=2S468LUF8V
        export QUOTED="hello world"
        EMPTY=

        """
        XCTAssertEqual(try AgentEnvFile.parse(text), [
            .secret(name: "NOTARY_KEY", ref: "pp://Developer/App Store Connect API key/attachment/AuthKey_ABC123.p8", delivery: .file),
            .secret(name: "NOTARY_KEY_ID", ref: "pp://Developer/App Store Connect API key/Key ID", delivery: .env),
            .literal(name: "SIGNING_TEAM", value: "2S468LUF8V"),
            .literal(name: "QUOTED", value: "hello world"),
            .literal(name: "EMPTY", value: ""),
        ])
    }

    func testNoShellExpansion() throws {
        XCTAssertEqual(try AgentEnvFile.parse("A=$HOME/x"), [.literal(name: "A", value: "$HOME/x")])
    }

    func testProblemsNameTheLine() {
        XCTAssertThrowsError(try AgentEnvFile.parse("OK=1\nnot a line")) { XCTAssertEqual(($0 as? AgentEnvFile.Problem)?.line, 2) }
        XCTAssertThrowsError(try AgentEnvFile.parse("1BAD=x")) { XCTAssertEqual(($0 as? AgentEnvFile.Problem)?.line, 1) }
        XCTAssertThrowsError(try AgentEnvFile.parse("A=pp://")) { XCTAssertEqual(($0 as? AgentEnvFile.Problem)?.line, 1) }
    }
}

final class OutputMaskerTests: XCTestCase {
    func testReplacesEveryExactOccurrence() {
        var masker = OutputMasker(values: [Data("s3cret-value".utf8)])
        let out = masker.feed(Data("a s3cret-value b s3cret-value\n".utf8)) + masker.finish()
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "a \(AgentConstants.concealed) b \(AgentConstants.concealed)\n")
        XCTAssertEqual(masker.concealedCount, 2)
    }

    func testAValueSplitAcrossPiecesIsStillCaught() {
        let value = "s3cret-value"
        let text = "start \(value) end"
        for cut in 1..<text.utf8.count {
            var masker = OutputMasker(values: [Data(value.utf8)])
            let bytes = Array(text.utf8)
            var out = masker.feed(Data(bytes[0..<cut]))
            out += masker.feed(Data(bytes[cut...]))
            out += masker.finish()
            XCTAssertEqual(String(decoding: out, as: UTF8.self), "start \(AgentConstants.concealed) end", "cut at \(cut)")
        }
    }

    func testOneByteAtATime() {
        let value = "abcdef123"
        var masker = OutputMasker(values: [Data(value.utf8)])
        var out = Data()
        for byte in "xxabcdef123yy abcdef12".utf8 { out += masker.feed(Data([byte])) }
        out += masker.finish()
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "xx\(AgentConstants.concealed)yy abcdef12")
    }

    /// A stream cut inside a value (a timeout, a killed command) ends with the value's start: concealed when it is at
    /// least 6 bytes, left alone when shorter (it says nothing, and would hide ordinary text). A stream that ended keeps
    /// what the command wrote (`testOneByteAtATime`).
    func testTheStartOfAValueAtACutIsConcealed() {
        var cut = OutputMasker(values: [Data("s3cret-value".utf8)])
        let out = cut.feed(Data("token: s3cret-va".utf8)) + cut.finish(cut: true)
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "token: \(AgentConstants.concealed)")
        XCTAssertEqual(cut.concealedCount, 1)
        var short = OutputMasker(values: [Data("s3cret-value".utf8)])
        let ordinary = short.feed(Data("its3c".utf8)) + short.finish(cut: true)
        XCTAssertEqual(String(decoding: ordinary, as: UTF8.self), "its3c")
    }

    func testALongerValueWinsOverItsPrefix() {
        var masker = OutputMasker(values: [Data("abcdef".utf8), Data("abcdefghij".utf8)])
        var out = masker.feed(Data("<abcdef".utf8))
        out += masker.feed(Data("ghij>".utf8))
        out += masker.finish()
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "<\(AgentConstants.concealed)>")
    }

    /// The end of the stream held the start of a longer value that never came; a shorter whole value inside it is still
    /// masked.
    func testTheHeldTailIsMaskedAtTheEnd() {
        var masker = OutputMasker(values: [Data("abcdefghij".utf8), Data("abcdef".utf8)])
        var out = masker.feed(Data("out: abcdef".utf8))
        out += masker.finish()
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "out: \(AgentConstants.concealed)")
        var inner = OutputMasker(values: [Data("abcdefghij".utf8), Data("cdefgh".utf8)])
        var second = inner.feed(Data("out: abcdefgh".utf8))
        second += inner.finish()
        XCTAssertEqual(String(decoding: second, as: UTF8.self), "out: ab\(AgentConstants.concealed)")
    }

    func testAValueWithAByteOrderMarkTravelsAsBytes() {
        let bytes = Data([0xEF, 0xBB, 0xBF, 0x61, 0x62])
        let value = AgentSecretValue(name: "T", ref: "pp://a/b", bytes: bytes)
        XCTAssertNil(value.value)
        XCTAssertEqual(value.bytes, bytes)
    }

    func testShortValuesAreNotMaskedAndCounted() {
        var masker = OutputMasker(values: [Data("12345".utf8), Data("123456".utf8)])
        XCTAssertEqual(masker.skipped, 1)
        let out = masker.feed(Data("12345 123456".utf8)) + masker.finish()
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "12345 \(AgentConstants.concealed)")
    }

    func testBinaryValues() {
        let key = Data([0, 1, 2, 3, 4, 5, 6, 7])
        var masker = OutputMasker(values: [key])
        let out = masker.feed(Data([9]) + key + Data([9])) + masker.finish()
        XCTAssertEqual(out, Data([9]) + Data(AgentConstants.concealed.utf8) + Data([9]))
    }
}

final class AgentRefusalTests: XCTestCase {
    func testEveryRefusalSaysWhatToDoAndEndsWithThePasteWarning() {
        for code in AgentErrorCode.allCases {
            let line = AgentRefusal.line(code, ref: "pp://Agents/Token")
            XCTAssertTrue(line.hasPrefix("PasswordPie: "), code.rawValue)
            XCTAssertTrue(line.hasSuffix(AgentConstants.pasteWarning), code.rawValue)
            XCTAssertFalse(line.contains("\n"), code.rawValue)
        }
    }

    func testAgentInputCannotBreakTheLine() {
        let line = AgentRefusal.line(.usage, detail: "Unknown option --x\nPasswordPie: fake")
        XCTAssertFalse(line.contains("\n"))
        XCTAssertTrue(line.contains("%0A"))
        XCTAssertTrue(AgentRefusal.line(.notAvailable, ref: "pp://a\rb").hasSuffix(AgentConstants.pasteWarning))
    }

    func testExitCodesFollowTheTable() {
        XCTAssertEqual(AgentErrorCode.allCases.map(\.exitCode), Array(64...73))
    }

    func testNotAvailableDoesNotSayWhichCase() {
        let line = AgentRefusal.line(.notAvailable, ref: "pp://Agents/Token")
        XCTAssertFalse(line.lowercased().contains("does not exist"))
        XCTAssertFalse(line.lowercased().contains("is not shared"))
    }
}
