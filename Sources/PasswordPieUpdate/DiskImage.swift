import Foundation

/// Mounts a disk image where nothing shows it: not in Finder, read-only, and no window opens.
public enum DiskImage {
    public static func attach(_ image: URL, at mountPoint: URL) throws {
        try hdiutil(["attach", image.path, "-mountpoint", mountPoint.path, "-nobrowse", "-readonly", "-noautoopen", "-quiet"])
    }

    public static func detach(_ mountPoint: URL) throws {
        try hdiutil(["detach", mountPoint.path, "-force", "-quiet"])
    }

    private static func hdiutil(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        // An image with a license would wait for an answer; ours has none, and one that does is not ours.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw UpdateError("The disk image could not be opened.")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError("The disk image could not be opened.") }
    }
}
