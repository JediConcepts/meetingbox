import Foundation

/// Where the floating record button shows.
enum FloatingMode: String, CaseIterable {
    case always, whileRecording, never
}

/// The app's settings, with their defaults, over a given `UserDefaults` (the app's own suite,
/// `com.jediconcepts.meetingbox`; tests give one in a temporary folder). Never read from `MB_*`
/// variables: the command's `--mic` and `--dir` travel inside each request instead.
final class Preferences {
    static let suiteName = "com.jediconcepts.meetingbox"

    private let defaults: UserDefaults
    private let home: URL

    init(defaults: UserDefaults, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.defaults = defaults
        self.home = home
    }

    /// The app's defaults: `.standard` when running as the bundle (whose domain is the suite),
    /// else the named suite.
    static func appDefaults(_ bundle: Bundle = .main) -> UserDefaults {
        if bundle.bundleIdentifier == suiteName { return .standard }
        return UserDefaults(suiteName: suiteName) ?? .standard
    }

    private enum Key {
        static let showMenuBar = "showMenuBar"
        static let floating = "floating"
        static let showInDock = "showInDock"
        static let openMinutes = "openMinutes"
        static let sounds = "sounds"
        static let meetingsFolder = "meetingsFolder"
        static let microphone = "microphone"
        static let floatingX = "floatingX"
        static let floatingY = "floatingY"
    }

    private func bool(_ key: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }

    var showMenuBar: Bool {
        get { bool(Key.showMenuBar, true) }
        set { defaults.set(newValue, forKey: Key.showMenuBar) }
    }

    var floating: FloatingMode {
        get { (defaults.string(forKey: Key.floating)).flatMap(FloatingMode.init(rawValue:)) ?? .whileRecording }
        set { defaults.set(newValue.rawValue, forKey: Key.floating) }
    }

    var showInDock: Bool {
        get { bool(Key.showInDock, true) }
        set { defaults.set(newValue, forKey: Key.showInDock) }
    }

    /// Open the minutes when they are ready (never while a recording is running).
    var openMinutes: Bool {
        get { bool(Key.openMinutes, true) }
        set { defaults.set(newValue, forKey: Key.openMinutes) }
    }

    /// The start, stop and done sounds.
    var sounds: Bool {
        get { bool(Key.sounds, true) }
        set { defaults.set(newValue, forKey: Key.sounds) }
    }

    /// Where new recordings go, and the library's folder. `~/Meetings` by default.
    var meetingsFolder: URL {
        get {
            if let path = defaults.string(forKey: Key.meetingsFolder), path.hasPrefix("/") {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return home.appendingPathComponent("Meetings", isDirectory: true)
        }
        set { defaults.set(newValue.path, forKey: Key.meetingsFolder) }
    }

    /// A microphone name to match, or nil for the system default.
    var microphone: String? {
        get { defaults.string(forKey: Key.microphone).flatMap { $0.isEmpty ? nil : $0 } }
        set {
            if let mic = newValue, !mic.isEmpty { defaults.set(mic, forKey: Key.microphone) }
            else { defaults.removeObject(forKey: Key.microphone) }
        }
    }

    /// Where the floating button was left, its lower left corner in screen coordinates (two Doubles);
    /// nil until it has been moved, or when what is stored is not a position.
    var floatingOrigin: CGPoint? {
        get {
            guard let x = defaults.object(forKey: Key.floatingX) as? Double, let y = defaults.object(forKey: Key.floatingY) as? Double,
                  x.isFinite, y.isFinite else { return nil }
            return CGPoint(x: x, y: y)
        }
        set {
            if let p = newValue {
                defaults.set(Double(p.x), forKey: Key.floatingX)
                defaults.set(Double(p.y), forKey: Key.floatingY)
            } else {
                defaults.removeObject(forKey: Key.floatingX)
                defaults.removeObject(forKey: Key.floatingY)
            }
        }
    }

    /// Recorded time as the timer shows it: `mm:ss` under an hour, then `h:mm:ss`.
    func formatTimer(_ seconds: Int) -> String { Preferences.timerText(seconds) }

    static func timerText(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let (h, m, sec) = (s / 3600, (s % 3600) / 60, s % 60)
        let two = { (n: Int) in n < 10 ? "0\(n)" : "\(n)" }
        return h > 0 ? "\(h):\(two(m)):\(two(sec))" : "\(two(m)):\(two(sec))"
    }
}
