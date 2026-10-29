import Darwin
import Foundation

/// Starts and watches the recorder. `ChildRecorder` is the real one; tests use a fake.
protocol RecorderControl {
    /// Starts `--record` into `dir` and returns its pid. Each `health ...` line it prints goes to `onHealthLine`.
    func launch(dir: URL, mic: String?, onHealthLine: @escaping (String) -> Void) throws -> Int32
    /// Follows the capture.log of a recorder this app did not start, from its current end.
    func attach(dir: URL, onHealthLine: @escaping (String) -> Void)
    /// Reads what the recorder in `dir` has logged since the last call and passes on its health lines.
    func pollLog(dir: URL)
    /// The last line the recorder in `dir` logged that is not a health line.
    func lastMessage(dir: URL) -> String?
    func signal(_ pid: Int32, _ sig: Int32)
    func isRunning(_ pid: Int32) -> Bool
    /// A recorder writing into `dir`, found by its command line, even one this app did not start;
    /// `unknown` when that cannot be told.
    func find(dir: URL) -> FindResult
    /// The exit status of a recorder this process started and that has exited, else nil.
    func exitStatus(_ pid: Int32) -> Int32?
    /// Runs `--recover dir`.
    func recover(dir: URL) -> RecoverResult
    /// The duration of `audio.m4a` when `.recording-complete` exists and the three `.m4a` open with
    /// matching durations; nil when they do not verify.
    func verify(dir: URL) -> Double?
}

enum FindResult: Equatable { case found(Int32), notFound, unknown }

/// `busy`: another process holds the folder (`--recover` exited 75), so nothing is known about it.
enum RecoverResult: Equatable { case recovered, failed, busy }

struct SessionError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Owns one recording's lifecycle: idle, recording, paused, finalising, and back to idle.
/// Writes the state files the command line reads (`recording.dir`, `paused`), adopts a recorder
/// left running by a crashed app, recovers dead and orphaned recordings, and queues a meeting only
/// once its audio verifies. Call it from one queue (the main queue in the app); a 1 s timer on that
/// queue drives `tick()`, which also reads the recorder's capture.log for health lines.
/// When it cannot tell whether a recorder is alive (`find` is unknown) or another process holds a
/// folder (`recover` is busy), it changes nothing and tries again later.
final class Session {
    enum Phase: Equatable {
        case idle, recording(URL), paused(URL), finalising(URL)

        var folder: URL? {
            switch self {
            case .idle: return nil
            case .recording(let u), .paused(let u), .finalising(let u): return u
            }
        }
    }
    enum StreamHealth: String { case ok, stalled, error }
    enum DiskHealth { case ok, low }
    struct Health: Equatable {
        var mic: StreamHealth
        var system: StreamHealth
        var disk: DiskHealth
    }

    // Disk floors in decimal units, as Finder shows free space.
    static let startFloor: Int64 = 2_000_000_000
    static let lowFloor: Int64 = 1_000_000_000
    static let stopFloor: Int64 = 200_000_000
    /// No health line for this long means both streams are stalled.
    static let silenceLimit: TimeInterval = 10
    /// After SIGTERM, this long before SIGKILL.
    static let killGrace: TimeInterval = 10
    static let interrupted = "the recording was interrupted; its files are kept"
    static let diskStopped = "recording stopped because the disk was nearly full (under 200 MB free)"
    static let diskStoppedFailed = "recording stopped because the disk was nearly full; the recording was interrupted; its files are kept"

    private(set) var phase: Phase = .idle
    var onChange: ((Phase) -> Void)?
    /// The folder, and whether its audio verified (queued) or not (failed).
    var onFinished: ((URL, Bool) -> Void)?

    private let stateDir: URL
    private let recorder: RecorderControl
    private let store: MeetingStore
    private let now: () -> Date
    private let freeBytes: () -> Int64
    private let tickQueue: DispatchQueue?
    private let workQueue: DispatchQueue?
    private var timer: DispatchSourceTimer?

    // The current recording.
    private var pid: Int32 = 0
    /// The recorder was found running, not started here: its pid is not our child.
    private var adopted = false
    /// The session stopped itself for lack of disk space.
    private var diskStop = false
    private var started = Date()
    private var pausedSeconds = 0
    private var pausedAt: Date?
    private var frozenSeconds = 0

    /// Where finalising has got to. Nil while recovery or verification is running.
    private enum Wait { case exiting(since: Date), terminating(since: Date) }
    private var wait: Wait?

    // Health, written by the recorder's stderr reader on its own thread.
    private let healthLock = NSLock()
    private var mic = StreamHealth.ok
    private var system = StreamHealth.ok
    private var disk = DiskHealth.ok
    private var lastLine = Date()
    /// Bumped per recording, so a late line from an earlier recorder is ignored.
    private var generation = 0

    /// `adopt` could not tell whether a recorder was alive; the tick tries again.
    private var needsAdopt = false
    /// Orphans whose recovery is running, so a second `adopt` does not start another.
    private var orphansInFlight: Set<String> = []

    /// What finalising came to. `busy`: another process holds the folder, so nothing is written.
    private enum Outcome: Equatable { case verified(seconds: Int?), failed, busy }
    /// `tickQueue` runs the 1 s timer and receives finished background work; nil means no timer
    /// (tests call `tick()`). `workQueue` runs recovery and verification off that queue; nil runs
    /// them inline.
    init(stateDir: URL, recorder: RecorderControl, store: MeetingStore, now: @escaping () -> Date,
         freeBytes: @escaping () -> Int64, tickQueue: DispatchQueue? = .main,
         workQueue: DispatchQueue? = DispatchQueue(label: "meetingbox.session.work")) {
        self.stateDir = stateDir
        self.recorder = recorder
        self.store = store
        self.now = now
        self.freeBytes = freeBytes
        self.tickQueue = tickQueue
        self.workQueue = workQueue
    }

    deinit { timer?.cancel() }

    var health: Health {
        healthLock.lock()
        defer { healthLock.unlock() }
        return Health(mic: mic, system: system, disk: disk)
    }

    // MARK: start, pause, resume, stop

    /// Makes a new meeting folder, writes `recording.dir` and `meeting.json`, then launches the recorder.
    @discardableResult
    func start(root: URL, mic: String?) throws -> URL {
        if let dir = phase.folder { throw SessionError("already recording in \(dir.path)") }
        // A recorder this session has not adopted (yet) may still be writing where recording.dir points.
        if let named = namedFolder(), recorder.find(dir: named) != .notFound {
            throw SessionError("already recording in \(named.path)")
        }
        guard freeBytes() >= Session.startFloor else {
            throw SessionError("not enough free disk space to record (2 GB needed)")
        }
        let t = now()
        let dir = Session.folderURL(try MeetingFolder.create(in: root, at: t).path)
        try writeStateFiles(dir)
        do {
            try store.update(dir) { r in
                r.id = UUID().uuidString
                r.started = t
                r.seconds = 0
                r.pausedAt = nil
                r.pausedSeconds = nil
                r.error = nil
                r.state = .recording
            }
        } catch {
            clearStateFiles()
            throw error
        }
        let gen = resetHealth()
        let newPid: Int32
        do {
            newPid = try recorder.launch(dir: dir, mic: mic) { [weak self] line in self?.healthLine(line, gen) }
        } catch {
            clearStateFiles()
            // Never left saying recording, or the next launch would take it for an orphan.
            try? store.update(dir) { $0.state = .failed; $0.error = error.localizedDescription }
            throw error
        }
        pid = newPid
        adopted = false
        diskStop = false
        started = t
        pausedSeconds = 0
        pausedAt = nil
        set(.recording(dir))
        return dir
    }

    func pause() {
        guard case .recording(let dir) = phase else { return }
        let t = now()
        recorder.signal(pid, SIGUSR1)
        try? MeetingStore.writePrivately(Data(), to: pausedFile)
        pausedAt = t
        try? store.update(dir) { $0.pausedAt = t }
        set(.paused(dir))
    }

    func resume() {
        guard case .paused(let dir) = phase else { return }
        let t = now()
        recorder.signal(pid, SIGUSR2)
        try? FileManager.default.removeItem(at: pausedFile)
        foldPause(at: t)
        let total = pausedSeconds
        try? store.update(dir) { $0.pausedAt = nil; $0.pausedSeconds = total }
        set(.recording(dir))
    }

    /// Sends SIGINT and moves to finalising at once. The meeting is queued only when the recorder
    /// has exited and its audio verifies, or recovery has made it verify.
    @discardableResult
    func stop() -> URL? {
        switch phase {
        case .idle:
            return nil
        case .finalising(let dir):
            return dir
        case .recording(let dir), .paused(let dir):
            recorder.signal(pid, SIGINT)
            beginFinalising(dir)
            return dir
        }
    }

    /// Recorded time only: pauses do not count, and the clock stops at stop.
    func recordedSeconds(at date: Date) -> Int {
        switch phase {
        case .idle:
            return 0
        case .finalising:
            return frozenSeconds
        case .recording, .paused:
            let end = pausedAt.map { min($0, date) } ?? date
            return max(0, Int(end.timeIntervalSince(started)) - pausedSeconds)
        }
    }

    // MARK: adopt

    /// At launch: takes up the recording `recording.dir` names (alive: carry on; dead: recover),
    /// then recovers every orphan, a meeting still marked recording or finalising that nothing is
    /// recording any more.
    func adopt() {
        guard phase == .idle else { return }
        needsAdopt = false
        let named = namedFolder()
        if let dir = named { adoptNamed(dir) }
        for meeting in store.scan() where meeting.state == .recording || meeting.state == .finalising {
            // Spelt from the store's root, as `start` spelt it for the recorder's command line
            // (a directory listing may resolve /var to /private/var).
            let dir = Session.folderURL(store.root.appendingPathComponent(meeting.folder.url.lastPathComponent).path)
            if let n = named, Session.same(n, dir) { continue }
            if orphansInFlight.contains(dir.path) { continue }
            switch recorder.find(dir: dir) {
            case .found: continue
            case .unknown: needsAdopt = true; continue
            case .notFound: break
            }
            orphansInFlight.insert(dir.path)
            let rec = recorder
            offQueue({ Session.finalise(rec, dir, tryClean: false) }) { [weak self] outcome in
                guard let self = self else { return }
                self.orphansInFlight.remove(dir.path)
                switch outcome {
                case .busy:
                    return // someone else is finalising it; a later adopt looks again
                case .verified(let seconds):
                    self.record(dir, verified: true, seconds: seconds, reason: nil)
                    self.onFinished?(dir, true)
                case .failed:
                    self.record(dir, verified: false, seconds: nil, reason: Session.interrupted)
                    self.onFinished?(dir, false)
                }
            }
        }
        updateTimer()
    }

    private func adoptNamed(_ dir: URL) {
        // Only a meeting folder in the store is ever recovered or written to.
        guard MeetingFolder.parse(dir) != nil, Session.same(dir.deletingLastPathComponent(), store.root) else {
            clearStateFiles()
            return
        }
        let record = Session.readRecord(dir)
        if let state = record?.state, state != .recording && state != .finalising {
            // Already settled before the app went away; only the state files were left behind.
            clearStateFiles()
            return
        }
        let t = now()
        let found: Int32
        switch recorder.find(dir: dir) {
        case .unknown:
            needsAdopt = true // cannot tell: change nothing, try again on the next tick
            return
        case .notFound:
            // The recorder died with the app: rebuild from the working files, or fail keeping them.
            adopted = true
            diskStop = record?.error == Session.diskStopped
            frozenSeconds = record?.seconds ?? 0
            wait = nil
            set(.finalising(dir))
            settle(dir, tryClean: false, exitStatus: nil)
            return
        case .found(let p):
            found = p
        }
        pid = found
        adopted = true
        diskStop = record?.error == Session.diskStopped
        started = record?.started ?? MeetingFolder.parse(dir)?.date ?? t
        pausedSeconds = record?.pausedSeconds ?? 0
        let gen = resetHealth()
        recorder.attach(dir: dir) { [weak self] line in self?.healthLine(line, gen) }
        if record?.state == .finalising {
            // The app went away after SIGINT; the recorder is still finalising.
            pausedAt = nil
            frozenSeconds = record?.seconds ?? 0
            wait = .exiting(since: t)
            set(.finalising(dir))
            return
        }
        let paused = FileManager.default.fileExists(atPath: pausedFile.path)
        pausedAt = paused ? (record?.pausedAt ?? t) : nil
        let (s, ps, pa) = (started, pausedSeconds, pausedAt)
        try? store.update(dir) { r in
            r.state = .recording
            r.started = s
            r.pausedSeconds = ps
            r.pausedAt = pa
        }
        set(paused ? .paused(dir) : .recording(dir))
    }

    // MARK: the 1 s tick

    /// Drives the finalising wait, health, the disk floor, and a recorder that died on its own.
    func tick() {
        guard let folder = phase.folder else {
            if needsAdopt { adopt() }
            return
        }
        // Liveness first: a recorder already gone has written all it will, so the read below has it.
        let alive = recorder.isRunning(pid)
        recorder.pollLog(dir: folder)
        switch phase {
        case .idle:
            return
        case .recording(let dir), .paused(let dir):
            if !alive {
                beginFinalising(dir) // died on its own: handled as a stop
                advanceFinalising(dir, alive: false)
                return
            }
            let free = freeBytes()
            if free < Session.stopFloor {
                diskStop = true
                try? store.update(dir) { $0.error = Session.diskStopped }
                stop()
                return
            }
            let t = now()
            healthLock.lock()
            disk = free < Session.lowFloor ? .low : .ok
            if t.timeIntervalSince(lastLine) >= Session.silenceLimit {
                if mic != .error { mic = .stalled }
                if system != .error { system = .stalled }
            }
            healthLock.unlock()
        case .finalising(let dir):
            advanceFinalising(dir, alive: alive)
        }
    }

    // MARK: finalising

    /// 60 s plus 1 s per recorded minute: finalise encodes at about 37 s per recorded hour.
    /// After it, SIGTERM, 10 s, SIGKILL, then recovery. The real recorder ignores SIGTERM once it is
    /// finalising (its stop handlers are gone and the signal stays ignored), so the step that ends a
    /// stuck finalise is SIGKILL; recovery then redoes the work, which is safe to repeat.
    private var exitLimit: TimeInterval { TimeInterval(60 + frozenSeconds / 60) }

    private func beginFinalising(_ dir: URL) {
        let t = now()
        frozenSeconds = recordedSeconds(at: t)
        foldPause(at: t)
        wait = .exiting(since: t)
        let (secs, ps) = (frozenSeconds, pausedSeconds)
        try? store.update(dir) { r in
            r.state = .finalising
            r.seconds = secs
            r.pausedAt = nil
            r.pausedSeconds = ps
        }
        set(.finalising(dir))
    }

    private func advanceFinalising(_ dir: URL, alive: Bool) {
        guard let w = wait else { return }
        if !alive {
            let status = recorder.exitStatus(pid)
            settle(dir, tryClean: status == nil || status == 0, exitStatus: status)
            return
        }
        let t = now()
        switch w {
        case .exiting(let since):
            guard t.timeIntervalSince(since) >= exitLimit else { return }
            switch stillOurs(dir) {
            case true?:
                recorder.signal(pid, SIGTERM)
                wait = .terminating(since: t)
            case false?:
                settle(dir, tryClean: true, exitStatus: nil)
            case nil:
                break // cannot tell: try again on the next tick
            }
        case .terminating(let since):
            guard t.timeIntervalSince(since) >= Session.killGrace else { return }
            switch stillOurs(dir) {
            case true?:
                recorder.signal(pid, SIGKILL)
                settle(dir, tryClean: false, exitStatus: nil) // recovery waits for the dying recorder's folder lock
            case false?:
                settle(dir, tryClean: true, exitStatus: nil)
            case nil:
                break
            }
        }
    }

    /// Before SIGTERM or SIGKILL: our own child is ours; an adopted pid must still be the recorder
    /// writing into `dir`, or it has exited and the pid may belong to something else. Nil: cannot tell.
    private func stillOurs(_ dir: URL) -> Bool? {
        guard adopted else { return true }
        switch recorder.find(dir: dir) {
        case .found(let p): return p == pid
        case .notFound: return false
        case .unknown: return nil
        }
    }

    /// Verified audio is queued; anything else goes through recovery, then is queued only if it
    /// verifies, else failed with every file kept. A busy folder is left to whoever holds it.
    private func settle(_ dir: URL, tryClean: Bool, exitStatus: Int32?) {
        wait = nil
        let rec = recorder
        let failedExit = exitStatus.map { $0 != 0 } ?? false
        offQueue({ Session.finalise(rec, dir, tryClean: tryClean) }) { [weak self] outcome in
            self?.finish(dir, outcome, failedExit: failedExit)
        }
    }

    /// Runs on the work queue. The only route to `verified` is a `verify` that ran last.
    private static func finalise(_ rec: RecorderControl, _ dir: URL, tryClean: Bool) -> Outcome {
        if tryClean, rec.verify(dir: dir) != nil { return .verified(seconds: nil) }
        switch rec.recover(dir: dir) {
        case .busy: return .busy
        case .failed: return .failed
        case .recovered:
            // Recovered audio is the truth about how long the recording is (pauses are not in it).
            guard let duration = rec.verify(dir: dir) else { return .failed }
            return .verified(seconds: Int(duration.rounded()))
        }
    }

    private func finish(_ dir: URL, _ outcome: Outcome, failedExit: Bool) {
        guard phase == .finalising(dir) else { return }
        switch outcome {
        case .busy:
            break // another process owns the folder now: write nothing, keep no claim on it
        case .verified(let seconds):
            record(dir, verified: true, seconds: seconds ?? frozenSeconds, reason: nil)
        case .failed:
            record(dir, verified: false, seconds: frozenSeconds, reason: failureReason(dir, failedExit: failedExit))
        }
        clearStateFiles()
        _ = resetHealth()
        adopted = false
        diskStop = false
        set(.idle)
        if outcome != .busy { onFinished?(dir, outcome != .failed) }
    }

    /// The disk stop if that is what ended it; else what a recorder that failed said last; else the
    /// generic reason.
    private func failureReason(_ dir: URL, failedExit: Bool) -> String {
        if diskStop { return Session.diskStoppedFailed }
        if failedExit, let message = recorder.lastMessage(dir: dir) { return message }
        return Session.interrupted
    }

    /// Queued carries no error; failed carries the reason.
    private func record(_ dir: URL, verified: Bool, seconds: Int?, reason: String?) {
        try? store.update(dir) { r in
            if let s = seconds { r.seconds = s }
            if verified {
                r.state = .queued
                r.error = nil
            } else {
                r.state = .failed
                r.error = reason ?? Session.interrupted
            }
        }
    }

    // MARK: helpers

    private func set(_ p: Phase) {
        phase = p
        updateTimer()
        onChange?(p)
    }

    /// The timer runs while there is a recording, or an adopt to try again.
    private func updateTimer() {
        if phase == .idle && !needsAdopt {
            timer?.cancel()
            timer = nil
        } else if timer == nil, let q = tickQueue {
            let source = DispatchSource.makeTimerSource(queue: q)
            source.schedule(deadline: .now() + 1, repeating: 1)
            source.setEventHandler { [weak self] in self?.tick() }
            source.resume()
            timer = source
        }
    }

    private func foldPause(at t: Date) {
        if let p = pausedAt { pausedSeconds += max(0, Int(t.timeIntervalSince(p))) }
        pausedAt = nil
    }

    private func offQueue<T>(_ work: @escaping () -> T, then: @escaping (T) -> Void) {
        guard let wq = workQueue else { then(work()); return }
        let back = tickQueue ?? DispatchQueue.main
        wq.async {
            let result = work()
            back.async { then(result) }
        }
    }

    /// Resets health to ok for a new recording and returns its generation.
    private func resetHealth() -> Int {
        healthLock.lock()
        defer { healthLock.unlock() }
        generation += 1
        mic = .ok
        system = .ok
        disk = .ok
        lastLine = now()
        return generation
    }

    /// `health mic=<ok|stalled|error> system=<ok|stalled|error>`; anything else is ignored.
    private func healthLine(_ line: String, _ gen: Int) {
        let parts = line.split(separator: " ")
        guard parts.first == "health" else { return }
        var m: StreamHealth? = nil
        var s: StreamHealth? = nil
        for part in parts.dropFirst() {
            let kv = part.split(separator: "=", maxSplits: 1)
            guard kv.count == 2, let value = StreamHealth(rawValue: String(kv[1])) else { continue }
            if kv[0] == "mic" { m = value } else if kv[0] == "system" { s = value }
        }
        guard let micValue = m, let systemValue = s else { return }
        let t = now()
        healthLock.lock()
        if gen == generation {
            mic = micValue
            system = systemValue
            lastLine = t
        }
        healthLock.unlock()
    }

    private var dirFile: URL { stateDir.appendingPathComponent("recording.dir") }
    private var pausedFile: URL { stateDir.appendingPathComponent("paused") }

    /// `recording.dir` holds the folder's path with no newline, as the command line writes it.
    /// Written 0600 from the start, through a temp file renamed into place.
    private func writeStateFiles(_ dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: stateDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.removeItem(at: pausedFile)
        try MeetingStore.writePrivately(Data(dir.path.utf8), to: dirFile)
    }

    /// The folder `recording.dir` names, if it names one.
    private func namedFolder() -> URL? {
        guard let text = try? String(contentsOf: dirFile, encoding: .utf8) else { return nil }
        let path = text.trimmingCharacters(in: .newlines)
        guard !path.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return Session.folderURL(path)
    }

    /// Removes only the two fixed state files.
    private func clearStateFiles() {
        try? FileManager.default.removeItem(at: pausedFile)
        try? FileManager.default.removeItem(at: dirFile)
    }

    private static func readRecord(_ dir: URL) -> MeetingRecord? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("meeting.json")),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return MeetingRecord(json: obj)
    }

    /// Every folder Session hands out is in directory form (a trailing slash), as `MeetingStore.scan`
    /// gives it, so a phase compares equal to the same meeting found by a scan.
    static func folderURL(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }

    private static func same(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
