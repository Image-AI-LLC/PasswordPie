import XCTest
@testable import PasswordPie

final class FolderAccessTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        suite = "FolderAccessTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    /// Bookmarks are the folder path as bytes; `answer` is what the folder panel returns.
    private final class FakeSystem {
        var answer: URL?
        var asked: [URL] = []
        var started: [String] = []
        var stopped: [String] = []
        var unresolvable: Set<String> = []
        var stale: Set<String> = []
        var remade: [String] = []

        var system: FolderAccess.System {
            FolderAccess.System(
                makeBookmark: { url in
                    self.remade.append(url.path)
                    return Data(url.path.utf8)
                },
                resolveBookmark: { data in
                    let path = String(decoding: data, as: UTF8.self)
                    if self.unresolvable.contains(path) { throw CocoaError(.fileNoSuchFile) }
                    return FolderAccess.Resolved(url: URL(fileURLWithPath: path), stale: self.stale.contains(path))
                },
                startAccessing: { url in
                    self.started.append(url.path)
                    return true
                },
                stopAccessing: { self.stopped.append($0.path) },
                askForFolder: { database in
                    self.asked.append(database)
                    return self.answer
                }
            )
        }
    }

    private func access(_ fake: FakeSystem, sandboxed: Bool = true) -> FolderAccess {
        FolderAccess(sandboxed: sandboxed, defaults: defaults, ownFolder: "/Container/Data", system: fake.system)
    }

    private let dropbox = URL(fileURLWithPath: "/Users/a/Dropbox/Passwords.kdbx")

    func testOutsideTheSandboxNothingIsAsked() {
        let fake = FakeSystem()
        let folders = access(fake, sandboxed: false)
        XCTAssertTrue(folders.ensure(dropbox))
        XCTAssertTrue(fake.asked.isEmpty)
        XCTAssertNil(defaults.object(forKey: FolderAccess.defaultsKey))
    }

    func testTheAppsOwnFolderNeverAsks() {
        let fake = FakeSystem()
        XCTAssertTrue(access(fake).ensure(URL(fileURLWithPath: "/Container/Data/Library/Application Support/PasswordPie/PasswordPie.kdbx")))
        XCTAssertTrue(fake.asked.isEmpty)
    }

    func testAllowingTheFolderKeepsItsBookmarkAndStartsAccess() {
        let fake = FakeSystem()
        fake.answer = URL(fileURLWithPath: "/Users/a/Dropbox")
        let folders = access(fake)
        XCTAssertTrue(folders.ensure(dropbox))
        XCTAssertEqual(fake.asked, [dropbox])
        XCTAssertEqual(fake.started, ["/Users/a/Dropbox"])
        XCTAssertEqual(defaults.dictionary(forKey: FolderAccess.defaultsKey) as? [String: Data], ["/Users/a/Dropbox": Data("/Users/a/Dropbox".utf8)])
        // A second database in the same folder does not ask again.
        XCTAssertTrue(folders.ensure(URL(fileURLWithPath: "/Users/a/Dropbox/Work.kdbx")))
        XCTAssertEqual(fake.asked.count, 1)
    }

    func testCancellingOrChoosingAnotherFolderKeepsNothing() {
        let fake = FakeSystem()
        let folders = access(fake)
        XCTAssertFalse(folders.ensure(dropbox))
        fake.answer = URL(fileURLWithPath: "/Users/a/Desktop")
        XCTAssertFalse(folders.ensure(dropbox))
        XCTAssertTrue(folders.bookmarks.isEmpty)
        XCTAssertTrue(fake.started.isEmpty)
    }

    func testTheNextStartOpensTheAllowedFoldersWithoutAsking() {
        let first = FakeSystem()
        first.answer = URL(fileURLWithPath: "/Users/a/Dropbox")
        XCTAssertTrue(access(first).ensure(dropbox))

        let next = FakeSystem()
        let folders = access(next)
        folders.restore()
        XCTAssertEqual(next.started, ["/Users/a/Dropbox"])
        XCTAssertTrue(folders.isUsable(dropbox))
        XCTAssertTrue(next.asked.isEmpty)
    }

    func testAFolderThatNoLongerResolvesIsDroppedAndAsksAgain() {
        defaults.set(["/Users/a/Dropbox": Data("/Users/a/Dropbox".utf8)], forKey: FolderAccess.defaultsKey)
        let fake = FakeSystem()
        fake.unresolvable = ["/Users/a/Dropbox"]
        let folders = access(fake)
        folders.restore()
        XCTAssertFalse(folders.isUsable(dropbox))
        XCTAssertTrue((defaults.dictionary(forKey: FolderAccess.defaultsKey) ?? [:]).isEmpty)
    }

    func testAStaleBookmarkIsMadeAgain() {
        defaults.set(["/Users/a/Dropbox": Data("old".utf8)], forKey: FolderAccess.defaultsKey)
        let fake = FakeSystem()
        // The saved bytes "old" resolve to a folder that moved: still reachable, but the bookmark wants remaking.
        let resolvedPath = URL(fileURLWithPath: "old").path
        fake.stale = ["old"]
        let folders = access(fake)
        folders.restore()
        XCTAssertEqual(fake.remade, [resolvedPath])
        XCTAssertEqual(folders.bookmarks[resolvedPath], Data(resolvedPath.utf8))
    }

    func testRemovingTheLastDatabaseInAFolderForgetsTheFolder() {
        let fake = FakeSystem()
        fake.answer = URL(fileURLWithPath: "/Users/a/Dropbox")
        let folders = access(fake)
        XCTAssertTrue(folders.ensure(dropbox))
        folders.prune(keeping: [dropbox.path])
        XCTAssertEqual(Array(folders.bookmarks.keys), ["/Users/a/Dropbox"])
        folders.prune(keeping: ["/Container/Data/Library/Application Support/PasswordPie/PasswordPie.kdbx"])
        XCTAssertTrue(folders.bookmarks.isEmpty)
        XCTAssertEqual(fake.stopped, ["/Users/a/Dropbox"])
    }
}

final class FolderAccessSymlinkTests: XCTestCase {
    func testAFolderReachedThroughASymlinkCoversTheRealPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("symlink-\(UUID().uuidString)").resolvingSymlinksInPath()
        let real = root.appendingPathComponent("CloudStorage/Dropbox")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("Dropbox")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "FolderAccessSymlinkTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let system = FolderAccess.System(
            makeBookmark: { Data($0.path.utf8) },
            resolveBookmark: { FolderAccess.Resolved(url: URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), stale: false) },
            startAccessing: { _ in true },
            stopAccessing: { _ in },
            askForFolder: { _ in link }
        )
        let folders = FolderAccess(sandboxed: true, defaults: defaults, ownFolder: "/Container/Data", system: system)
        XCTAssertTrue(folders.ensure(real.appendingPathComponent("Passwords.kdbx")))
        XCTAssertTrue(folders.isUsable(link.appendingPathComponent("Passwords.kdbx")))
        XCTAssertTrue(folders.isUsable(real.appendingPathComponent("Passwords.kdbx")))
    }
}
