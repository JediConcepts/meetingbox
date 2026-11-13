import Foundation

// "Record a voice sample…" (spec 6.2): what records it, the states the sheet shows, and the private
// folder it is recorded into. Foundation only, so the native tests compile it; the microphone itself is
// MicSampleRecorder (MicSample.swift), which only the app builds.

/// Records the microphone alone into `<folder>/sample.caf` until `stop`. `started` comes on the main
/// queue: nil once it is capturing, or the reason it cannot (in Preferences' words); after nil it comes
/// at most once more, with a reason, if capturing then fails. `stop` returns at once and never blocks
/// its caller; `done` comes on the main queue once capturing has stopped and sample.caf is final.
protocol SampleRecorder: AnyObject {
    func start(folder: URL, microphone: String?, started: @escaping (String?) -> Void)
    func stop(_ done: @escaping () -> Void)
}

/// Where the sample stands, as the sheet shows it.
enum SampleState: Equatable {
    case idle
    /// Capturing, with the countdown.
    case recording(secondsLeft: Int)
    /// The engine is making the print from it.
    case building
    /// The engine's answer, in words.
    case done(String)
    case failed(String)

    /// How long the user reads aloud for.
    static let seconds = 90
}

/// The sample's private folder, `<state dir>/sample.XXXXXX` (made with mkdtemp, so 0700), and the only
/// folders meetingbox removes from the state folder: a real folder (never a link) named `sample.` and six
/// letters or digits, as mkdtemp makes them.
enum SampleFolder {
    static let audioName = "sample.caf"

    /// A new folder in `stateDir`, or nil when one cannot be made.
    static func make(in stateDir: URL) -> URL? {
        var template = Array(stateDir.appendingPathComponent("sample.XXXXXX").path.utf8CString)
        guard mkdtemp(&template) != nil else { return nil }
        return URL(fileURLWithPath: String(cString: template), isDirectory: true)
    }

    /// `sample.` and six ASCII letters or digits.
    static func isSampleName(_ name: String) -> Bool {
        guard name.hasPrefix("sample.") else { return false }
        let tail = name.dropFirst("sample.".count)
        return tail.count == 6 && tail.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }

    /// Removes `folder` if it is a sample folder: a real folder, not a link, with a sample folder's name.
    static func remove(_ folder: URL) {
        var info = stat()
        guard isSampleName(folder.lastPathComponent), lstat(folder.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// At launch: any sample folder a crash or a quit left in `stateDir`.
    static func removeLeftovers(in stateDir: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: stateDir.path)) ?? []
        for name in names where isSampleName(name) { remove(stateDir.appendingPathComponent(name, isDirectory: true)) }
    }
}
