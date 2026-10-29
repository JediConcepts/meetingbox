import Foundation

/// Whether each source is still delivering audio. Silence still arrives as buffers,
/// so a quiet microphone is ok; a source with no buffers for `stallAfter` seconds is
/// stalled, and one whose stream reported an error stays in error.
final class HealthMonitor: @unchecked Sendable {
    enum State: String {
        case ok, stalled, error
    }

    private let lock = NSLock()
    private let now: () -> Date
    private let stallAfter: TimeInterval
    private var lastBuffer: [Date]
    private var failed = [false, false]

    init(stallAfter: TimeInterval = 5, now: @escaping () -> Date = Date.init) {
        self.now = now
        self.stallAfter = stallAfter
        let start = now()
        lastBuffer = [start, start]
    }

    func buffer(from source: AudioSource) {
        lock.lock()
        defer { lock.unlock() }
        lastBuffer[source.rawValue] = now()
    }

    func error(from source: AudioSource) {
        lock.lock()
        defer { lock.unlock() }
        failed[source.rawValue] = true
    }

    func state(of source: AudioSource) -> State {
        lock.lock()
        defer { lock.unlock() }
        let i = source.rawValue
        if failed[i] { return .error }
        return now().timeIntervalSince(lastBuffer[i]) >= stallAfter ? .stalled : .ok
    }

    /// The line the recorder prints to stderr every 2 s.
    func line() -> String {
        "health mic=\(state(of: .mic).rawValue) system=\(state(of: .system).rawValue)"
    }
}
