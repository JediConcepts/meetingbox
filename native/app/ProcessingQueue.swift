import Darwin
import Foundation

/// Runs `meetingbox process` for one meeting. Returns the worker's PID (or -1 when it could not be
/// started); `done` is called once, on any queue, with the exit status and the last stderr line.
/// `attempt` names this run: the script writes it into `.process-result`.
protocol PipelineRunner {
    func run(audio: URL, progress: URL, attempt: String, done: @escaping (Int32, String) -> Void) -> Int32
}

/// The real runner: `<MBScriptPath> process <audio>` with `MB_PROGRESS_FILE`, `MB_ATTEMPT`,
/// `MB_SOUNDS=0` and `MB_KEEP_AUDIO=1`, and `PATH` led by `~/.local/bin:/opt/homebrew/bin:/usr/local/bin`.
/// The app's own `MB_*` variables are not passed on: settings travel explicitly, never through the
/// environment. The script's stdout and stderr are `<dir>/.process-log` itself (0600, appended), not
/// a pipe, so the run carries on if the app goes away; the last line is read back from that file.
final class ScriptRunner: PipelineRunner {
    let script: URL
    private let home: URL
    private let environment: [String: String]

    init(script: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.script = script
        self.home = home
        self.environment = environment
    }

    /// The script named by `MBScriptPath` in the app's Info.plist.
    static func fromBundle(_ bundle: Bundle = .main) -> ScriptRunner? {
        guard let path = bundle.object(forInfoDictionaryKey: "MBScriptPath") as? String, !path.isEmpty else { return nil }
        return ScriptRunner(script: URL(fileURLWithPath: path))
    }

    func run(audio: URL, progress: URL, attempt: String, done: @escaping (Int32, String) -> Void) -> Int32 {
        var env = environment.filter { !$0.key.hasPrefix("MB_") }
        let lead = ["\(home.path)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"].joined(separator: ":")
        env["PATH"] = lead + ":" + (env["PATH"].flatMap { $0.isEmpty ? nil : $0 } ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        env["MB_PROGRESS_FILE"] = progress.path
        env["MB_ATTEMPT"] = attempt
        env["MB_SOUNDS"] = "0"
        env["MB_KEEP_AUDIO"] = "1" // a retry needs the audio: never let a run remove it

        let process = Process()
        process.executableURL = script
        process.arguments = ["process", audio.path]
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        let logURL = audio.deletingLastPathComponent().appendingPathComponent(ScriptRunner.logName)
        let fd = open(logURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else {
            let message = "could not start meetingbox: cannot write \(logURL.path)"
            DispatchQueue.global(qos: .utility).async { done(127, message) }
            return -1
        }
        fchmod(fd, 0o600)
        let from = lseek(fd, 0, SEEK_END) // this run's lines start here
        let log = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? log.close() } // the child has its own copy once it runs
        process.standardOutput = log
        process.standardError = log
        do {
            try process.run()
        } catch {
            let message = "could not start meetingbox: \(error.localizedDescription)"
            DispatchQueue.global(qos: .utility).async { done(127, message) }
            return -1
        }
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            let status = process.terminationReason == .uncaughtSignal ? 128 + process.terminationStatus : process.terminationStatus
            done(status, ScriptRunner.lastLine(ScriptRunner.tail(logURL, from: UInt64(max(0, from)))))
        }
        return pid
    }

    static let logName = ".process-log"

    /// What the log holds from `offset` on, at most the last 64 KB of it.
    private static func tail(_ url: URL, from offset: UInt64) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > offset else { return Data() }
        let start = max(offset, size > 65_536 ? size - 65_536 : 0)
        guard (try? handle.seek(toOffset: start)) != nil else { return Data() }
        return (try? handle.readToEnd()) ?? Data()
    }

    /// The last line with text, without colour codes or the script's "error" label.
    static func lastLine(_ data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        guard let line = text.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) }).last(where: { !$0.isEmpty }) else { return "" }
        return line.hasPrefix("error ") ? String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces) : line
    }
}

/// Reads `<dir>/.processing`, the lock `meetingbox process` holds (see the script for how it is
/// taken). Never writes or removes it: the script takes over a stale lock itself.
enum ProcessingLock {
    enum Owner: Equatable { case alive, gone, unknown }
    /// How long a lock with no owner file yet counts as held, after its change time.
    static let grace: TimeInterval = 10

    /// `gone` covers no lock and a stale one (owner dead, or its PID reused by another process).
    static func owner(_ dir: URL, ps: URL, now: Date) -> Owner {
        let lock = dir.appendingPathComponent(".processing")
        var st = stat()
        if lstat(lock.path, &st) != 0 { return errno == ENOENT ? .gone : .unknown }
        let text = (try? String(contentsOf: lock.appendingPathComponent("owner"), encoding: .utf8))?
            .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        if let space = text.firstIndex(of: " "), let pid = Int32(text[..<space]), pid > 0 {
            let start = text[text.index(after: space)...].trimmingCharacters(in: .whitespaces)
            guard let current = lstart(pid, ps: ps) else { return .unknown }
            return current == start ? .alive : .gone
        }
        // No owner yet, or one that cannot be read: held for the grace after the lock's change
        // time, then stale, as the script treats it.
        let changed = Date(timeIntervalSince1970: TimeInterval(st.st_ctimespec.tv_sec))
        return now.timeIntervalSince(changed) < grace ? .alive : .gone
    }

    /// `ps -o lstart=` for the PID: "" when nothing runs under it, nil when ps cannot tell.
    private static func lstart(_ pid: Int32, ps: URL) -> String? {
        let process = Process()
        let out = Pipe()
        process.executableURL = ps
        process.arguments = ["-o", "lstart=", "-p", String(pid)]
        // UTC, as the script reads it: ps prints local time, which differs between environments.
        process.environment = ["LC_ALL": "C", "TZ": "UTC0", "PATH": "/usr/bin:/bin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        switch process.terminationStatus {
        case 0: return text
        case 1: return text.isEmpty ? "" : nil // ps exits 1 when no such process
        default: return nil
        }
    }
}

/// `.process-result`: `attempt=<id> status=<n> started=<ISO 8601> finished=<ISO 8601>`.
struct ProcessResult: Equatable {
    var attempt: String
    var status: Int
    var started: Date?

    static func read(_ dir: URL) -> ProcessResult? {
        guard let text = try? String(contentsOf: dir.appendingPathComponent(".process-result"), encoding: .utf8) else { return nil }
        var fields: [String: String] = [:]
        for pair in text.split(whereSeparator: { $0 == " " || $0.isNewline }) {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            fields[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
        }
        guard let attempt = fields["attempt"], let status = fields["status"].flatMap({ Int($0) }) else { return nil }
        return ProcessResult(attempt: attempt, status: status,
                             started: fields["started"].flatMap { ISO8601DateFormatter().date(from: $0) })
    }
}

/// The durable processing queue. Its state lives in each meeting's `meeting.json` (`queued`,
/// `processing`, `attempts`, `attempt`), so a crash loses nothing: `resume()` picks up every
/// `queued` and `processing` meeting, and never touches `unprocessed` or `done` ones. One job runs
/// at a time, oldest first. A job found `processing` after a crash is settled from its lock and
/// `.process-result`: a live owner is waited for; our attempt's success is done; anything that
/// stopped part way is run again, at most three runs in all.
/// Call it from one queue (the main queue in the app); a 1 s timer there follows the progress file
/// and waits on a lock held by another process.
final class ProcessingQueue {
    static let maxAttempts = 3
    static let keptStopping = "processing kept stopping part way"
    static let noMinutes = "processing finished but wrote no minutes"
    /// `meetingbox process` refused: another process holds the folder (EX_TEMPFAIL).
    static let busyExit: Int32 = 75
    static let progressName = ".process-progress"
    /// `stage` while another process holds the folder: its progress is not ours to read.
    static let waitingStage = "waiting for another meetingbox"

    /// How a stage from the progress file reads in the app.
    static func label(_ stage: String) -> String {
        switch stage {
        case "transcribing": return "Transcribing"
        case "speakers": return "Finding speakers"
        case "minutes": return "Writing minutes"
        case "done": return "Done"
        case waitingStage: return "Waiting for another meetingbox"
        default: return stage
        }
    }

    /// The meeting being processed, or waited on.
    private(set) var current: URL?
    /// The last stage in its progress file.
    private(set) var stage: String?
    var onChange: (() -> Void)?
    /// The folder, and whether it ended done (true) or failed (false).
    var onFinished: ((URL, Bool) -> Void)?

    private let store: MeetingStore
    private let runner: PipelineRunner
    private let now: () -> Date
    private let ps: URL
    private let tickQueue: DispatchQueue?
    private var timer: DispatchSourceTimer?

    private var pending: [URL] = []
    private enum Job {
        /// Our run, started at `started`. `token` ignores a late `done` from an earlier run.
        case running(started: Date, token: Int)
        /// Another process holds the folder: wait for its lock to go, then settle from the result.
        case waiting
    }
    private var job: Job?
    private var token = 0

    /// `tickQueue` runs the 1 s timer and receives the runner's `done`; nil means no timer and
    /// `done` handled where it is called (tests call `tick()`). `ps` is injectable, as in ChildRecorder.
    init(store: MeetingStore, runner: PipelineRunner, now: @escaping () -> Date = Date.init,
         ps: URL = URL(fileURLWithPath: "/bin/ps"), tickQueue: DispatchQueue? = .main) {
        self.store = store
        self.runner = runner
        self.now = now
        self.ps = ps
        self.tickQueue = tickQueue
    }

    deinit { timer?.cancel() }

    // MARK: enqueue, resume

    /// Queues a meeting whose `meeting.json` says `queued` (Session wrote it after a verified
    /// finalise) or `processing`. A meeting already queued or processing here is not added twice;
    /// any other state, or no `meeting.json`, is left alone (a failed one only through `retry`).
    func enqueue(_ folder: URL) {
        onTickQueue()
        let dir = ProcessingQueue.normal(folder)
        guard !known(dir), let state = ProcessingQueue.read(dir)?.state, state == .queued || state == .processing else { return }
        pending.append(dir)
        onChange?()
        advance()
    }

    /// "Try again" on a `failed` meeting: written `queued`, attempts and error reset, before anything
    /// runs, then queued. Any other state is left alone, and so is a recording that never finished
    /// (`MeetingFolder.recordingUnfinished`): the reason it failed is kept and nothing is queued.
    func retry(_ folder: URL) {
        onTickQueue()
        let dir = ProcessingQueue.normal(folder)
        guard !known(dir), ProcessingQueue.read(dir)?.state == .failed, !MeetingFolder.recordingUnfinished(dir) else { return }
        queueAgain(dir, from: [.failed])
    }

    /// "Process" on a meeting that was never processed, or whose run failed: it needs the
    /// `audio.m4a` a job runs. Written `queued` (attempts and error reset) before anything runs, then
    /// queued. A meeting with no `meeting.json` has the state a scan infers for it, `done` when it has
    /// notes and `unprocessed` when it has not. Any other state, no audio, or a recording that never
    /// finished (`MeetingFolder.recordingUnfinished`) changes nothing at all: no record is made for a
    /// folder that is refused, and a record's own failure reason is kept.
    func process(_ folder: URL) {
        onTickQueue()
        let dir = ProcessingQueue.normal(folder)
        let audio = dir.appendingPathComponent("audio.m4a").path
        guard !known(dir), FileManager.default.fileExists(atPath: audio), !MeetingFolder.recordingUnfinished(dir) else { return }
        let state = ProcessingQueue.read(dir)?.state
            ?? (FileManager.default.fileExists(atPath: dir.appendingPathComponent("notes.md").path) ? .done : .unprocessed)
        guard state == .unprocessed || state == .failed else { return }
        queueAgain(dir, from: [.unprocessed, .failed])
    }

    /// Writes a meeting in one of the `accepted` states `queued`, with attempts and error reset, and
    /// queues it. A state that changed under us is left as it is.
    private func queueAgain(_ dir: URL, from accepted: [MeetingState]) {
        var requeued = false
        do {
            try store.update(dir) {
                guard accepted.contains($0.state) else { return }
                $0.state = .queued
                $0.error = nil
                $0.stage = nil
                $0.attempts = nil
                $0.attempt = nil
                requeued = true
            }
        } catch { return }
        if requeued { enqueue(dir) }
    }

    /// Picks up every meeting left `queued` or `processing`, oldest first. Safe to call again.
    func resume() {
        onTickQueue()
        for meeting in store.scan().reversed() {
            guard let state = meeting.record?.state, state == .queued || state == .processing else { continue }
            let dir = ProcessingQueue.normal(meeting.folder.url)
            if !known(dir) { pending.append(dir) }
        }
        onChange?()
        advance()
    }

    // MARK: running

    /// Follows the progress file, and settles a job whose lock another process held once it goes.
    func tick() {
        guard let dir = current, let job = job else { return }
        switch job {
        case .running:
            pollProgress(dir)
        case .waiting:
            if ProcessingLock.owner(dir, ps: ps, now: now()) == .gone {
                settle(dir)
                advance()
            }
        }
    }

    /// Starts jobs until one is running or waiting, or none is left.
    private func advance() {
        while job == nil {
            guard !pending.isEmpty else {
                if current != nil || stage != nil {
                    current = nil
                    stage = nil
                    onChange?()
                }
                updateTimer()
                return
            }
            let dir = pending.removeFirst()
            current = dir
            stage = nil
            guard let record = ProcessingQueue.read(dir) else { current = nil; continue }
            switch record.state {
            case .queued:
                launch(dir, attempts: 1)
            case .processing:
                // Left by a crash, or a process we were refused for: its owner may still be at work.
                if ProcessingLock.owner(dir, ps: ps, now: now()) == .gone {
                    settle(dir)
                } else {
                    wait(dir)
                }
            default:
                break // changed since it was queued: not ours to run
            }
            if job == nil { current = nil }
            onChange?()
        }
        updateTimer()
    }

    /// A `processing` meeting nobody holds: done when its result is our attempt's success with fresh
    /// minutes; failed when that run failed on its own; otherwise it stopped part way and runs again.
    private func settle(_ dir: URL) {
        job = nil
        guard let record = ProcessingQueue.read(dir), record.state == .processing else { return }
        if let result = ProcessResult.read(dir), let attempt = record.attempt, result.attempt == attempt {
            if result.status == 0, let started = result.started, ProcessingQueue.fresh(dir, since: started) {
                succeed(dir)
                return
            }
            if result.status != 0 && result.status < 128 {
                fail(dir, "processing failed (exit \(result.status))")
                return
            }
        }
        let attempts = record.attempts ?? 0
        if attempts >= ProcessingQueue.maxAttempts {
            fail(dir, ProcessingQueue.keptStopping)
        } else {
            launch(dir, attempts: attempts + 1)
        }
    }

    private func launch(_ dir: URL, attempts: Int) {
        let attempt = UUID().uuidString
        do {
            try store.update(dir) {
                $0.state = .processing
                $0.attempts = attempts
                $0.attempt = attempt
                $0.error = nil
                $0.stage = nil
            }
        } catch {
            return // cannot even record it: leave it queued for the next resume
        }
        let progress = dir.appendingPathComponent(ProcessingQueue.progressName)
        try? MeetingStore.writePrivately(Data(), to: progress)
        stage = nil
        token += 1
        let mine = token
        let started = now()
        job = .running(started: started, token: mine)
        _ = runner.run(audio: dir.appendingPathComponent("audio.m4a"), progress: progress, attempt: attempt) { [weak self] status, line in
            self?.onQueue { self?.ended(mine, dir, status, line) }
        }
    }

    private func ended(_ mine: Int, _ dir: URL, _ status: Int32, _ line: String) {
        guard case .running(let started, let t)? = job, t == mine,
              let cur = current, cur.path == dir.path else { return }
        pollProgress(dir)
        if status == ProcessingQueue.busyExit {
            // Refused: nothing ran, so this run is not counted. Wait for the holder, then settle.
            try? store.update(dir) { if let n = $0.attempts { $0.attempts = max(0, n - 1) } }
            wait(dir)
            onChange?()
            updateTimer()
            return
        }
        job = nil
        if status == 0 {
            if ProcessingQueue.fresh(dir, since: started) { succeed(dir) } else { fail(dir, ProcessingQueue.noMinutes) }
        } else {
            fail(dir, line.isEmpty ? "processing failed (exit \(status))" : line)
        }
        advance()
    }

    /// Another process holds the folder. Its progress (if any) is not in our file, so say why.
    private func wait(_ dir: URL) {
        job = .waiting
        stage = ProcessingQueue.waitingStage
        try? store.update(dir) { $0.stage = ProcessingQueue.waitingStage }
    }

    private func succeed(_ dir: URL) {
        clearProgress(dir)
        try? store.update(dir) {
            $0.state = .done
            $0.stage = nil
            $0.error = nil
        }
        onFinished?(dir, true)
    }

    private func fail(_ dir: URL, _ reason: String) {
        clearProgress(dir)
        try? store.update(dir) {
            $0.state = .failed
            $0.stage = nil
            $0.error = reason
        }
        onFinished?(dir, false)
    }

    // MARK: helpers

    /// Empties the app's progress file, if there is one, so a later wait never shows its old stage.
    private func clearProgress(_ dir: URL) {
        let file = dir.appendingPathComponent(ProcessingQueue.progressName)
        if FileManager.default.fileExists(atPath: file.path) { try? MeetingStore.writePrivately(Data(), to: file) }
    }

    /// The queue's state is confined to the tick queue; a caller elsewhere would race it.
    private func onTickQueue() {
        if let q = tickQueue { dispatchPrecondition(condition: .onQueue(q)) }
    }

    private func pollProgress(_ dir: URL) {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(ProcessingQueue.progressName)) else { return }
        let text = String(decoding: data, as: UTF8.self)
        // whole lines only: the script may be half way through writing the next
        let lines = text.hasSuffix("\n") ? text.split(whereSeparator: \.isNewline) : text.split(whereSeparator: \.isNewline).dropLast()
        guard let last = lines.last.map({ $0.trimmingCharacters(in: .whitespaces) }), !last.isEmpty, last != stage else { return }
        stage = last
        try? store.update(dir) { $0.stage = last }
        onChange?()
    }

    private func known(_ dir: URL) -> Bool {
        current?.path == dir.path || pending.contains { $0.path == dir.path }
    }

    /// The timer runs while a job is running or waited on.
    private func updateTimer() {
        if job == nil {
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

    private func onQueue(_ work: @escaping () -> Void) {
        if let q = tickQueue { q.async(execute: work) } else { work() }
    }

    /// `transcript.txt` and `notes.md` both exist and were written at or after `since` (to the second).
    private static func fresh(_ dir: URL, since: Date) -> Bool {
        let floor = since.addingTimeInterval(-1)
        return ["transcript.txt", "notes.md"].allSatisfy { name in
            let attrs = try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)
            guard let modified = attrs?[.modificationDate] as? Date else { return false }
            return modified >= floor
        }
    }

    private static func read(_ dir: URL) -> MeetingRecord? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("meeting.json")),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return MeetingRecord(json: obj)
    }

    private static func normal(_ url: URL) -> URL {
        URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
    }
}
