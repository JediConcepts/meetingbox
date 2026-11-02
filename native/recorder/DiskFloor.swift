import Foundation

/// The recorder's own backstop against a full disk. The app stops a recording when under 200 MB
/// is free, but a recorder whose app has gone (crashed, quit with "keep recording", not
/// reopened) would run until the disk is full and the working files stopped growing. So the
/// recorder checks the free space of its output volume about every 10 s and, below 100 MB,
/// writes one line to stderr and stops itself exactly as on SIGINT. With the app running the
/// app's higher floor is reached first, so the app stops it and records the reason.
///
/// The floor, the interval and the free-space source can be given, so a test never needs a real
/// full disk.
final class DiskFloor: @unchecked Sendable {
    /// Decimal units, as Finder shows free space.
    static let bytes: Int64 = 100_000_000
    static let interval: TimeInterval = 10
    /// Read back by the app from capture.log as the recorder's reason for stopping.
    static let message = "stopped: the disk is nearly full"

    private let directory: URL
    private let floor: Int64
    private let interval: TimeInterval
    private let freeBytes: (URL) -> Int64?
    private let report: (String) -> Void
    private let onLow: () -> Void
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var finished = false

    /// `directory` is the recorder's output folder. `onLow` runs once, after `report` has been
    /// given `message`. `report` is where the line goes: stderr in the recorder.
    init(directory: URL, floor: Int64 = DiskFloor.bytes, interval: TimeInterval = DiskFloor.interval,
         freeBytes: @escaping (URL) -> Int64? = DiskFloor.freeBytes(near:),
         report: @escaping (String) -> Void = eprint, onLow: @escaping () -> Void) {
        self.directory = directory
        self.floor = floor
        self.interval = interval
        self.freeBytes = freeBytes
        self.report = report
        self.onLow = onLow
    }

    /// Checks now, then every `interval`, until the disk is low or `cancel()`.
    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil, !finished else { return }
        let source = DispatchSource.makeTimerSource(queue: .global())
        source.schedule(deadline: .now(), repeating: interval)
        source.setEventHandler { [weak self] in self?.check() }
        timer = source
        source.resume()
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        finished = true
        timer?.cancel()
        timer = nil
    }

    /// One check. Below the floor it says so and asks for the stop, once; space that cannot be
    /// read is not a reason to stop a recording.
    func check() {
        lock.lock()
        let done = finished
        lock.unlock()
        guard !done, let free = freeBytes(directory), free < floor else { return }
        lock.lock()
        let first = !finished
        finished = true
        timer?.cancel()
        timer = nil
        lock.unlock()
        guard first else { return }
        report(DiskFloor.message)
        onLow()
    }

    /// Free bytes on the volume holding `url`, or on its nearest existing parent; nil when unreadable.
    static func freeBytes(near url: URL) -> Int64? {
        var dir = url
        while !FileManager.default.fileExists(atPath: dir.path), dir.pathComponents.count > 1 {
            dir = dir.deletingLastPathComponent()
        }
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: dir.path)
        return (attrs?[.systemFreeSize] as? NSNumber)?.int64Value
    }
}
