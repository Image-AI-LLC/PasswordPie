import Foundation
import XCTest

/// What the app's own code can do on the network: docs/CHANNELS.md, "Network". Every target under `Sources/` goes into
/// `PasswordPie.app` (the app, its core, the bridge, the Chrome host, the Safari and AutoFill extensions), and none may
/// name a networking API unless the file is on the allow-list below, with the reason. The list is empty: the app signs
/// in to nothing, asks no site for Premium, checks for no updates and fetches no icons.
final class NetworkSourceTests: XCTestCase {
    /// File name → why it may reach the network. Adding a line here means updating "Network" in docs/CHANNELS.md first.
    private let allowed: [String: String] = [:]

    private let networking = try! NSRegularExpression(pattern: #"""
        \b(URLSession|URLRequest|NSURLConnection|NWConnection|NWListener|NWBrowser|NWPathMonitor|NWEndpoint|ASWebAuthenticationSession|WKWebView|CFNetwork|CFStream\w*|CFSocket\w*|SocketPort|SCNetworkReachability\w*|AF_INET6?|PF_INET6?|sockaddr_in6?|getaddrinfo|gethostbyname)\b|import\s+(Network|WebKit|FoundationNetworking)\b
        """#)

    private var sources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    private func swiftFiles() throws -> [URL] {
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" || $0.pathExtension == "c" || $0.pathExtension == "h" }
    }

    func testNoFileOutsideTheAllowListNamesANetworkingAPI() throws {
        let files = try swiftFiles()
        XCTAssertGreaterThan(files.count, 50, "the walk found the sources")
        var reaching: [String: String] = [:]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard let match = networking.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range, in: text) else { continue }
            reaching[file.lastPathComponent] = String(text[range])
        }
        XCTAssertEqual(Set(reaching.keys), Set(allowed.keys), "networking outside the allow-list: \(reaching)")
    }

    func testThePatternCatchesWhatItIsFor() {
        for sample in [
            "let task = URLSession.shared.dataTask(with: url)",
            "var request = URLRequest(url: url)",
            "let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { _, _ in }",
            "let connection = NWConnection(host: host, port: 443, using: .tls)",
            "import Network",
            "addr.sin_family = sa_family_t(AF_INET)",
        ] {
            XCTAssertNotNil(networking.firstMatch(in: sample, range: NSRange(sample.startIndex..., in: sample)), sample)
        }
        let socket = "address.sun_family = sa_family_t(AF_UNIX)"
        XCTAssertNil(networking.firstMatch(in: socket, range: NSRange(socket.startIndex..., in: socket)), "the bridge's Unix socket stays on this Mac")
    }

    /// Neither channel's sandbox or hardened runtime asks to be a network client.
    func testNoEntitlementAsksForTheNetwork() throws {
        let folder = sources.deletingLastPathComponent().appendingPathComponent("Entitlements")
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasSuffix(".entitlements") {
            let text = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
            XCTAssertFalse(text.contains("<key>com.apple.security.network.client</key>"), name)
            XCTAssertFalse(text.contains("<key>com.apple.security.network.server</key>"), name)
        }
    }
}
