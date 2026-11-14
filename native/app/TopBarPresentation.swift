import Foundation

// The window's top bar (spec 6.6): the recording's controls while one is under way, and a simple player
// for the selected meeting's audio. Which buttons show, which can be pressed, and their words, worked out
// from the arguments alone. Foundation only, so the native tests compile it; LibraryWindow draws it, and
// Player.swift is the part that plays.

/// Where the player stands, as the bar shows it.
enum PlayerState: Equatable {
    case idle
    case playing(URL)
    case paused(URL)
    /// Why the last file asked for cannot be played, in the bar's words.
    case failed(String)
}

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
        /// What Play, Pause and Stop act on: the file the player holds, else the selected meeting's audio;
        /// nil for a meeting with no audio, which says why instead.
        let file: URL?
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

    /// The bar for the session's `phase` and recorded `seconds`, whether the microphone or the Mac's sound
    /// may be being taken by something other than a recording (`sampling`: a voice sample, or a recorder
    /// not confirmed yet), the player's state and position, the selected meeting (`selected`, as
    /// `selected(_:files:)` gives it) and its audio, and the length to show.
    ///
    /// - The recording's controls show while a recording runs or is paused, whatever is selected.
    /// - The player shows for the file the player holds, so what plays can always be paused and stopped;
    ///   else for the selected meeting's audio; else, for a finished meeting other than the one being
    ///   recorded or saved, with Play disabled and "This recording cannot be played".
    /// - Play is offered only while the session is idle and nothing else takes the sound in: the recorder
    ///   takes in the Mac's own sound until it has stopped, and a sample the room's, so a meeting played
    ///   then would be recorded too.
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
        let file = held ?? audio
        if file == nil {
            // No audio: said only for a finished meeting the session is not on.
            guard let selected = selected, !(phase.folder.map { LibraryPresentation.samePlace($0, selected) } ?? false) else {
                return TopBar(recording: recording, player: nil)
            }
        }
        let canPlay = phase == .idle && !sampling && file != nil
        let length = max(duration, 0)
        // Nothing loaded is at the start; a position outside the file is shown within it.
        let at = held == nil ? 0 : max(position, 0)
        let shown = length > 0 ? min(at, length) : at
        var problem: String? = file == nil ? cannotPlay : nil
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

    /// The `selected` the bar is given: the selected meeting's folder once its files have been read and its
    /// recording is finished; nil while they are being read, for an unfinished recording, and with nothing
    /// selected. So missing audio is said only where audio belongs.
    static func selected(_ folder: URL?, files: MeetingFiles?) -> URL? {
        guard let files = files, !files.unfinished else { return nil }
        return folder
    }

    /// `0:00`, `12:34`, `1:05:00`: whole seconds, rounded down.
    static func time(_ seconds: Double) -> String {
        Preferences.timerText(seconds.isFinite && seconds > 0 ? Int(min(seconds, 1e9)) : 0, padMinutes: false)
    }

    /// The length the bar shows: the file the player holds, once loaded, else the meeting's recorded length.
    static func length(loaded: Double, recorded: Int) -> Double {
        loaded > 0 ? loaded : Double(max(recorded, 0))
    }
}
