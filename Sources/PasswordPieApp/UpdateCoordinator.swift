#if PP_DIRECT
import AppKit
import PasswordPieUpdate

/// The app's side of updates, direct channel only: when to start `PasswordPieUpdater`, and when to let it replace the
/// app. The app itself asks the network nothing. See "Updates that install themselves" in docs/UX.md.
@MainActor
final class UpdateCoordinator: ObservableObject {
    struct Environment {
        var defaults: UserDefaults
        var now: () -> Date
        var installedVersion: String
        /// False when this bundle has no updater: `swift run`, a test.
        var hasUpdater: Bool
        /// Starts `PasswordPieUpdater check` and calls back on the main queue with what it printed.
        var check: (@escaping (UpdateOutcome?) -> Void) -> Void
        /// Starts `PasswordPieUpdater install`, which waits for this app to exit. False when it could not be started.
        var install: (_ staged: String, _ relaunch: Bool) -> Bool
        /// True while the staged app is still in the updater's cache: a later check may have thrown it away.
        var stagedExists: (_ path: String) -> Bool
        var quit: () -> Void
        /// The vault is locked and no PasswordPie window is open.
        var isIdle: () -> Bool
    }

    enum State: Equatable {
        case idle
        case checking
        /// Downloaded, checked and waiting to be installed.
        case ready(String)
        /// Newer, but this copy cannot be replaced where it is.
        case available(String)
        case failed(String)
        /// Not a release build, or no updater in the bundle.
        case unavailable
    }

    private enum Key {
        static let automatic = "updateAutomatically"
        static let lastAnswer = "updateLastAnswer"
        static let lastAttempt = "updateLastAttempt"
        static let stagedVersion = "updateStagedVersion"
        static let stagedPath = "updateStagedPath"
    }

    @Published private(set) var state: State = .idle
    @Published var automatic: Bool {
        didSet { environment.defaults.set(automatic, forKey: Key.automatic) }
    }
    @Published private(set) var lastAnswer: Date?
    private let environment: Environment
    private var handedOff = false
    private var timer: Timer?

    init(environment: Environment) {
        self.environment = environment
        automatic = environment.defaults.object(forKey: Key.automatic) as? Bool ?? true
        lastAnswer = environment.defaults.object(forKey: Key.lastAnswer) as? Date
        if !environment.hasUpdater {
            state = .unavailable
        } else if let version = environment.defaults.string(forKey: Key.stagedVersion), stagedPath != nil {
            state = .ready(version)
        }
    }

    private var stagedPath: String? { environment.defaults.string(forKey: Key.stagedPath) }

    private func forgetStaged() {
        environment.defaults.removeObject(forKey: Key.stagedVersion)
        environment.defaults.removeObject(forKey: Key.stagedPath)
    }

    /// The first look a minute after launch, then every hour: is a check due, and can a waiting update go in.
    func start() {
        guard timer == nil, state != .unavailable else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.tick() }
        let timer = Timer(timeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = 10 * 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func tick() {
        installIfIdle()
        guard automatic, state != .checking, state != .unavailable else { return }
        let lastAttempt = environment.defaults.object(forKey: Key.lastAttempt) as? Date
        guard UpdateSchedule.isDue(lastAnswer: lastAnswer, lastAttempt: lastAttempt, now: environment.now()) else { return }
        check()
    }

    /// Check Now in Preferences: asks whatever the schedule says, and with Update automatically off.
    func checkNow() {
        guard state != .checking, state != .unavailable else { return }
        check()
    }

    private func check() {
        state = .checking
        environment.defaults.set(environment.now(), forKey: Key.lastAttempt)
        environment.check { [weak self] outcome in self?.finish(outcome) }
    }

    private func finish(_ outcome: UpdateOutcome?) {
        guard let outcome else {
            fail("The updater did not answer.")
            return
        }
        switch outcome.status {
        case .upToDate:
            answered()
            forgetStaged()
            state = .idle
        case .staged:
            guard let version = outcome.version, let path = outcome.path else {
                fail("The updater did not answer.")
                return
            }
            answered()
            environment.defaults.set(version, forKey: Key.stagedVersion)
            environment.defaults.set(path, forKey: Key.stagedPath)
            state = .ready(version)
            installIfIdle()
        case .available:
            answered()
            forgetStaged()
            state = .available(outcome.version ?? "")
        case .notEligible:
            forgetStaged()
            state = .unavailable
        case .failed:
            fail(outcome.message ?? "The update check failed.")
        }
    }

    /// A failed check does not take back an update that is already waiting: it stays ready to install. Unless that
    /// check emptied the cache for a newer release before it failed: then nothing waits any more.
    private func fail(_ message: String) {
        if let version = environment.defaults.string(forKey: Key.stagedVersion), let path = stagedPath, environment.stagedExists(path) {
            state = .ready(version)
        } else {
            forgetStaged()
            state = .failed(message)
        }
    }

    private func answered() {
        lastAnswer = environment.now()
        environment.defaults.set(lastAnswer, forKey: Key.lastAnswer)
    }

    /// Installs a waiting update when nothing would be interrupted: the vault locked, no window open.
    func installIfIdle() {
        guard automatic, case .ready = state, !handedOff, environment.isIdle() else { return }
        restartToUpdate()
    }

    /// Restart to Update in Preferences, and what `installIfIdle` does: hand the staged app to the updater and quit.
    func restartToUpdate() {
        guard !handedOff, handOff(relaunch: true) else { return }
        environment.quit()
    }

    /// Quit with an update waiting: it goes in, and the app does not come back by itself.
    func appWillTerminate() {
        guard automatic, !handedOff else { return }
        _ = handOff(relaunch: false)
    }

    /// At launch, before anything shows: true when a waiting update was handed to the updater, and the caller exits.
    func installAtLaunch() -> Bool {
        guard automatic else { return false }
        return handOff(relaunch: true)
    }

    /// The staged path is forgotten before the updater gets it, so a failed install is tried once and not at every start;
    /// the next weekly check stages it again.
    private func handOff(relaunch: Bool) -> Bool {
        guard case .ready = state, let path = stagedPath else { return false }
        forgetStaged()
        guard environment.install(path, relaunch) else {
            state = .failed("The updater could not be started.")
            return false
        }
        handedOff = true
        state = .idle
        return true
    }

    /// The line under Update automatically in Preferences.
    var statusLine: String {
        switch state {
        case .checking:
            return "Checking…"
        case .ready(let version):
            return automatic
                ? "PasswordPie \(version) is ready. It installs the next time PasswordPie is locked."
                : "PasswordPie \(version) is ready. Press Restart to Update to install it."
        case .available(let version):
            return "PasswordPie \(version) is available, but this copy cannot replace itself. Download it instead."
        case .failed(let message):
            return "The last check failed: \(message)"
        case .unavailable:
            return "This build is not a release, so it does not update itself."
        case .idle:
            guard let lastAnswer else { return "PasswordPie \(environment.installedVersion). Not checked yet." }
            let calendar = Calendar.current
            if calendar.isDate(lastAnswer, inSameDayAs: environment.now()) {
                return "PasswordPie \(environment.installedVersion) is up to date. Checked today."
            }
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return "PasswordPie \(environment.installedVersion) is up to date. Checked \(formatter.string(from: lastAnswer))."
        }
    }
}

extension UpdateCoordinator.Environment {
    /// `Contents/MacOS/PasswordPieUpdater`, next to the app's own executable.
    static var updaterURL: URL? {
        guard let url = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("PasswordPieUpdater"),
              Bundle.main.bundleURL.pathExtension == "app",
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    /// The real thing. The updater gets no input but its arguments, and nothing of the vault.
    static func live(isIdle: @escaping () -> Bool) -> Self {
        let updater = updaterURL
        func process(_ arguments: [String]) -> Process? {
            guard let updater else { return nil }
            let process = Process()
            process.executableURL = updater
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            return process
        }
        return Self(
            defaults: .standard,
            now: Date.init,
            installedVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            hasUpdater: updater != nil,
            check: { completion in
                DispatchQueue.global(qos: .utility).async {
                    var output = Data()
                    if let process = process(["check"]) {
                        let pipe = Pipe()
                        process.standardOutput = pipe
                        if (try? process.run()) != nil {
                            output = pipe.fileHandleForReading.readDataToEndOfFile()
                            process.waitUntilExit()
                        }
                    }
                    let outcome = UpdateOutcome.parse(output)
                    DispatchQueue.main.async { completion(outcome) }
                }
            },
            install: { staged, relaunch in
                guard let process = process(["install", staged, String(getpid())] + (relaunch ? ["relaunch"] : [])) else { return false }
                process.standardOutput = FileHandle.nullDevice
                return (try? process.run()) != nil
            },
            stagedExists: { FileManager.default.fileExists(atPath: $0) },
            quit: { NSApp.terminate(nil) },
            isIdle: isIdle
        )
    }
}
#endif
