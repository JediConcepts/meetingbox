import Foundation

/// A stop is one request, whoever makes it: SIGINT, SIGTERM or the disk floor. The first reason
/// stands, and everything that follows is the same finalise, verify and marker. It is a type of
/// its own so a test can drive what `runRecorder` wires, with no recorder and no devices.
final class StopRequest: @unchecked Sendable {
    enum Reason: Equatable {
        case signal
        /// The recorder's own backstop: the output volume is nearly full.
        case diskFloor
    }

    private let lock = NSLock()
    private var first: Reason?
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream<Void>.makeStream()
    }

    /// Why the stop was asked for; nil until it is.
    var reason: Reason? {
        lock.lock()
        defer { lock.unlock() }
        return first
    }

    /// Asks for the stop. Only the first call does anything.
    func request(_ reason: Reason) {
        lock.lock()
        let isFirst = first == nil
        if isFirst { first = reason }
        lock.unlock()
        guard isFirst else { return }
        continuation.yield()
        continuation.finish()
    }

    /// Returns once a stop has been asked for (at once if it already has). Wait from one place only.
    func wait() async {
        for await _ in stream { break }
    }

    /// `handler` runs once the stop has been asked for.
    func onStop(_ handler: @escaping () -> Void) {
        continuation.onTermination = { _ in handler() }
    }
}

/// How a recording ended, after the capture stopped.
enum Ending: Equatable {
    case saved
    /// The stop came from the disk floor and there is not room to finalise: nothing was encoded,
    /// the working files are kept, and this is the line to print.
    case refused(String)
    /// Finalising failed; the working files are kept for `meetingbox recover`.
    case failed(String)
}

/// The end of a recording, as `runRecorder` calls it once the capture and the mixer have stopped:
/// closes the working files, then finalises, unless a stop from the disk floor finds less free space
/// than finalising needs. Blocks (finalising reads durations), so not from the concurrency pool.
func endRecording(output: RecordingOutput, stop: StopRequest, directory: URL,
                  freeBytes: (URL) -> Int64? = DiskFloor.freeBytes(near:)) -> Ending {
    output.close() // waits for the writer queue, so the seconds below are all there is
    if let line = DiskFloor.refusal(for: stop, directory: directory, secondsWritten: output.secondsWritten,
                                    freeBytes: freeBytes) {
        return .refused(line)
    }
    do {
        try output.finish()
        return .saved
    } catch {
        return .failed(error.localizedDescription)
    }
}
