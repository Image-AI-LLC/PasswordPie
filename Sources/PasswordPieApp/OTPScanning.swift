import AppKit
import Combine
import PasswordPieCore
import UniformTypeIdentifiers

// Two-step QR codes in the app: reading one from the clipboard, a file or a dropped image (the editor), and the one scan
// from the browser extension waiting for the person to confirm it (docs/UX.md, "Scan a two-step QR code").
// Everything stays in memory and on this Mac: Vision reads the picture, nothing is sent anywhere.

/// What reading a picture or a link gave.
enum OTPScanOutcome: Equatable {
    case scanned(ScannedOTP)
    /// One sentence for the row under the field.
    case failed(String)
}

enum OTPInputScanner {
    static let noQRCode = "No QR code found."
    static let nothingToScan = "Copy a screenshot of the QR code first, or an otpauth:// link."
    static let unreadableImage = "This image could not be read."

    /// The clipboard: an `otpauth://` link as text, an image file, or an image (a ⌃⇧⌘4 screenshot).
    static func scan(pasteboard: NSPasteboard) -> OTPScanOutcome {
        if let text = pasteboard.string(forType: .string), looksLikeOTPLink(text) {
            return scan(text: text)
        }
        if let url = imageFileURLs(on: pasteboard).first {
            return scan(fileURL: url)
        }
        if let image = NSImage(pasteboard: pasteboard) {
            return scan(image: image)
        }
        return .failed(nothingToScan)
    }

    /// True when ⌘V in the field should read a picture: an image is there and no text to paste.
    static func holdsOnlyAnImage(_ pasteboard: NSPasteboard) -> Bool {
        guard pasteboard.string(forType: .string) == nil else { return false }
        return !imageFileURLs(on: pasteboard).isEmpty || NSImage.canInit(with: pasteboard)
    }

    static func scan(text: String) -> OTPScanOutcome {
        switch OTPAuthImport.parse(text) {
        case .success(let scan): return .scanned(scan)
        case .failure(let error): return .failed(error.message)
        }
    }

    static func scan(fileURL: URL) -> OTPScanOutcome {
        guard let image = NSImage(contentsOf: fileURL) else { return .failed(unreadableImage) }
        return scan(image: image)
    }

    static func scan(image: NSImage) -> OTPScanOutcome {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .failed(unreadableImage) }
        return scan(cgImage: cgImage)
    }

    static func scan(cgImage: CGImage) -> OTPScanOutcome {
        guard let payloads = try? QRCodeReader.payloads(in: cgImage) else { return .failed(unreadableImage) }
        switch OTPAuthImport.firstScan(in: payloads) {
        case .success(let scan)?: return .scanned(scan)
        case .failure(let error)?: return .failed(error.message)
        case nil: return .failed(noQRCode)
        }
    }

    private static func looksLikeOTPLink(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("otpauth")
    }

    private static func imageFileURLs(on pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier]
        ]
        return pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }
}

/// What the editor stores for what was typed or scanned: a link as it is, a bare Base32 secret as the otpauth link
/// KeePassXC writes in the `otp` field, nothing for nothing.
func editorOTPValue(_ input: String, title: String, username: String) -> String {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "" }
    if trimmed.lowercased().hasPrefix("otpauth://") { return trimmed }
    return TOTP.otpAuthURL(secretBase32: trimmed, title: title, username: username)
}

/// The one QR code the browser extension scanned, waiting for the person to choose the item and press Add. Memory only:
/// it goes after 2 minutes, on Cancel, on Add, or when another scan replaces it. Nothing is written before Add.
@MainActor
final class OTPScanModel: ObservableObject {
    static let lifetime: TimeInterval = 120

    struct Scan: Equatable {
        let otp: ScannedOTP
        /// The origin of the page it was on, if it was a web page.
        let origin: String?
        let browser: BridgeBrowser?
        let received: Date
    }

    enum Target: Hashable {
        case entry(UUID)
        case newItem
    }

    enum Phase: Equatable {
        case idle
        case choosing
        /// Add was pressed on an item that already has a code.
        case confirmReplace
        /// Saved in this item. The scan itself is gone.
        case added(UUID)
        case expired
        case failed(String)
    }

    static let expiredText = "This scan has expired. Scan the QR code again."

    @Published private(set) var scan: Scan?
    @Published private(set) var phase: Phase = .idle
    @Published var target: Target?
    @Published var query = ""

    private unowned let session: VaultSession
    var now: () -> Date = Date.init
    /// A scan arrived: show the window, or the unlock screen first.
    var present: () -> Void = {}
    /// The code was saved in `entry`: the extension that scanned it may fill it into the page.
    var codeAdded: (_ entry: UUID, _ browser: BridgeBrowser, _ origin: String) -> Void = { _, _, _ in }
    private var expiry: Timer?

    init(session: VaultSession) {
        self.session = session
    }

    /// A newer scan replaces the one before, whatever it had reached.
    func receive(_ otp: ScannedOTP, origin: String?, browser: BridgeBrowser?) {
        scan = Scan(otp: otp, origin: origin, browser: browser, received: now())
        phase = .choosing
        query = ""
        target = nil
        prepare()
        scheduleExpiry()
        present()
    }

    /// Picks the best item, now that the vault can be read. Does nothing while locked.
    func prepare() {
        guard !session.locked, phase == .choosing, target == nil, scan != nil else { return }
        // Only an item on the page's own site is chosen for the person. One that merely names the issuer is listed, not chosen.
        let site = scan?.origin.flatMap { BrowserSite(url: $0) }?.key
        if let first = candidates.first, let site, entryWebsites(first).contains(where: { BrowserSite(url: $0)?.key == site }) {
            target = .entry(first.id)
        } else {
            target = .newItem
        }
    }

    /// A scan is waiting to be confirmed. A failed save keeps it waiting, so Add can be pressed again.
    var isWaiting: Bool {
        expireIfNeeded()
        return scan != nil && (phase == .choosing || phase == .confirmReplace || isFailed)
    }

    /// Items on the page's site, then items naming the issuer. Empty while locked.
    var candidates: [VaultEntry] {
        guard let scan, !session.locked else { return [] }
        return OTPScanMatch.candidates(in: session.entries, issuer: scan.otp.issuer, account: scan.otp.account, pageURL: scan.origin)
    }

    /// Other items matching the search, up to 20.
    var searchResults: [VaultEntry] {
        let tokens = searchTokens(query)
        guard !tokens.isEmpty, !session.locked else { return [] }
        let shown = Set(candidates.map(\.id))
        return sortedForMenu(session.entries.filter { entry in
            guard !entry.trashed, !shown.contains(entry.id) else { return false }
            let text = foldForSearch([entry.title, entry.username, urlSearchString(entry.url)].joined(separator: " "))
            return tokens.allSatisfy { text.contains($0) }
        }).prefix(20).map { $0 }
    }

    /// The title a new item gets: the issuer, else the page's host.
    var newItemTitle: String {
        guard let scan else { return "" }
        if !scan.otp.issuer.isEmpty { return scan.otp.issuer }
        return scan.origin.flatMap { BrowserSite(url: $0)?.host } ?? "Two-Step Code"
    }

    /// Whether the chosen item holds a code already, so Add asks first.
    var targetHasCode: Bool {
        guard case .entry(let id)? = target, let entry = session.storedEntry(id) else { return false }
        return OneTimeCodes.hasCode(entry) || !entry.otp.isEmpty
    }

    func add() {
        guard isWaiting, let scan, !session.locked, let target else { return }
        var entry: VaultEntry
        switch target {
        case .entry(let id):
            guard let stored = session.storedEntry(id) else { return }
            if phase != .confirmReplace, targetHasCode {
                phase = .confirmReplace
                return
            }
            entry = stored
        case .newItem:
            entry = VaultEntry()
            entry.title = newItemTitle
            entry.username = scan.otp.account
            entry.url = scan.origin ?? ""
        }
        // The previous value of the field goes into the item's KDBX history when the file is written.
        entry.otp = scan.otp.uri
        guard session.storeEntry(entry) else {
            phase = .failed(session.message.isEmpty ? "The database could not be saved." : session.message)
            return
        }
        clearScan()
        phase = .added(entry.id)
        if let browser = scan.browser, let origin = scan.origin { codeAdded(entry.id, browser, origin) }
    }

    /// Back from "Replace the existing code?" to the list.
    func keepChoosing() {
        guard phase == .confirmReplace || isFailed else { return }
        phase = scan == nil ? .expired : .choosing
    }

    func cancel() {
        clearScan()
        phase = .idle
    }

    /// Drops a scan older than 2 minutes. Called by the timer, and before anything uses the scan.
    @discardableResult
    func expireIfNeeded() -> Bool {
        guard let scan, now().timeIntervalSince(scan.received) >= Self.lifetime else { return false }
        clearScan()
        phase = .expired
        return true
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func clearScan() {
        scan = nil
        target = nil
        query = ""
        expiry?.invalidate()
        expiry = nil
    }

    private func scheduleExpiry() {
        expiry?.invalidate()
        expiry = Timer.scheduledTimer(withTimeInterval: Self.lifetime, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.expireIfNeeded() }
        }
    }
}
