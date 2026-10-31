import LocalAuthentication
import XCTest
@testable import PasswordPieCore

final class TouchIDSecretStoreTests: XCTestCase {
    private let service = "com.oldcai.passwordpie.tests"
    private var account = ""

    override func setUp() {
        account = "account-\(UUID().uuidString)"
    }

    /// A sandboxed `swift test` cannot open the login keychain and returns `errSecParam`.
    /// A normal session returns `errSecItemNotFound` for an account this test just invented.
    private func requireKeychain() throws {
        let status = TouchIDSecretStore(service: service).probe(account: account)
        try XCTSkipIf(status != errSecItemNotFound, "Login keychain is not available to this test process (\(status)).")
    }

    override func tearDown() {
        _ = TouchIDSecretStore(service: service).delete(account: account)
    }

    func testRoundTripReplacesAndClearsTheSecret() throws {
        try requireKeychain()
        let store = TouchIDSecretStore(service: service)
        XCTAssertEqual(store.save(secret: Data("first".utf8), account: account), errSecSuccess)
        XCTAssertEqual(store.load(account: account).secret, Data("first".utf8))

        XCTAssertEqual(store.save(secret: Data("päss wörd".utf8), account: account), errSecSuccess)
        XCTAssertEqual(store.load(account: account).secret, Data("päss wörd".utf8))

        XCTAssertEqual(store.delete(account: account), errSecSuccess)
        XCTAssertEqual(store.load(account: account).status, errSecItemNotFound)
        XCTAssertNil(store.load(account: account).secret)
        XCTAssertEqual(store.delete(account: account), errSecSuccess)
    }

    func testMissingItemIsNotFound() throws {
        try requireKeychain()
        let loaded = TouchIDSecretStore(service: service).load(account: account)
        XCTAssertEqual(loaded.status, errSecItemNotFound)
        XCTAssertNil(loaded.secret)
    }

    func testEmptySecretIsRejected() throws {
        try requireKeychain()
        let status = TouchIDSecretStore(service: service).save(secret: Data(), account: account)
        XCTAssertEqual(status, errSecParam)
        XCTAssertEqual(TouchIDSecretStore(service: service).load(account: account).status, errSecItemNotFound)
    }

    func testCancelledTouchIDStaysQuiet() {
        XCTAssertNil(TouchIDPromptMessage.message(for: .userCancel))
        XCTAssertNil(TouchIDPromptMessage.message(for: .appCancel))
        XCTAssertNil(TouchIDPromptMessage.message(for: .systemCancel))
        XCTAssertNil(TouchIDPromptMessage.message(for: .userFallback))
    }

    func testProbeReportsAStoredSecretWithoutReturningIt() throws {
        try requireKeychain()
        let store = TouchIDSecretStore(service: service)
        XCTAssertEqual(store.probe(account: account), errSecItemNotFound)
        XCTAssertEqual(store.save(secret: Data("secret".utf8), account: account), errSecSuccess)
        XCTAssertEqual(store.probe(account: account), errSecSuccess)
        XCTAssertEqual(store.delete(account: account), errSecSuccess)
        XCTAssertEqual(store.probe(account: account), errSecItemNotFound)
    }

    func testEnableCommitsToTheDatabaseThatStartedThePrompt() {
        let secret = Data("pw".utf8)
        XCTAssertEqual(
            TouchIDEnrollment.commit(
                capturedAccount: "/old.kdbx",
                currentAccount: "/new.kdbx",
                capturedSecret: secret,
                currentSecret: Data()
            ),
            .write(account: "/old.kdbx", showOnCurrentDatabase: false)
        )
        XCTAssertEqual(
            TouchIDEnrollment.commit(
                capturedAccount: "/vault.kdbx",
                currentAccount: "/vault.kdbx",
                capturedSecret: secret,
                currentSecret: secret
            ),
            .write(account: "/vault.kdbx", showOnCurrentDatabase: true)
        )
        XCTAssertEqual(
            TouchIDEnrollment.commit(
                capturedAccount: "/vault.kdbx",
                currentAccount: "/vault.kdbx",
                capturedSecret: secret,
                currentSecret: Data("other".utf8)
            ),
            .rejectChangedPassword
        )
    }

    func testFailedDeleteKeepsTheTouchIDFlag() {
        XCTAssertFalse(TouchIDEnrollment.keepsPersistedFlag(deleteStatus: errSecSuccess))
        XCTAssertTrue(TouchIDEnrollment.keepsPersistedFlag(deleteStatus: errSecAuthFailed))
    }

    func testMasterUnlockRefreshClearsStaleOnlyAfterTheSaveSucceeds() {
        XCTAssertEqual(TouchIDEnrollment.refreshAfterMasterUnlock(saveStatus: errSecSuccess), .refreshed)
        XCTAssertEqual(
            TouchIDEnrollment.refreshAfterMasterUnlock(saveStatus: errSecAuthFailed),
            .stale(errSecAuthFailed)
        )
    }

    func testOfferRequiresAReadableSecret() {
        XCTAssertEqual(TouchIDEnrollment.offer(hardware: true, probe: errSecSuccess), .available)
        XCTAssertEqual(TouchIDEnrollment.offer(hardware: false, probe: errSecSuccess), .noHardware)
        XCTAssertEqual(TouchIDEnrollment.offer(hardware: true, probe: errSecItemNotFound), .missingSecret)
        XCTAssertEqual(TouchIDEnrollment.offer(hardware: true, probe: errSecAuthFailed), .unreadable)
    }

    func testTouchIDFailuresExplainWhatToDo() {
        XCTAssertEqual(
            TouchIDPromptMessage.message(for: .biometryLockout),
            "Touch ID is locked. Use the master password."
        )
        XCTAssertEqual(
            TouchIDPromptMessage.message(for: .biometryNotEnrolled),
            "Set up Touch ID in System Settings, then try again."
        )
        XCTAssertEqual(TouchIDPromptMessage.message(for: .authenticationFailed), "Touch ID didn't match.")
        XCTAssertEqual(TouchIDPromptMessage.message(for: .biometryNotAvailable), "Touch ID is not available.")
    }

    func testARememberedFileLoadsOnlyInsideItsOwnWindow() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fresh = now.addingTimeInterval(-86_400)
        let expired = now.addingTimeInterval(-8 * 86_400)
        XCTAssertEqual(RememberedFile.access(enabled: true, stale: false, unlockedAt: fresh, now: now), .load(stampNow: false))
        XCTAssertEqual(RememberedFile.access(enabled: true, stale: false, unlockedAt: expired, now: now), .expire)
        XCTAssertEqual(RememberedFile.access(enabled: true, stale: false, unlockedAt: nil, now: now), .load(stampNow: true))
        XCTAssertEqual(RememberedFile.access(enabled: false, stale: false, unlockedAt: fresh, now: now), .skip)
        XCTAssertEqual(RememberedFile.access(enabled: true, stale: true, unlockedAt: fresh, now: now), .skip)
    }
}
