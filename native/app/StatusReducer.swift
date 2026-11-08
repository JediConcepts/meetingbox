import Foundation

// The rules that change the state the views show, apart from AppKit and Combine so they are
// tested: when the clock runs, when a failure or the line about a meeting is set and when it goes.
// `AppModel` keeps one `StatusInput`, feeds it these events, and draws what comes out. Foundation only.

enum StatusEvent {
    /// The session moved to this phase.
    case phase(Session.Phase)
    /// The clock ticked: the recorded seconds and the capture health, read from the session.
    case tick(seconds: Int, health: Session.Health)
    /// The processing queue's current job and its stage.
    case processing(URL?, stage: String?)
    /// A job finished and its minutes are written.
    case minutesReady(URL)
    /// A recording ended without being asked to: its folder and why.
    case recordingStopped(URL, reason: String)
    /// A meeting was left unfinished: its minutes could not be written, or its recording could not be
    /// finished. `line` says which (`StatusPresentation.minutesNotWritten`, `recordingNotFinished`).
    case unfinished(URL, line: String)
    /// The user opened that meeting in the window (its menu line, or the window coming forward on it).
    case minutesOpened(URL)
    /// The user chose something in a menu or on the floating button, or a command over the socket
    /// acted on the recording (start, stop, pause or resume).
    case acted
    /// What they asked for did not happen.
    case failed(Failure)
}

extension StatusInput {
    /// The clock (a 1 s timer reading the session) runs while there is a recording or a pause to time.
    var clockRuns: Bool {
        switch phase {
        case .recording, .paused: return true
        case .idle, .finalising: return false
        }
    }

    mutating func apply(_ event: StatusEvent) {
        switch event {
        case .phase(let new):
            let began = phase == .idle
            phase = new
            // A new recording is news enough: the line about the last meeting and any old failure go.
            // A recording taken up as paused, or resumed, is not a new one. A failure is not cleared
            // when a recording ends, because a start that failed arrives after its recorder has died.
            // The one exception is the refusal while the last recording was being saved: it is about
            // that save, so it goes as soon as the session is anything but finalising.
            if began, case .recording = new {
                notice = nil
                failure = nil
            }
            if failure == Failure.stillSaving {
                switch new {
                case .finalising: break
                case .idle, .recording, .paused: failure = nil
                }
            }
            if !clockRuns { seconds = 0 }
        case .tick(let now, let current):
            guard clockRuns else { return } // a late tick after the stop
            seconds = now
            health = current
        case .processing(let url, let current):
            processing = url
            stage = current
        // One line about a meeting: the most recent of these wins.
        case .minutesReady(let dir):
            notice = Notice(kind: .minutesReady, folder: dir, line: StatusPresentation.minutesReady)
        case .recordingStopped(let dir, let reason):
            notice = Notice(kind: .recordingStopped, folder: dir, line: StatusPresentation.recordingStopped(reason))
        case .unfinished(let dir, let line):
            notice = Notice(kind: .unfinished, folder: dir, line: line)
        case .minutesOpened(let dir):
            if notice?.folder == dir { notice = nil }
        case .acted:
            failure = nil
        case .failed(let what):
            failure = what
        }
    }
}

extension Failure {
    /// What a reply to `request` says to show, with the session in `phase`. A start that failed, and a
    /// pause or resume that could not reach the recorder (the recording is not where the user put it,
    /// and they should know). Not the races, such as "not recording" after the recorder ended first, or
    /// a start that lost to another start and names the folder now recording or paused (that recording
    /// is fine), and never a stop: those are for the log.
    static func from(_ request: ControlRequest, reply: String, phase: Session.Phase = .idle) -> Failure? {
        guard reply.hasPrefix("error ") else { return nil }
        let reason = String(reply.dropFirst("error ".count))
        switch request {
        case .start:
            switch phase {
            case .recording(let live), .paused(let live):
                // "already recording in <folder>": the folder ends the reason (a longer neighbour,
                // such as <folder>-2, is another folder).
                if reason.hasSuffix(" " + live.path) { return nil }
            case .idle, .finalising:
                break
            }
            return Failure("start", reason)
        case .pause where reply == ControlHandler.cannotReach:
            return Failure("pause", reason)
        case .resume where reply == ControlHandler.cannotReach:
            return Failure("resume", reason)
        default:
            return nil
        }
    }
}

/// A failure the app shows, and whether the failure sound plays with it.
struct ShownFailure: Equatable {
    let failure: Failure
    let sound: Bool
}

extension Failure {
    /// The refusal of a start while the last recording is being saved, as it is shown: the reason
    /// `ControlHandler.stillSaving` carries.
    static let stillSaving = Failure("start", String(ControlHandler.stillSaving.dropFirst("error ".count)))

    /// What the app does with `reply` to `request` (for a toggle, the start or stop it became), with
    /// the session in `phase`: what `from` shows, the same for the menus and the socket, or nil (an
    /// error is then only logged). A failed start over the socket (the hotkey or the command) also plays
    /// the failure sound, since whoever pressed the hotkey is often not looking at the screen. Not the
    /// refusal while the last recording is saved (`ControlHandler.onRefused` has played it already),
    /// not a start from the menus or the floating button, and never a pause or resume.
    static func shown(_ request: ControlRequest, reply: String, phase: Session.Phase, overSocket: Bool) -> ShownFailure? {
        guard let failure = from(request, reply: reply, phase: phase) else { return nil }
        guard case .start = request else { return ShownFailure(failure: failure, sound: false) }
        return ShownFailure(failure: failure, sound: overSocket && reply != ControlHandler.stillSaving)
    }
}
