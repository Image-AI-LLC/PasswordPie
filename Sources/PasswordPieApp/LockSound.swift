import AppKit

/// The two padlock clicks. See `docs/UX.md`, "Lock".
enum LockSound {
    case lock
    case unlock

    fileprivate var resourceName: String {
        switch self {
        case .lock: "lock"
        case .unlock: "unlock"
        }
    }
}

/// Plays the padlock sounds of System Settings, which ship with macOS in SecurityInterface.framework.
/// They follow "Play user interface sound effects"; a Mac without the files stays quiet.
@MainActor
final class LockSoundPlayer {
    static let shared = LockSoundPlayer()

    /// The Sound settings switch "Play user interface sound effects", in the global domain. Absent means on.
    static let soundEffectsKey = "com.apple.sound.uiaudio.enabled"
    private static let framework = "/System/Library/Frameworks/SecurityInterface.framework"
    private static let volume: Float = 0.6

    /// Kept, so a sound is not released while it plays.
    private var sounds: [LockSound: NSSound] = [:]

    static func url(for sound: LockSound) -> URL? {
        Bundle(path: framework)?.url(forResource: sound.resourceName, withExtension: "aif")
    }

    static func soundEffectsEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: soundEffectsKey) as? NSNumber)?.boolValue ?? true
    }

    func play(_ sound: LockSound) {
        guard Self.soundEffectsEnabled() else { return }
        if sounds[sound] == nil, let url = Self.url(for: sound), let loaded = NSSound(contentsOf: url, byReference: true) {
            loaded.volume = Self.volume
            sounds[sound] = loaded
        }
        guard let player = sounds[sound] else { return }
        player.stop()
        player.play()
    }
}
