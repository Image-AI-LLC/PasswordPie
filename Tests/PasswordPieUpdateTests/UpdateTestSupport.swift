import Foundation
import XCTest
@testable import PasswordPieUpdate

/// Ad-hoc signed stand-ins for the app and its disk image. The real policy needs our Developer ID and Apple's notary,
/// so these tests use a policy that asks for a signing identifier instead: the checks around it are the same.
enum UpdateFixture {
    static let appID = "com.passwordpie.testapp"
    static let imageID = "com.passwordpie.testimage"
    static let policy = ReleasePolicy(
        installed: "identifier \"\(appID)\"",
        image: "identifier \"\(imageID)\"",
        app: "identifier \"\(appID)\"",
        bundleIdentifier: appID
    )

    static func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pp-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// `<folder>/PasswordPie.app`, version `version`, signed ad hoc as `signedAs` (nil: not signed).
    @discardableResult
    static func makeApp(in folder: URL, version: String, bundleID: String = appID, signedAs: String? = appID) throws -> URL {
        let app = folder.appendingPathComponent("PasswordPie.app", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appendingPathComponent("PasswordPie"))
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleID, "CFBundleExecutable": "PasswordPie", "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version, "CFBundleVersion": "1",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        if let signedAs {
            XCTAssertEqual(try run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", signedAs, app.path]), 0)
        }
        return app
    }

    /// A disk image holding `app`, signed ad hoc as `signedAs` (nil: not signed).
    static func makeImage(of app: URL, at image: URL, signedAs: String? = imageID) throws {
        XCTAssertEqual(try run("/usr/bin/hdiutil", ["create", "-srcfolder", app.deletingLastPathComponent().path, "-format", "UDZO", "-ov", image.path]), 0)
        if let signedAs {
            XCTAssertEqual(try run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", signedAs, image.path]), 0)
        }
    }

    static func feed(tag: String, assets: [String]? = nil, bytes: Int = 4_000_000, draft: Bool = false, prerelease: Bool = false) -> Data {
        let names = assets ?? ["PasswordPie-\(tag.dropFirst()).dmg", "PasswordPie.dmg"]
        let object: [String: Any] = [
            "tag_name": tag, "draft": draft, "prerelease": prerelease,
            "assets": names.map { ["name": $0, "size": bytes, "browser_download_url": "https://example.com/elsewhere/\($0)"] },
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }
}

/// Answers from memory and a file: no test here touches the network.
final class FakeTransport: UpdateTransport {
    var feed: Data?
    var image: URL?
    private(set) var fetched: [URL] = []
    private(set) var downloaded: [URL] = []

    init(feed: Data?, image: URL? = nil) {
        self.feed = feed
        self.image = image
    }

    func fetch(_ url: URL) throws -> Data {
        fetched.append(url)
        guard let feed else { throw UpdateError("GitHub did not answer.") }
        return feed
    }

    func download(_ url: URL, to file: URL, maxBytes: Int) throws {
        downloaded.append(url)
        guard let image else { throw UpdateError("The download failed.") }
        try FileManager.default.copyItem(at: image, to: file)
    }
}
