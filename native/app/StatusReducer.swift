import Foundation

// The rules that change the state the views show, apart from AppKit and Combine so they are
// tested: when the clock runs, when a failure or the ready meeting is set and when it goes.
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
    /// The user opened that meeting's minutes.
    case minutesOpened(URL)
    /// The user chose something in a menu or on the floating button.
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
            // A new recording is news enough: the last meeting's link and any old failure go. A
            // recording taken up as paused, or resumed, is not a new one. A failure is not cleared
            // when a recording ends, because a start that failed arrives after its recorder has died.
            if began, case .recording = new {
                ready = nil
                failure = nil
            }
            if !clockRuns { seconds = 0 }
        case .tick(let now, let current):
            guard clockRuns else { return } // a late tick after the stop
            seconds = now
            health = current
        case .processing(let url, let current):
            processing = url
            stage = current
        case .minutesReady(let dir):
            ready = dir
        case .minutesOpened(let dir):
            if ready == dir { ready = nil }
        case .acted:
            failure = nil
        case .failed(let what):
            failure = what
        }
    }
}

extension Failure {
    /// What a reply to `request` says to show. A start that failed, and a pause or resume that could
    /// not reach the recorder (the recording is not where the user put it, and they should know). Not
    /// the races, such as "not recording" after the recorder ended first, and never a stop: those are
    /// for the log.
    static func from(_ request: ControlRequest, reply: String) -> Failure? {
        guard reply.hasPrefix("error ") else { return nil }
        let reason = String(reply.dropFirst("error ".count))
        switch request {
        case .start:
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
