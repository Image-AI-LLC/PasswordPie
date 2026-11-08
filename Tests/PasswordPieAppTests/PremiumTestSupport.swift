import CryptoKit
import Foundation
import PasswordPieCore
@testable import PasswordPie

/// The store, scripted. Nothing here touches StoreKit.
@MainActor
final class FakePremiumBackend: PremiumBackend {
    struct Failure: LocalizedError {
        var errorDescription: String? { "The App Store said no." }
    }

    var transactions: [PremiumTransaction] = []
    /// After this many more answers, `currentTransactions` starts returning these. A store that lags behind a purchase.
    var transactionsAfterRefreshes: (count: Int, transactions: [PremiumTransaction])?
    var products: Result<[PremiumProduct], Failure> = .success([FakePremiumBackend.lifetime, FakePremiumBackend.yearly])
    /// Nil: a success, with the transaction `onPurchase` (or the default) adds.
    var purchaseOutcome: Result<PremiumPurchaseOutcome, Failure>?
    var restoreOutcome: Result<PremiumRestoreOutcome, Failure> = .success(.finished)
    /// Runs inside `purchase`, as the store records the transaction before it returns.
    var onPurchase: ((PremiumPlan) -> Void)?
    var onRestore: (() -> Void)?
    /// Holds `currentTransactions` open, as a store that has not answered yet.
    var answerGate: CheckedContinuation<Void, Never>?
    var holdsAnswers = false
    /// Holds `purchase` open, as the App Store's own sheet does while the user decides.
    var purchaseGate: CheckedContinuation<Void, Never>?
    var holdsPurchases = false
    private(set) var purchases: [PremiumPlan] = []
    private(set) var restores = 0
    private(set) var productLoads = 0
    private var continuation: AsyncStream<Void>.Continuation?

    static let lifetime = PremiumProduct(plan: .lifetime, displayName: "Premium Lifetime", displayPrice: "€33,99", period: nil)
    static let yearly = PremiumProduct(plan: .yearly, displayName: "Premium Yearly", displayPrice: "€11,99", period: PremiumPeriod(value: 1, unit: .year))

    func currentTransactions() async -> [PremiumTransaction] {
        if holdsAnswers {
            await withCheckedContinuation { answerGate = $0 }
        }
        if let lag = transactionsAfterRefreshes {
            if lag.count <= 0 {
                transactions = lag.transactions
                transactionsAfterRefreshes = nil
            } else {
                transactionsAfterRefreshes = (lag.count - 1, lag.transactions)
            }
        }
        return transactions
    }

    func transactionUpdates() -> AsyncStream<Void> {
        AsyncStream { continuation = $0 }
    }

    func loadProducts() async throws -> [PremiumProduct] {
        productLoads += 1
        return try products.get()
    }

    func purchase(_ plan: PremiumPlan) async throws -> PremiumPurchaseOutcome {
        purchases.append(plan)
        if holdsPurchases {
            await withCheckedContinuation { purchaseGate = $0 }
        }
        if let onPurchase {
            onPurchase(plan)
        } else if purchaseOutcome == nil {
            transactions.append(PremiumFixtures.transaction(plan))
        }
        if let purchaseOutcome { return try purchaseOutcome.get() }
        return .success
    }

    func restore() async throws -> PremiumRestoreOutcome {
        restores += 1
        onRestore?()
        return try restoreOutcome.get()
    }

    func emitUpdate() {
        continuation?.yield(())
    }

    func answer() {
        answerGate?.resume()
        answerGate = nil
        holdsAnswers = false
    }
}

/// Records what reaches the clipboard, so tests never touch the real one.
final class FakePasteboard: PasteboardLike {
    private(set) var changeCount = 0
    private(set) var writes: [String] = []

    func write(_ string: String) -> Int {
        writes.append(string)
        changeCount += 1
        return changeCount
    }

    func clear() {
        changeCount += 1
    }
}

enum PremiumFixtures {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let lifetime = transaction(.lifetime)

    static func transaction(_ plan: PremiumPlan, expires: Date? = nil) -> PremiumTransaction {
        PremiumTransaction(
            productID: plan.productID, verified: true, revocationDate: nil,
            expirationDate: plan == .yearly ? (expires ?? now.addingTimeInterval(365 * 86400)) : expires
        )
    }

    static func yearly(expires: Date) -> PremiumTransaction {
        transaction(.yearly, expires: expires)
    }

    static func login(_ title: String = "Bank", code: Bool = true) -> VaultEntry {
        var entry = VaultEntry()
        entry.title = title
        entry.username = "ada"
        entry.password = "secret"
        entry.url = "https://bank.example/login"
        if code { entry.otp = "otpauth://totp/Bank:ada?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=Bank" }
        return entry
    }
}

@MainActor
func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { return false }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return true
}

// MARK: The account

/// passwordpie.com's signing key, made for the test run. The store under test trusts only this one.
enum PassKey {
    static let key = Curve25519.Signing.PrivateKey()

    static func verify(_ jwt: String, _ now: Date) -> Entitlement? {
        EntitlementToken.verify(jwt, now: now, publicKey: key.publicKey.rawRepresentation)
    }

    static func verifyActivation(_ jwt: String, _ now: Date) -> Entitlement? {
        EntitlementToken.verify(jwt, now: now, publicKey: key.publicKey.rawRepresentation, audience: EntitlementToken.activationAudience)
    }

    static func activationLink(plan: String = "lifetime", expires: Date, signer: Curve25519.Signing.PrivateKey = key) -> URL {
        URL(string: "passwordpie://activate?token=\(pass(plan: plan, expires: expires, signer: signer, audience: EntitlementToken.activationAudience))")!
    }

    static func pass(plan: String = "lifetime", expires: Date, signer: Curve25519.Signing.PrivateKey = key, audience: String = EntitlementToken.audience) -> String {
        func b64(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let header = try! JSONSerialization.data(withJSONObject: ["alg": "EdDSA", "typ": "JWT", "kid": "pp-1"], options: .sortedKeys)
        let claims = try! JSONSerialization.data(withJSONObject: [
            "iss": "https://passwordpie.com", "aud": audience, "sub": "user-1", "premium": true, "plan": plan,
            "iat": 1_700_000_000, "exp": Int(expires.timeIntervalSince1970),
        ] as [String: Any], options: .sortedKeys)
        let signing = "\(b64(header)).\(b64(claims))"
        return "\(signing).\(b64(try! signer.signature(for: Data(signing.utf8))))"
    }
}

@MainActor
final class FakeAccountSecrets: AccountSecretStore {
    var values: [AccountSecret: String] = [:]
    private(set) var reads = 0

    func read(_ secret: AccountSecret) -> String? {
        reads += 1
        return values[secret]
    }

    func write(_ value: String, for secret: AccountSecret) { values[secret] = value }
    func delete(_ secret: AccountSecret) { values[secret] = nil }
}

#if PP_DIRECT
extension PassKey {
    static func premium(plan: String = "lifetime", passExpires: Date = PremiumFixtures.now.addingTimeInterval(7 * 86400), until: Date? = nil) -> AccountReply {
        .ok(AccountEntitlementResponse(premium: true, plan: plan, expiresAt: until, token: pass(plan: plan, expires: passExpires)))
    }

    static let free = AccountReply.ok(AccountEntitlementResponse(premium: false, plan: nil, expiresAt: nil, token: nil))
}

/// passwordpie.com, scripted.
@MainActor
final class FakeAccountClient: AccountClient {
    var entitlementReply: AccountReply = PassKey.free
    var exchangeToken: String? = "session-from-code"
    var emailReply: String? = "ada@example.com"
    /// Holds `entitlement` open, as a site that has not answered yet.
    var holdsAnswers = false
    var answerGate: CheckedContinuation<Void, Never>?
    private(set) var entitlementCalls: [String] = []
    private(set) var exchanged: [String] = []
    private(set) var signedOut: [String] = []

    func exchange(code: String) async -> String? {
        exchanged.append(code)
        return exchangeToken
    }

    func email(session: String) async -> String? { emailReply }

    func entitlement(session: String) async -> AccountReply {
        entitlementCalls.append(session)
        if holdsAnswers { await withCheckedContinuation { answerGate = $0 } }
        return entitlementReply
    }

    func signOut(session: String) async { signedOut.append(session) }

    func answer() {
        holdsAnswers = false
        answerGate?.resume()
        answerGate = nil
    }
}

/// The sign-in sheet, scripted. By default the site sends back a one-time code for the state it was given.
@MainActor
final class FakeSignIn: AccountSignInDriver {
    enum Script {
        case code
        case token(String)
        case wrongState
        case cancel
        case fail
    }

    var script = Script.code
    private(set) var opened: [URL] = []

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        opened.append(url)
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
        switch script {
        case .code: return URL(string: "passwordpie://auth?code=one-time&state=\(state)")!
        case .token(let token): return URL(string: "passwordpie://auth?token=\(token)&state=\(state)")!
        case .wrongState: return URL(string: "passwordpie://auth?code=one-time&state=someone-else")!
        case .cancel: throw AccountSignInCancelled()
        case .fail: throw URLError(.cannotConnectToHost)
        }
    }
}

@MainActor
struct FakeAccount {
    let client = FakeAccountClient()
    let secrets = FakeAccountSecrets()
    let signIn = FakeSignIn()

    var services: AccountServices {
        AccountServices(site: .production, client: client, secrets: secrets, signIn: signIn, verify: PassKey.verify)
    }

    /// Signed in already, as after an earlier launch.
    func signedIn(_ session: String = "session-1") -> FakeAccount {
        secrets.values[.session] = session
        secrets.values[.email] = "ada@example.com"
        return self
    }
}
#endif
