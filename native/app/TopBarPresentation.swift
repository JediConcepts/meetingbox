import Foundation

// The window's top bar (spec 6.6): the recording's controls while one is under way, and a simple player
// for the selected meeting's audio. Which buttons show, which can be pressed, and their words, worked out
// from the arguments alone. Foundation only, so the native tests compile it; LibraryWindow draws it.

/// What the top bar shows now.
struct TopBar: Equatable {
    /// A button: its words, and whether it can be pressed.
    struct Control: Equatable {
        let title: String
        let enabled: Bool
    }

    /// While a recording runs or is paused, whichever meeting is selected: its time, Pause (Resume when
    /// paused) and Stop. Each is the menu bar's action of that name, done through `AppModel.perform`.
    struct Recording: Equatable {
        let timer: String
        let toggle: Control
        let toggleAction: MenuAction
        let stop: Control
        let stopAction: MenuAction
    }

    /// The player: Play or Pause, Stop (back to the start), the position and a slider to move it.
    struct Playback: Equatable {
        /// What Play, Pause and Stop act on: the file the player holds, else the selected meeting's audio.
        let file: URL
        let playing: Bool
        let toggle: Control
        let stop: Control
        /// "12:34 / 1:05:00", or the position alone when the length is not known.
        let position: String
        /// Why the file cannot be played, shown in place of the position.
        let problem: String?
        /// The slider moves the position only while the player holds the file.
        let canSeek: Bool
        let value: Double
        /// The slider's top: the length, and never 0, so its range is never empty.
        let length: Double
    }

    let recording: Recording?
    let player: Playback?
}

enum TopBarPresentation {
    static let play = "Play"
    static let pause = "Pause"
    static let stop = "Stop"
    static let cannotPlay = "This recording cannot be played"

    /// The bar for the session's `phase` and recorded `seconds`, whether a voice sample is being recorded,
    /// the player's state and position, the selected meeting's folder and audio, and the length to show.
    ///
    /// - The recording's controls show while a recording runs or is paused, whatever is selected.
    /// - The player shows for the selected meeting's audio, or for the file the player holds, so what
    ///   plays can always be paused and stopped.
    /// - Play is offered only while nothing records and no sample is taken: the recorder takes in the
    ///   Mac's own sound, and a sample the room's, so a meeting played then would be recorded too. It is
    ///   offered while the last recording is only being saved.
    static func bar(phase: Session.Phase, seconds: Int, sampling: Bool, player: PlayerState, selected: URL?, audio: URL?,
                    position: Double, duration: Double) -> TopBar {
        let recording: TopBar.Recording?
        switch phase {
        case .recording:
            recording = controls(seconds, toggle: .pause)
        case .paused:
            recording = controls(seconds, toggle: .resume)
        case .idle, .finalising:
            recording = nil
        }
        let held: URL?
        let playing: Bool
        switch player {
        case .playing(let url): (held, playing) = (url, true)
        case .paused(let url): (held, playing) = (url, false)
        case .idle, .failed: (held, playing) = (nil, false)
        }
        guard let file = held ?? (selected == nil ? nil : audio) else { return TopBar(recording: recording, player: nil) }
        let canPlay = recording == nil && !sampling
        let length = max(duration, 0)
        // Nothing loaded is at the start; a position outside the file is shown within it.
        let at = held == nil ? 0 : max(position, 0)
        let shown = length > 0 ? min(at, length) : at
        var problem: String? = nil
        if case .failed(let why) = player { problem = why }
        let playback = TopBar.Playback(
            file: file, playing: playing,
            toggle: playing ? TopBar.Control(title: pause, enabled: true) : TopBar.Control(title: play, enabled: canPlay),
            stop: TopBar.Control(title: stop, enabled: held != nil),
            position: length > 0 ? "\(time(shown)) / \(time(length))" : time(shown),
            problem: problem, canSeek: held != nil, value: shown, length: max(length, 1))
        return TopBar(recording: recording, player: playback)
    }

    private static func controls(_ seconds: Int, toggle: MenuAction) -> TopBar.Recording {
        TopBar.Recording(timer: Preferences.timerText(seconds), toggle: TopBar.Control(title: toggle.title, enabled: true), toggleAction: toggle,
                         stop: TopBar.Control(title: MenuAction.stop.title, enabled: true), stopAction: .stop)
    }

    /// `0:00`, `12:34`, `1:05:00`: whole seconds, rounded down.
    static func time(_ seconds: Double) -> String {
        let s = seconds.isFinite ? max(0, Int(seconds)) : 0
        let (h, m, sec) = (s / 3600, (s % 3600) / 60, s % 60)
        let two = { (n: Int) in n < 10 ? "0\(n)" : "\(n)" }
        return h > 0 ? "\(h):\(two(m)):\(two(sec))" : "\(m):\(two(sec))"
    }

    /// The length the bar shows: the file the player holds, once loaded, else the meeting's recorded length.
    static func length(loaded: Double, recorded: Int) -> Double {
        loaded > 0 ? loaded : Double(max(recorded, 0))
    }
}
