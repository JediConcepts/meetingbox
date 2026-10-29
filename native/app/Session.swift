import Darwin
import Foundation

/// Starts and watches the recorder. `ChildRecorder` is the real one; tests use a fake.
protocol RecorderControl {
    /// Starts `--record` into `dir` and returns its pid. Each `health ...` line it prints goes to `onHealthLine`.
    func launch(dir: URL, mic: String?, onHealthLine: @escaping (String) -> Void) throws -> Int32
    func signal(_ pid: Int32, _ sig: Int32)
    func isRunning(_ pid: Int32) -> Bool
    /// The pid of a recorder writing into `dir`, found by its command line, even one this app did not start.
    func find(dir: URL) -> Int32?
    /// The exit status of a recorder this process started and that has exited, else nil.
    func exitStatus(_ pid: Int32) -> Int32?
    /// Runs `--recover dir`: true when the folder ends complete.
    func recover(dir: URL) -> Bool
    /// True when `.recording-complete` exists and the three `.m4a` open with matching durations.
    func verify(dir: URL) -> Bool
}

struct SessionError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Owns one recording's lifecycle: idle, recording, paused, finalising, and back to idle.
/// Writes the state files the command line reads (`recording.dir`, `paused`), adopts a recorder
/// left running by a crashed app, recovers dead and orphaned recordings, and queues a meeting only
/// once its audio verifies. Call it from one queue (the main queue in the app); a 1 s timer on that
/// queue drives `tick()`. Health lines may arrive on any thread.
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
    /// Off for an adopted recorder, whose stderr went with the app that started it.
    private var watchSilence = true
    /// Bumped per recording, so a late line from an earlier recorder is ignored.
    private var generation = 0

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
        let gen = resetHealth(watchSilence: true)
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
        FileManager.default.createFile(atPath: pausedFile.path, contents: Data(),
                                       attributes: [.posixPermissions: 0o600])
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
        var named: URL? = nil
        if let path = try? String(contentsOf: dirFile, encoding: .utf8),
           !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let dir = Session.folderURL(path.trimmingCharacters(in: .newlines))
            named = dir
            adoptNamed(dir)
        }
        for meeting in store.scan() where meeting.state == .recording || meeting.state == .finalising {
            // Spelt from the store's root, as `start` spelt it for the recorder's command line
            // (a directory listing may resolve /var to /private/var).
            let dir = Session.folderURL(store.root.appendingPathComponent(meeting.folder.url.lastPathComponent).path)
            if let n = named, Session.same(n, dir) { continue }
            if recorder.find(dir: dir) != nil { continue }
            let rec = recorder
            offQueue({ rec.recover(dir: dir) && rec.verify(dir: dir) }) { [weak self] ok in
                self?.record(dir, verified: ok, seconds: nil)
                self?.onFinished?(dir, ok)
            }
        }
    }

    private func adoptNamed(_ dir: URL) {
        let record = Session.readRecord(dir)
        if let state = record?.state, state != .recording && state != .finalising {
            // Already settled before the app went away; only the state files were left behind.
            clearStateFiles()
            return
        }
        let t = now()
        if let found = recorder.find(dir: dir) {
            pid = found
            started = record?.started ?? MeetingFolder.parse(dir)?.date ?? t
            pausedSeconds = record?.pausedSeconds ?? 0
            _ = resetHealth(watchSilence: false)
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
        } else {
            // The recorder died with the app: rebuild from the working files, or fail keeping them.
            frozenSeconds = record?.seconds ?? 0
            wait = nil
            set(.finalising(dir))
            settle(dir, tryClean: false)
        }
    }

    // MARK: the 1 s tick

    /// Drives the finalising wait, health, the disk floor, and a recorder that died on its own.
    func tick() {
        switch phase {
        case .idle:
            return
        case .recording(let dir), .paused(let dir):
            if !recorder.isRunning(pid) {
                beginFinalising(dir) // died on its own: handled as a stop
                advanceFinalising(dir)
                return
            }
            let free = freeBytes()
            if free < Session.stopFloor {
                try? store.update(dir) { $0.error = Session.diskStopped }
                stop()
                return
            }
            let t = now()
            healthLock.lock()
            disk = free < Session.lowFloor ? .low : .ok
            if watchSilence && t.timeIntervalSince(lastLine) >= Session.silenceLimit {
                if mic != .error { mic = .stalled }
                if system != .error { system = .stalled }
            }
            healthLock.unlock()
        case .finalising(let dir):
            advanceFinalising(dir)
        }
    }

    // MARK: finalising

    /// 60 s plus 1 s per recorded minute: finalise encodes at about 37 s per recorded hour.
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

    private func advanceFinalising(_ dir: URL) {
        guard let w = wait else { return }
        if !recorder.isRunning(pid) {
            let status = recorder.exitStatus(pid)
            settle(dir, tryClean: status == nil || status == 0)
            return
        }
        let t = now()
        switch w {
        case .exiting(let since):
            if t.timeIntervalSince(since) >= exitLimit {
                recorder.signal(pid, SIGTERM)
                wait = .terminating(since: t)
            }
        case .terminating(let since):
            if t.timeIntervalSince(since) >= Session.killGrace {
                recorder.signal(pid, SIGKILL)
                settle(dir, tryClean: false) // recovery waits for the dying recorder's folder lock
            }
        }
    }

    /// Verified audio is queued; anything else goes through recovery, then is queued only if it
    /// verifies, else failed with every file kept.
    private func settle(_ dir: URL, tryClean: Bool) {
        wait = nil
        let rec = recorder
        offQueue({ (tryClean && rec.verify(dir: dir)) || (rec.recover(dir: dir) && rec.verify(dir: dir)) }) {
            [weak self] ok in self?.finish(dir, verified: ok)
        }
    }

    private func finish(_ dir: URL, verified: Bool) {
        guard phase == .finalising(dir) else { return }
        record(dir, verified: verified, seconds: frozenSeconds)
        clearStateFiles()
        _ = resetHealth(watchSilence: true)
        set(.idle)
        onFinished?(dir, verified)
    }

    private func record(_ dir: URL, verified: Bool, seconds: Int?) {
        try? store.update(dir) { r in
            if let s = seconds { r.seconds = s }
            if verified {
                r.state = .queued
            } else {
                r.state = .failed
                r.error = Session.interrupted
            }
        }
    }

    // MARK: helpers

    private func set(_ p: Phase) {
        phase = p
        if p == .idle {
            timer?.cancel()
            timer = nil
        } else if timer == nil, let q = tickQueue {
            let source = DispatchSource.makeTimerSource(queue: q)
            source.schedule(deadline: .now() + 1, repeating: 1)
            source.setEventHandler { [weak self] in self?.tick() }
            source.resume()
            timer = source
        }
        onChange?(p)
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
    private func resetHealth(watchSilence watch: Bool) -> Int {
        healthLock.lock()
        defer { healthLock.unlock() }
        generation += 1
        mic = .ok
        system = .ok
        disk = .ok
        lastLine = now()
        watchSilence = watch
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
    private func writeStateFiles(_ dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: stateDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.removeItem(at: pausedFile)
        try Data(dir.path.utf8).write(to: dirFile, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dirFile.path)
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
