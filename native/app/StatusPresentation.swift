import Foundation

// What the menu bar item and the floating button show, decided here in plain values so every
// phase can be tested without AppKit. `StatusItem` and `FloatingPanel` only draw what
// `StatusPresentation` says, and `AppModel.perform` carries out the `MenuAction` they hand back.
// Foundation only.

/// The tint of the status symbol, and of the floating button's dot. `plain` is the system's own colour.
enum StatusTint: Equatable { case plain, red, amber }

/// What a menu entry or a floating button does.
enum MenuAction: Equatable {
    /// A line of information, not clickable.
    case info
    case separator
    case start, pause, resume, stop
    /// The folder of the recording in progress (or just stopped).
    case showFolder(URL)
    case openMeetingbox
    /// The notes of a meeting whose minutes are ready.
    case openMinutes(URL)
    case preferences
    case quit

    /// The words for the entry or the button's tooltip.
    var title: String {
        switch self {
        case .info, .separator: return ""
        case .start: return "Start recording"
        case .pause: return "Pause"
        case .resume: return "Resume"
        case .stop: return "Stop"
        case .showFolder: return "Show recording folder"
        case .openMeetingbox: return "Open meetingbox"
        case .openMinutes: return StatusPresentation.minutesReady
        case .preferences: return "Preferences…"
        case .quit: return "Quit meetingbox"
        }
    }
}

struct MenuEntry: Equatable {
    let title: String
    let enabled: Bool
    let action: MenuAction

    /// Two menus that differ at most in their titles: the open menu can be updated in place, with no
    /// item taken away from under the pointer.
    static func sameShape(_ a: [MenuEntry], _ b: [MenuEntry]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.enabled == $1.enabled && $0.action == $1.action }
    }
}

/// Something the user asked for that did not happen, shown until their next action: "Could not
/// start: <reason>", "Could not pause: ...", "Could not resume: ...".
struct Failure: Equatable {
    let action: String
    let reason: String

    init(_ action: String, _ reason: String) {
        self.action = action
        self.reason = reason
    }

    var line: String { "Could not \(action): \(reason)" }
}

/// The menu bar item itself: an SF Symbol, its tint, the timer beside it, and its tooltip.
struct StatusButton: Equatable {
    let symbol: String
    let tint: StatusTint
    let title: String
    let help: String
}

struct PanelPresentation: Equatable {
    let visible: Bool
    let dot: StatusTint
    let label: String
    /// Left to right: Record, or Pause or Resume then Stop, then the folder.
    let controls: [MenuAction]
    let help: String?
}

/// Everything the views depend on, and the state `StatusReducer.swift` keeps. `ready` is the
/// meeting whose minutes were finished last and not yet opened; `failure` is what the user asked for
/// last that did not work.
struct StatusInput: Equatable {
    var phase: Session.Phase = .idle
    var seconds = 0
    var health = Session.Health(mic: .ok, system: .ok, disk: .ok)
    var processing: URL? = nil
    var stage: String? = nil
    var ready: URL? = nil
    var failure: Failure? = nil
    var floating: FloatingMode = .whileRecording
    /// The preferences window exists (it does from Task 9).
    var preferencesAvailable = false
}

struct StatusPresentation: Equatable {
    static let writingMinutes = "Writing minutes"
    static let minutesReady = "Minutes ready"
    static let microphoneOK = "Microphone: capturing"
    static let microphoneBad = "Microphone: not receiving audio"
    static let systemOK = "System audio: capturing"
    static let systemBad = "System audio: not receiving audio"
    static let diskLow = "Disk space low"

    let button: StatusButton
    let menu: [MenuEntry]
    let panel: PanelPresentation

    init(_ i: StatusInput) {
        let recording: Bool, live: Bool, finalising: Bool
        switch i.phase {
        case .recording: (recording, live, finalising) = (true, true, false)
        case .paused: (recording, live, finalising) = (false, true, false)
        case .finalising: (recording, live, finalising) = (false, false, true)
        case .idle: (recording, live, finalising) = (false, false, false)
        }
        let healthy = i.health.mic == .ok && i.health.system == .ok && i.health.disk == .ok
        let busy = finalising || i.processing != nil
        let failure = i.failure
        let failureLine = failure?.line
        // A dot is red while recording and plain while paused; either turns amber when capture is wrong.
        let dot: StatusTint = live && !healthy ? .amber : (recording ? .red : .plain)
        let timer = Preferences.timerText(i.seconds)
        let busyHelp = (!finalising ? i.stage.map(ProcessingQueue.label) : nil) ?? StatusPresentation.writingMinutes

        // The status item. A failure wins; during a recording the timer stays beside the warning.
        if let line = failureLine {
            button = StatusButton(symbol: "exclamationmark.triangle", tint: .amber, title: live ? timer : "", help: line)
        } else if recording {
            button = StatusButton(symbol: "circle.fill", tint: dot, title: timer,
                                  help: healthy ? "Recording" : "Recording, but some audio is not arriving")
        } else if live {
            button = StatusButton(symbol: "pause.circle", tint: dot, title: timer,
                                  help: healthy ? "Paused" : "Paused, but some audio is not arriving")
        } else if busy {
            button = StatusButton(symbol: "ellipsis.circle", tint: .plain, title: StatusPresentation.writingMinutes, help: busyHelp)
        } else if i.ready != nil {
            button = StatusButton(symbol: "checkmark.circle", tint: .plain, title: StatusPresentation.minutesReady, help: StatusPresentation.minutesReady)
        } else {
            button = StatusButton(symbol: "record.circle", tint: .plain, title: "", help: "meetingbox")
        }

        // The menu: what is going on, then what can be done, then the app.
        func line(_ title: String) -> MenuEntry { MenuEntry(title: title, enabled: false, action: .info) }
        func item(_ action: MenuAction, enabled: Bool = true) -> MenuEntry { MenuEntry(title: action.title, enabled: enabled, action: action) }
        var info: [MenuEntry] = []
        if let failureLine = failureLine { info.append(line(failureLine)) }
        if live {
            info.append(line(i.health.mic == .ok ? StatusPresentation.microphoneOK : StatusPresentation.microphoneBad))
            info.append(line(i.health.system == .ok ? StatusPresentation.systemOK : StatusPresentation.systemBad))
            if i.health.disk == .low { info.append(line(StatusPresentation.diskLow)) }
        }
        if busy { info.append(line(StatusPresentation.writingMinutes)) }
        if let ready = i.ready { info.append(item(.openMinutes(ready))) }

        var controls: [MenuAction]
        switch i.phase {
        case .idle: controls = [.start]
        case .recording: controls = [.pause, .stop]
        case .paused: controls = [.resume, .stop]
        case .finalising: controls = []
        }
        var folder: [MenuAction] = []
        if let dir = i.phase.folder { folder = [.showFolder(dir)] }

        let groups: [[MenuEntry]] = [
            info,
            (controls + folder).map { item($0) },
            [item(.openMeetingbox), item(.preferences, enabled: i.preferencesAvailable)],
            [item(.quit)],
        ]
        var entries: [MenuEntry] = []
        for group in groups where !group.isEmpty {
            if !entries.isEmpty { entries.append(MenuEntry(title: "", enabled: false, action: .separator)) }
            entries += group
        }
        menu = entries

        // The floating button.
        let visible: Bool
        switch i.floating {
        case .always: visible = true
        case .whileRecording: visible = live
        case .never: visible = false
        }
        let label: String
        if live {
            label = timer
        } else if finalising {
            label = StatusPresentation.writingMinutes
        } else if let failure = failure {
            label = "Could not \(failure.action)"
        } else {
            label = busy ? StatusPresentation.writingMinutes : "Ready"
        }
        panel = PanelPresentation(visible: visible, dot: failure != nil ? .amber : dot, label: label, controls: controls + folder,
                                  help: failureLine)
    }
}

/// Where the floating button goes: the top right of the main screen the first time, and where the
/// user left it after that, unless that is no longer on any screen.
enum FloatingPlacement {
    static let size = CGSize(width: 220, height: 44)
    static let margin: CGFloat = 16
    /// Less than this showing on a screen and the button cannot be grabbed, so it is put back.
    static let reachable = CGSize(width: 60, height: 24)

    /// `screens` and `main` are visible frames (below the menu bar), in screen coordinates.
    static func origin(saved: CGPoint?, size: CGSize = size, screens: [CGRect], main: CGRect) -> CGPoint {
        if let saved = saved {
            let frame = CGRect(origin: saved, size: size)
            let grabbable = screens.contains { screen in
                let shared = frame.intersection(screen)
                return !shared.isNull && shared.width >= reachable.width && shared.height >= reachable.height
            }
            if grabbable { return saved }
        }
        return CGPoint(x: main.maxX - size.width - margin, y: main.maxY - size.height - margin)
    }
}
