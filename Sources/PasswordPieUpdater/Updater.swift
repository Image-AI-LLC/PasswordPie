import Darwin
import Foundation
import PasswordPieUpdate

// PasswordPie's updater, direct channel only: `Contents/MacOS/PasswordPieUpdater`. The app starts it; it holds none of
// the database code and is never given a secret. See docs/CHANNELS.md, "Updates".
//
//   PasswordPieUpdater check                                 prints one line of JSON (`UpdateOutcome`)
//   PasswordPieUpdater install <staged app> <pid> [relaunch]  waits for <pid> to exit, then replaces the app around it
@main
enum Updater {
    /// The `.app` this executable is inside. The updater updates that app and no other: no path to an app is taken from
    /// the command line.
    static func containingApp() -> URL? {
        guard var url = Bundle.main.executableURL?.resolvingSymlinksInPath().standardizedFileURL else { return nil }
        while url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
            if url.pathExtension == "app" { return url }
        }
        return nil
    }

    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let app = containingApp() else {
            print(UpdateOutcome(.notEligible).line())
            exit(0)
        }
        let cache = UpdateCheck.defaultCache()
        switch arguments.first {
        case "check" where arguments.count == 1:
            print(UpdateCheck(app: app, cache: cache, transport: GitHubTransport()).run().line())
            exit(0)
        case "install" where (3...4).contains(arguments.count) && (arguments.count == 3 || arguments[3] == "relaunch"):
            guard let pid = pid_t(arguments[2]), pid > 1 else { exit(64) }
            let relaunch = arguments.count == 4
            var status: Int32 = 1
            if UpdateInstall.waitForExit(of: pid, seconds: 30) {
                do {
                    try UpdateInstall(app: app, staged: URL(fileURLWithPath: arguments[1]), cache: cache).run()
                    status = 0
                } catch {
                    FileHandle.standardError.write(Data("PasswordPieUpdater: \(error)\n".utf8))
                }
                // The app was asked to quit for this. It comes back whether or not the update went in.
                if relaunch { open(app) }
            }
            exit(status)
        default:
            FileHandle.standardError.write(Data("usage: PasswordPieUpdater check | install <staged app> <pid> [relaunch]\n".utf8))
            exit(64)
        }
    }

    private static func open(_ app: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [app.path]
        try? process.run()
        process.waitUntilExit()
    }
}
