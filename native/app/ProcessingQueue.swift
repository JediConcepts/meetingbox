import Darwin
import Foundation

// MARK: - jobs, writers and the settings a run takes

/// What a job runs: `process` (the first processing, and Process and Try again), or one of the redos,
/// `minutes` (Redo minutes, `meetingbox notes`) and `transcribe` (Transcribe again, `meetingbox redo`).
/// The raw values are the words `meeting.json`'s `job` and the engine's `.swap` use.
enum JobKind: String {
    case process, minutes, transcribe
}

/// What a redo's sheet chose, written into `meeting.json` by `ProcessingQueue.redo` before it runs. The
/// transcriber and tidying are for Transcribe again only. For Transcribe again the counts replace the
/// meeting's (nil is Work it out): `room` and `call` for its two sides, `recording` for a recording kept as
/// one file; Redo minutes leaves them as they are. A nil writer leaves the meeting's.
struct JobOptions: Equatable {
    var transcriber: Transcriber?
    var room: Int?
    var call: Int?
    var recording: Int?
    var tidy: Bool?
    var writer: MeetingWriter?
}

/// One run of the engine for one meeting: its kind, its folder, and the engine's arguments, built at
/// launch (`ScriptRunner.arguments`).
struct PipelineJob: Equatable {
    let kind: JobKind
    let folder: URL
    let arguments: [String]
}

/// An outside source's kind: the Claude API, or a Standard (OpenAI-compatible) one.
enum SourceKind: String, Codable {
    case claude, standard
}

/// An outside model that may write the minutes.
struct OutsideWriter: Equatable, Codable {
    var kind: SourceKind
    var address: String
    var model: String
}

/// Who writes a meeting's minutes.
enum MeetingWriter: Equatable {
    case apple
    case outside(OutsideWriter)
}

/// A source in Preferences, and whether the user agreed to send it transcripts.
struct Source: Equatable, Codable {
    var kind: SourceKind
    var address: String
    var agreed: Bool
}

/// What a job launched now runs with, read from Preferences at launch. `agreed` holds only sources
/// that exist and are agreed.
struct RunSettings: Equatable {
    var transcriber: Transcriber
    var tidy: Bool
    var preferredWriter: MeetingWriter
    var agreed: [Source]

    static let defaults = RunSettings(transcriber: .parakeet, tidy: true, preferredWriter: .apple, agreed: [])

    /// `agreed` holds an agreed source of this writer's kind at its address.
    func agrees(to writer: OutsideWriter) -> Bool {
        agreed.contains { $0.agreed && $0.kind == writer.kind && $0.address == writer.address }
    }
}

/// Runs the engine for one job. Returns the worker's PID (or -1 when it could not be started); `done`
/// is called once, on any queue, with the exit status and the last stderr line. `attempt` names this
/// run: the script writes it into `.process-result`.
protocol PipelineRunner {
    func run(_ job: PipelineJob, progress: URL, attempt: String, done: @escaping (Int32, String) -> Void) -> Int32
}

/// The real runner: `<MBScriptPath> <the job's arguments>` with `MB_PROGRESS_FILE`, `MB_ATTEMPT`,
/// `MB_SOUNDS=0` and `MB_KEEP_AUDIO=1`, and `PATH` led by `~/.local/bin:/opt/homebrew/bin:/usr/local/bin`.
/// The app's own `MB_*` variables are not passed on: settings travel as arguments, never through the
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

    /// The environment every engine command the app runs gets: the app's own, without any `MB_*`
    /// setting, and with `PATH` led by `~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin`.
    static func childEnvironment(_ environment: [String: String], home: URL) -> [String: String] {
        var env = environment.filter { !$0.key.hasPrefix("MB_") }
        let lead = ["\(home.path)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"].joined(separator: ":")
        env["PATH"] = lead + ":" + (env["PATH"].flatMap { $0.isEmpty ? nil : $0 } ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        return env
    }

    /// The engine's arguments for a job (contracts, "App to engine arguments"), where `<writer>` is
    /// `--writer apple`, or `--writer outside --kind K --address A --writer-model M` for `writer`:
    /// - process: `process <dir>/audio.m4a --parakeet|--native --tidy|--no-tidy <writer>`, no counts;
    /// - minutes: `notes <dir> <writer>`;
    /// - transcribe: `redo <dir> --parakeet|--native [--room N] [--call N] [--people N] --tidy|--no-tidy <writer>`,
    ///   where `--people` is the count of a recording kept as one file (`recording`).
    static func arguments(kind: JobKind, folder: URL, transcriber: Transcriber, room: Int?, call: Int?, recording: Int? = nil,
                          tidy: Bool, writer: OutsideWriter?) -> [String] {
        let engine = transcriber == .parakeet ? "--parakeet" : "--native"
        let lines = tidy ? "--tidy" : "--no-tidy"
        let writes = writer.map { ["--writer", "outside", "--kind", $0.kind.rawValue, "--address", $0.address, "--writer-model", $0.model] }
            ?? ["--writer", "apple"]
        switch kind {
        case .process:
            return ["process", folder.appendingPathComponent("audio.m4a").path, engine, lines] + writes
        case .minutes:
            return ["notes", folder.path] + writes
        case .transcribe:
            let counts = (room.map { ["--room", String($0)] } ?? []) + (call.map { ["--call", String($0)] } ?? [])
                + (recording.map { ["--people", String($0)] } ?? [])
            return ["redo", folder.path, engine] + counts + [lines] + writes
        }
    }

    /// The writer a job uses, chosen at launch: the meeting's own when it has one, else the preferred
    /// one. An outside writer is used only when `settings.agreed` holds an agreed source of its kind at
    /// its address; otherwise Apple's model writes and the outside one is `setAside`, for the log.
    static func writer(meeting: MeetingWriter?, settings: RunSettings) -> (use: OutsideWriter?, setAside: OutsideWriter?) {
        guard case .outside(let wanted) = meeting ?? settings.preferredWriter else { return (nil, nil) }
        return settings.agrees(to: wanted) ? (wanted, nil) : (nil, wanted)
    }

    /// The line `.process-log` gets when an outside writer is set aside at launch, naming the host as
    /// the address rule parses it (the host shown everywhere else).
    static func setAsideLine(_ writer: OutsideWriter) -> String {
        let host = PreferencesPresentation.shownHost(writer.address)
        return "The minutes writer \(writer.model) at \(host) was set aside because its source was removed, changed or not agreed. "
            + "Apple's model writes the minutes."
    }

    func run(_ job: PipelineJob, progress: URL, attempt: String, done: @escaping (Int32, String) -> Void) -> Int32 {
        var env = ScriptRunner.childEnvironment(environment, home: home)
        env["MB_PROGRESS_FILE"] = progress.path
        env["MB_ATTEMPT"] = attempt
        env["MB_SOUNDS"] = "0"
        env["MB_KEEP_AUDIO"] = "1" // a retry needs the audio: never let a run remove it

        let process = Process()
        process.executableURL = script
        process.arguments = job.arguments
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        let logURL = job.folder.appendingPathComponent(ScriptRunner.logName)
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

// MARK: - the engine's other commands

/// How the app runs an engine command that is not a job (`engines`, `voice add`, `voice forget`). `done`
/// comes once, on the main queue, with the exit status and at most 64 KB of stdout. Injected into
/// `AppModel`: only the app passes the real one, so a test can never reach the real engine.
protocol EngineCommands {
    func run(_ arguments: [String], stdin: Data?, timeout: TimeInterval, done: @escaping (Int32, String) -> Void)
}

/// What runs nothing: the default outside the app bundle, and the app's when its bundle names no script.
struct NoEngineCommands: EngineCommands {
    static let notInstalled = "meetingbox is not installed; run meetingbox setup"

    func run(_ arguments: [String], stdin: Data?, timeout: TimeInterval, done: @escaping (Int32, String) -> Void) {
        DispatchQueue.main.async { done(1, NoEngineCommands.notInstalled) }
    }
}

/// The real engine commands: the bundle's `MBScriptPath` script, never `~/.local/bin/meetingbox`, run
/// off the main queue with the runner's environment (no `MB_*` setting), anything secret on stdin
/// through a pipe and never in the arguments, stderr discarded. At the limit the script and everything
/// it started (its own process group) are sent SIGTERM, then SIGKILL 5 s later, and the status is 124.
struct ScriptEngineCommands: EngineCommands {
    static let timedOut: Int32 = 124
    static let outputLimit = 65_536
    let script: URL
    private let environment: [String: String]

    init(script: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.script = script
        self.environment = ScriptEngineCommands.environment(environment, home: home)
    }

    /// The script named by `MBScriptPath` in the app's Info.plist; nil outside the app bundle.
    static func fromBundle(_ bundle: Bundle = .main) -> ScriptEngineCommands? {
        guard let path = bundle.object(forInfoDictionaryKey: "MBScriptPath") as? String, !path.isEmpty else { return nil }
        return ScriptEngineCommands(script: URL(fileURLWithPath: path))
    }

    /// The environment the commands run with: the runner's.
    static func environment(_ environment: [String: String], home: URL) -> [String: String] {
        ScriptRunner.childEnvironment(environment, home: home)
    }

    func run(_ arguments: [String], stdin: Data?, timeout: TimeInterval, done: @escaping (Int32, String) -> Void) {
        let (script, environment) = (self.script, self.environment)
        DispatchQueue.global(qos: .userInitiated).async {
            let (status, output) = ScriptEngineCommands.execute(script: script, arguments: arguments, environment: environment,
                                                                stdin: stdin, timeout: timeout)
            DispatchQueue.main.async { done(status, output) }
        }
    }

    /// Runs `script` with `arguments` and waits for it: call off the main queue. Its stdin is a pipe
    /// holding `stdin` (empty when nil); its stdout is read to the end, keeping the first 64 KB; its
    /// stderr goes nowhere. It runs in a process group of its own, so the limit ends what it started too.
    static func execute(script: URL, arguments: [String], environment: [String: String], stdin: Data?,
                        timeout: TimeInterval) -> (Int32, String) {
        var input: [Int32] = [-1, -1], output: [Int32] = [-1, -1]
        guard pipe(&input) == 0 else { return (127, "could not start meetingbox: no pipe") }
        guard pipe(&output) == 0 else { close(input[0]); close(input[1]); return (127, "could not start meetingbox: no pipe") }
        _ = fcntl(input[1], F_SETNOSIGPIPE, 1) // a script that never reads its stdin must not end the app

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, input[0], 0)
        posix_spawn_file_actions_adddup2(&actions, output[1], 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own process group; only 0, 1 and 2 inherited; signals as a fresh process has them.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
                                                    | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t(), none = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGPIPE, SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGCHLD, SIGALRM, SIGUSR1, SIGUSR2] { sigaddset(&defaults, signal) }
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setsigmask(&attributes, &none)

        let argv = ([script.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, script.path, &actions, &attributes, argv, envp)
        close(input[0])
        close(output[1])
        guard spawned == 0 else {
            close(input[1])
            close(output[0])
            return (127, "could not start meetingbox: \(String(cString: strerror(spawned)))")
        }

        // The limit: TERM to the group, then KILL 5 s later, only while the script has not been reaped.
        let watch = Watchdog(group: pid)
        let watchdog = DispatchWorkItem { watch.fire() }
        DispatchQueue.global().asyncAfter(deadline: .now() + max(0, timeout), execute: watchdog)

        // stdin on its own thread, so a script that writes before it reads cannot deadlock with us.
        let feeder = DispatchGroup()
        let writeEnd = input[1]
        DispatchQueue.global().async(group: feeder) {
            if let data = stdin {
                data.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        let n = write(writeEnd, raw.baseAddress! + offset, raw.count - offset)
                        if n > 0 { offset += n } else if n < 0 && errno == EINTR { continue } else { break }
                    }
                }
            }
            close(writeEnd)
        }

        var kept = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let n = read(output[0], &buffer, buffer.count)
            if n > 0 {
                if kept.count < outputLimit { kept.append(contentsOf: buffer[0..<min(n, outputLimit - kept.count)]) }
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
        close(output[0])
        feeder.wait()

        // Seen to have exited first (WNOWAIT), so the watchdog can never signal a group whose leader's
        // PID has been reused; then reaped.
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) != 0 && errno == EINTR {}
        let timedOut = watch.reap()
        watchdog.cancel()
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        let text = String(decoding: kept, as: UTF8.self)
        if timedOut { return (ScriptEngineCommands.timedOut, text) }
        let signal = status & 0x7f
        return (signal == 0 ? (status >> 8) & 0xff : 128 + signal, text)
    }

    /// Ends a process group at the limit: SIGTERM, then SIGKILL 5 s later, never once it has been reaped.
    private final class Watchdog: @unchecked Sendable {
        private let lock = NSLock()
        private let group: pid_t
        private var reaped = false
        private var fired = false

        init(group: pid_t) { self.group = group }

        func fire() {
            lock.lock()
            defer { lock.unlock() }
            guard !reaped else { return }
            fired = true
            kill(-group, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [self] in
                lock.lock()
                defer { lock.unlock() }
                if !reaped { kill(-group, SIGKILL) }
            }
        }

        /// The script has exited and is about to be reaped: whether the limit was reached first.
        func reap() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            reaped = true
            return fired
        }
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
/// `processing`, `attempts`, `attempt`, and a redo's `job` and its options), so a crash loses nothing:
/// `resume()` picks up every `queued` and `processing` meeting, and never touches `unprocessed` or
/// `done` ones. One job runs at a time, as the kind its record names, in the order asked. At launch the
/// order is, each group oldest first: the meetings found `processing` whose lock is live or whose owner
/// cannot be told (a run the last instance left going may still be at work), then those found
/// `processing` whose lock is gone, then those found `queued`. A job found `processing` after a quit or
/// a crash is settled from its lock and `.process-result`: a live owner is waited for; our attempt's
/// success is done; anything that stopped part way is run again as the same kind, at most three runs in
/// all.
/// Call it from one queue (the main queue in the app); a 1 s timer there follows the progress file
/// and waits on a lock held by another process.
final class ProcessingQueue {
    static let maxAttempts = 3
    static let keptStopping = "processing kept stopping part way"
    static let noMinutes = "processing finished but wrote no minutes"
    /// The engine could not finish its swap and left `.swap` for the next run of the same kind to finish.
    static let swapExit: Int32 = 3
    /// `meetingbox process` refused: another process holds the folder (EX_TEMPFAIL).
    static let busyExit: Int32 = 75
    /// The reason a redo gives when it was stopped by a signal, or kept stopping, with nothing better said.
    static let redoStopped = "meetingbox was stopped before it finished"
    /// Why a job this version cannot read is not run (`MeetingRecord.jobUnknown`).
    static let unknownJob = "this version of meetingbox does not know that kind of job"
    /// The reason a redo gives when the engine said it was done but its files are not new.
    static let redoWroteNothing = "meetingbox finished but wrote nothing new"

    /// A redo that did not finish and changed nothing (Copy, fixed). When the engine's reason says so
    /// itself ("the meeting folder was moved, nothing was changed"), it is not said again.
    static func redoNothingChanged(_ reason: String) -> String {
        let said = clause(reason)
        if said.lowercased().hasSuffix("nothing was changed") { return "The redo did not finish: \(said)." }
        return "The redo did not finish: \(said). Nothing was changed."
    }

    /// A redo that left its swap part done, after its runs were spent (Copy, fixed).
    static func redoPartWay(_ reason: String) -> String {
        "The redo stopped part way: \(clause(reason)). Choose it again to finish it."
    }

    /// The engine's reason inside one of those sentences, without a full stop of its own.
    private static func clause(_ reason: String) -> String {
        var text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(".") { text.removeLast() }
        return text
    }

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

    /// The meeting being processed, or waited on, where it was last found; nil while its run goes on in a
    /// meeting that is in no root, so no other meeting at its old path is taken for it.
    var current: URL? { holding.flatMap { $0.lost ? nil : $0.dir } }
    /// That meeting, with what identifies it.
    private var holding: Held?
    /// A job is running or waited on, or more are queued behind it.
    var hasWork: Bool { holding != nil || !pending.isEmpty }
    /// The last stage in its progress file.
    private(set) var stage: String?
    var onChange: (() -> Void)?
    /// The folder (where it is now), whether the job worked (true) or not (false), its kind (nil for a job
    /// this version could not read, which ends as a redo that could not run), and the reason when it ended
    /// where its meeting could not be found: then nothing was written, and the record at the folder's old
    /// path, if any, is another meeting's. Otherwise the reason is the record's `error`. A redo that did
    /// not work can leave its meeting Done.
    var onFinished: ((URL, Bool, JobKind?, String?) -> Void)?
    /// The reason a job gives when its meeting was moved out of every root and its own outcome says nothing.
    static let lostFolder = "the meeting folder was moved where meetingbox cannot find it"

    private let store: MeetingStore
    private let runner: PipelineRunner
    private let now: () -> Date
    private let ps: URL
    private let tickQueue: DispatchQueue?
    /// Read once at each launch, so a job runs with the settings of the moment it starts.
    private let settings: () -> RunSettings
    private var timer: DispatchSourceTimer?

    /// A meeting this queue holds: its folder where it was last found; that folder's own identity, its
    /// device and inode from `lstat` when it was queued (a rename or a move within the volume keeps them, a
    /// Finder duplicate does not); its `meeting.json` id (a copied meeting.json has it too, so both must
    /// match); and the kind its record named then.
    private struct Held {
        var dir: URL
        let identity: FolderIdentity
        let id: String
        let kind: JobKind?
        /// Its run goes on, but the meeting is in no root: nothing is read or written for it until found.
        var lost = false

        init?(_ dir: URL, _ record: MeetingRecord) {
            guard let identity = FolderIdentity(dir) else { return nil }
            self.dir = dir
            self.identity = identity
            self.id = record.id
            self.kind = record.jobUnknown ? nil : record.job ?? .process
        }
    }

    /// A folder's own device and inode, from `lstat`: a link is its own entry, never followed.
    private struct FolderIdentity: Equatable {
        let device: dev_t
        let inode: ino_t

        init?(_ url: URL) {
            var st = stat()
            guard lstat(url.path, &st) == 0 else { return nil }
            device = st.st_dev
            inode = st.st_ino
        }
    }

    private var pending: [Held] = []
    private enum Job {
        /// Our run of this kind, started at `started`. `token` ignores a late `done` from an earlier run.
        case running(started: Date, token: Int, kind: JobKind)
        /// Another process holds the folder: wait for its lock to go, then settle from the result.
        case waiting
    }
    private var job: Job?
    private var token = 0

    /// `tickQueue` runs the 1 s timer and receives the runner's `done`; nil means no timer and
    /// `done` handled where it is called (tests call `tick()`). `ps` is injectable, as in ChildRecorder.
    /// `settings` gives what a job launched now runs with (the app's Preferences).
    init(store: MeetingStore, runner: PipelineRunner, now: @escaping () -> Date = Date.init,
         ps: URL = URL(fileURLWithPath: "/bin/ps"), tickQueue: DispatchQueue? = .main,
         settings: @escaping () -> RunSettings = { .defaults }) {
        self.store = store
        self.runner = runner
        self.now = now
        self.ps = ps
        self.tickQueue = tickQueue
        self.settings = settings
    }

    deinit { timer?.cancel() }

    // MARK: enqueue, resume

    /// Queues a meeting whose `meeting.json` says `queued` (Session wrote it after a verified
    /// finalise) or `processing`. A meeting already queued or processing here is not added twice;
    /// any other state, or no `meeting.json`, is left alone (a failed one only through `retry`).
    func enqueue(_ folder: URL) {
        onTickQueue()
        let dir = ProcessingQueue.normal(folder)
        guard !known(dir), let record = ProcessingQueue.read(dir), record.state == .queued || record.state == .processing,
              let entry = Held(dir, record) else { return }
        pending.append(entry)
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
    /// queues it as a full process: any redo options left in its record are cleared. A state that
    /// changed under us is left as it is.
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
                ProcessingQueue.clearJob(&$0)
                requeued = true
            }
        } catch { return }
        if requeued { enqueue(dir) }
    }

    /// Redo minutes (`minutes`) or Transcribe again (`transcribe`), from the window: true when it is
    /// queued. Redo minutes takes a finished or failed meeting that has a `transcript.txt`; Transcribe
    /// again a finished meeting with the `audio.m4a` a job runs. Neither takes a meeting this queue
    /// holds, any other state, or a recording that never finished; a meeting with no `meeting.json` has
    /// the state a scan infers for it. The kind and `options` are written into `meeting.json`, with the
    /// meeting `queued` and its attempts and error reset, before anything runs, so after a crash the same
    /// kind runs again with the same choices. A refusal writes nothing.
    func redo(_ folder: URL, kind: JobKind, options: JobOptions) -> Bool {
        onTickQueue()
        let dir = ProcessingQueue.normal(folder)
        let has = { (name: String) in FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) }
        let accepted: [MeetingState]
        switch kind {
        case .process: return false
        case .minutes: accepted = has("transcript.txt") ? [.done, .failed] : []
        case .transcribe: accepted = has("audio.m4a") ? [.done] : []
        }
        guard !known(dir), !MeetingFolder.recordingUnfinished(dir) else { return false }
        let state = ProcessingQueue.read(dir)?.state ?? (has("notes.md") ? .done : .unprocessed)
        guard accepted.contains(state) else { return false }
        var queued = false
        do {
            try store.update(dir) {
                guard accepted.contains($0.state) else { return }
                $0.state = .queued
                $0.error = nil
                $0.stage = nil
                $0.attempts = nil
                $0.attempt = nil
                $0.job = kind
                if kind == .transcribe {
                    $0.jobTranscriber = options.transcriber
                    $0.jobTidy = options.tidy
                    $0.people = MeetingRecord.People(room: options.room, call: options.call, recording: options.recording)
                } else {
                    $0.jobTranscriber = nil
                    $0.jobTidy = nil
                }
                if let writer = options.writer { $0.writer = writer }
                queued = true
            }
        } catch { return false }
        if queued { enqueue(dir) }
        return queued
    }

    /// A redo's options go on every final outcome, and when Process or Try again queue a full process.
    /// The counts and the writer stay: only a later sheet changes them.
    private static func clearJob(_ record: inout MeetingRecord) {
        record.job = nil
        record.jobTranscriber = nil
        record.jobTidy = nil
    }

    /// Picks up every meeting left `processing` or `queued`, in the meetings folder and in every other
    /// folder a recording was started in (`MeetingStore.roots`), in this order, each group oldest first:
    /// those `processing` whose lock is live or whose owner ps cannot tell, then those `processing` whose
    /// lock is gone, then those `queued`. A run the last instance started goes on after it quits, holding
    /// its lock, so at launch it is waited for before anything else starts, whatever the dates. Safe to
    /// call again: what a later call finds goes behind what is already pending.
    func resume() {
        onTickQueue()
        let found = store.scanEveryRoot().reversed().compactMap { meeting -> (dir: URL, record: MeetingRecord, group: Int)? in
            guard let record = meeting.record else { return nil }
            let dir = ProcessingQueue.normal(meeting.folder.url)
            switch record.state {
            case .processing: return (dir, record, ProcessingLock.owner(dir, ps: ps, now: now()) == .gone ? 1 : 0)
            case .queued: return (dir, record, 2)
            default: return nil
            }
        }
        for group in 0...2 {
            for meeting in found where meeting.group == group {
                if !known(meeting.dir), let entry = Held(meeting.dir, meeting.record) { pending.append(entry) }
            }
        }
        onChange?()
        advance()
    }

    // MARK: running

    /// Follows the progress file, and settles a job whose lock another process held once it goes. A
    /// folder moved meanwhile is followed, with the other process's lock in it. A running meeting in no
    /// root is current again when it comes back, wherever in a root it is.
    func tick() {
        guard let held = holding, let job = job else { return }
        switch job {
        case .running:
            // Nothing is read or written for the run until its folder is checked to be its meeting; the
            // usual case is one look at the folder it was last found in.
            guard let here = locate(held) else {
                // In no root (or another meeting is at its path): touch nothing, point at nothing.
                if !held.lost {
                    holding?.lost = true
                    onChange?()
                }
                return
            }
            if here != held.dir || held.lost {
                // Moved, or back from no root, at the path it was last found at or another: followed again.
                holding?.dir = here
                holding?.lost = false
                onChange?()
            }
            pollProgress(here)
        case .waiting:
            guard let entry = holding else { return }
            guard let here = locate(entry) else {
                endNowhere(entry, kind: entry.kind)
                return
            }
            holding?.dir = here
            if ProcessingLock.owner(here, ps: ps, now: now()) == .gone {
                settle(here)
                advance()
            }
        }
    }

    /// Starts jobs until one is running or waiting, or none is left. A meeting whose folder was moved
    /// while it waited its turn is run where it is now.
    private func advance() {
        while job == nil {
            guard !pending.isEmpty else {
                if holding != nil || stage != nil {
                    holding = nil
                    stage = nil
                    onChange?()
                }
                updateTimer()
                return
            }
            let entry = pending.removeFirst()
            stage = nil
            guard let dir = locate(entry) else {
                // In no root any more: nothing is written anywhere, and the job ends as not done.
                holding = nil
                onFinished?(entry.dir, false, entry.kind, ProcessingQueue.lostFolder)
                onChange?()
                continue
            }
            holding = entry
            holding?.dir = dir
            guard let record = ProcessingQueue.read(dir) else {
                holding = nil
                continue
            }
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
            if job == nil { holding = nil }
            onChange?()
        }
        updateTimer()
    }

    /// Where a meeting this queue holds is now: the folder it was last found in, while that is still its
    /// folder (`holds`); else, after a rename or a move in Finder, the folder directly in one of the roots
    /// that is. Only each folder's own entry is looked at (`lstat`), and a `meeting.json` is read only
    /// where the folder itself matches. Nil when it is in no root.
    private func locate(_ entry: Held) -> URL? {
        if ProcessingQueue.holds(entry, at: entry.dir) { return entry.dir }
        for root in store.roots {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] where !name.hasPrefix(".") {
                let dir = ProcessingQueue.normal(root.appendingPathComponent(name, isDirectory: true))
                if ProcessingQueue.holds(entry, at: dir) { return dir }
            }
        }
        return nil
    }

    /// The folder at `dir` is the entry's meeting only when both its own device and inode and the id in
    /// its `meeting.json` are the entry's: never a Finder duplicate, a copied meeting.json, or another
    /// meeting renamed onto the path.
    private static func holds(_ entry: Held, at dir: URL) -> Bool {
        FolderIdentity(dir) == entry.identity && read(dir)?.id == entry.id
    }

    /// The meeting is in no root any more (moved off the volume, out of the meetings folder, or to the
    /// Trash): nothing is written anywhere, the old path included, since another meeting may be there
    /// now. The job ends as not done; a relaunch's resume takes the meeting up if it comes back.
    private func endNowhere(_ entry: Held, kind: JobKind?, reason: String = ProcessingQueue.lostFolder) {
        job = nil
        onFinished?(entry.dir, false, kind, reason)
        advance()
    }

    /// A `processing` meeting nobody holds, settled by the kind its record names, by the rule a run that
    /// ended goes by (`outcome`), from its `.process-result` when that is our attempt's. With no result of
    /// ours it stopped part way, and runs again. A job this version cannot read is never run.
    private func settle(_ dir: URL) {
        job = nil
        guard let record = ProcessingQueue.read(dir), record.state == .processing else { return }
        if record.jobUnknown {
            fail(dir, nil, ProcessingQueue.redoNothingChanged(ProcessingQueue.unknownJob))
            return
        }
        let kind = record.job ?? .process
        guard let result = ProcessResult.read(dir), let attempt = record.attempt, result.attempt == attempt else {
            runAgain(dir, kind, reason: ProcessingQueue.redoStopped)
            return
        }
        let fresh = result.started.map { ProcessingQueue.fresh(dir, since: $0, kind: kind) } ?? false
        finish(dir, kind, ProcessingQueue.outcome(kind, status: Int32(clamping: result.status), fresh: fresh, line: "", settled: true))
    }

    /// What a run of ours came to, by its kind, its exit status, whether what that kind writes is fresh
    /// and the engine's last line: one rule for a run that ended (`ended`) and one settled after a relaunch
    /// (`settle`, which has no last line).
    /// - Exit 0: done when fresh. Otherwise a redo did not finish, having written nothing new. A process
    ///   that ended wrote no minutes; one settled runs again, as it always has.
    /// - Exit 3: a swap was left to finish, so the same kind runs again.
    /// - A signal runs a redo again, and a process when it is settled; a process that ended fails, as it
    ///   always has.
    /// - Anything else fails, in the engine's words.
    private enum Outcome {
        case done
        case failed(String)
        case runAgain(String)
    }

    private static func outcome(_ kind: JobKind, status: Int32, fresh: Bool, line: String, settled: Bool) -> Outcome {
        switch status {
        case 0:
            if fresh { return .done }
            if kind != .process { return .failed(redoNothingChanged(redoWroteNothing)) }
            return settled ? .runAgain(redoStopped) : .failed(noMinutes)
        case swapExit:
            return .runAgain(line.isEmpty ? redoStopped : line)
        case 128...:
            // A signal: its last line is only how far it got, so it is not the reason.
            return kind != .process || settled ? .runAgain(redoStopped) : .failed(failure(kind, status: status, line: line))
        default:
            return .failed(failure(kind, status: status, line: line))
        }
    }

    private func finish(_ dir: URL, _ kind: JobKind, _ outcome: Outcome) {
        switch outcome {
        case .done: succeed(dir, kind)
        case .failed(let reason): fail(dir, kind, reason)
        case .runAgain(let reason): runAgain(dir, kind, reason: reason)
        }
    }

    /// A run that stopped part way runs again as the same kind, up to `maxAttempts` runs in all; then the
    /// job fails: a process kept stopping, or a redo stopped part way for `reason`.
    private func runAgain(_ dir: URL, _ kind: JobKind, reason: String) {
        let attempts = ProcessingQueue.read(dir)?.attempts ?? 0
        if attempts >= ProcessingQueue.maxAttempts {
            fail(dir, kind, kind == .process ? ProcessingQueue.keptStopping : ProcessingQueue.redoPartWay(reason))
        } else {
            launch(dir, attempts: attempts + 1)
        }
    }

    /// Why a run that exited on its own with `status` failed: the engine's last line, else the status.
    /// A redo's reason is put in its sentence: nothing was changed.
    private static func failure(_ kind: JobKind, status: Int32, line: String) -> String {
        switch kind {
        case .process: return line.isEmpty ? "processing failed (exit \(status))" : line
        case .minutes, .transcribe: return redoNothingChanged(line.isEmpty ? "meetingbox failed (exit \(status))" : line)
        }
    }

    /// Launches the kind the record names, built from the record and the settings of this moment: a
    /// process with the Preferences transcriber and tidying; Transcribe again with its own transcriber,
    /// tidying and counts, any it lacks taken from Preferences; every kind with the meeting's writer, else
    /// the Preferences one, used only if agreed. A job this version cannot read is not run at all: it ends
    /// as a redo that could not run.
    private func launch(_ dir: URL, attempts: Int) {
        if ProcessingQueue.read(dir)?.jobUnknown == true {
            fail(dir, nil, ProcessingQueue.redoNothingChanged(ProcessingQueue.unknownJob))
            return
        }
        let attempt = UUID().uuidString
        var record: MeetingRecord?
        do {
            try store.update(dir) {
                $0.state = .processing
                $0.attempts = attempts
                $0.attempt = attempt
                $0.error = nil
                $0.stage = nil
                record = $0
            }
        } catch {
            return // cannot even record it: leave it queued for the next resume
        }
        let kind = record?.job ?? .process
        let progress = dir.appendingPathComponent(ProcessingQueue.progressName)
        try? MeetingStore.writePrivately(Data(), to: progress)
        stage = nil
        token += 1
        let mine = token
        let started = now()
        job = .running(started: started, token: mine, kind: kind)
        // The settings of this moment, read once; an outside writer that cannot be used is said first.
        let settings = self.settings()
        let writer = ScriptRunner.writer(meeting: record?.writer, settings: settings)
        if let aside = writer.setAside { ProcessingQueue.appendLog(dir, ScriptRunner.setAsideLine(aside)) }
        let own = kind == .transcribe ? record : nil // only Transcribe again carries its own choices
        // Its counts as the engine will take them, from the folder as it is now: the room and the call for a
        // meeting with both sides, else the one count of a recording kept as one file.
        let sides = own != nil && MeetingFolder.hasBothSides(dir)
        let arguments = ScriptRunner.arguments(kind: kind, folder: dir, transcriber: own?.jobTranscriber ?? settings.transcriber,
                                               room: sides ? own?.people.room : nil, call: sides ? own?.people.call : nil,
                                               recording: sides ? nil : own?.people.recording, tidy: own?.jobTidy ?? settings.tidy,
                                               writer: writer.use)
        _ = runner.run(PipelineJob(kind: kind, folder: dir, arguments: arguments), progress: progress, attempt: attempt) { [weak self] status, line in
            self?.onQueue { self?.ended(mine, dir, status, line) }
        }
    }

    /// One line added to `<dir>/.process-log` (0600), where the run's own lines follow.
    private static func appendLog(_ dir: URL, _ line: String) {
        let fd = open(dir.appendingPathComponent(ScriptRunner.logName).path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        fchmod(fd, 0o600)
        let data = Data((line + "\n").utf8)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// A run of ours ended: finished by `outcome`, where its meeting is now. A folder moved or renamed in
    /// Finder while it ran is found again (`locate`), and the status this run gave is used there, so
    /// nothing is run twice (the engine's own `.process-result` went to the old path). A meeting in no
    /// root is finished nowhere (`endNowhere`), with the reason its own run gave. The run is known by its
    /// token: the tick may have followed its folder since it was launched.
    private func ended(_ mine: Int, _ dir: URL, _ status: Int32, _ line: String) {
        guard case .running(let started, let t, let kind)? = job, t == mine, let entry = holding else { return }
        guard let here = locate(entry) else {
            var reason = ProcessingQueue.lostFolder
            if status != 0 && status != ProcessingQueue.busyExit {
                switch ProcessingQueue.outcome(kind, status: status, fresh: false, line: line, settled: false) {
                case .failed(let said), .runAgain(let said): reason = said
                case .done: break
                }
            }
            endNowhere(entry, kind: kind, reason: reason)
            return
        }
        holding?.dir = here
        holding?.lost = false
        pollProgress(here)
        if status == ProcessingQueue.busyExit {
            // Refused: nothing ran, so this run is not counted. Wait for the holder, then settle.
            try? store.update(here) { if let n = $0.attempts { $0.attempts = max(0, n - 1) } }
            wait(here)
            onChange?()
            updateTimer()
            return
        }
        job = nil
        finish(here, kind, ProcessingQueue.outcome(kind, status: status, fresh: ProcessingQueue.fresh(here, since: started, kind: kind),
                                                   line: line, settled: false))
        advance()
    }

    /// Another process holds the folder. Its progress (if any) is not in our file, so say why.
    private func wait(_ dir: URL) {
        job = .waiting
        stage = ProcessingQueue.waitingStage
        try? store.update(dir) { $0.stage = ProcessingQueue.waitingStage }
    }

    private func succeed(_ dir: URL, _ kind: JobKind) {
        clearProgress(dir)
        try? store.update(dir) {
            $0.state = .done
            $0.stage = nil
            $0.error = nil
            ProcessingQueue.clearJob(&$0)
        }
        onFinished?(dir, true, kind, nil)
    }

    /// A process that failed is Failed. A redo that did not work, or a job this version cannot read
    /// (`kind` nil), goes back to Done while the meeting has its minutes (else Failed), with `reason` as
    /// the error line the window shows on it.
    private func fail(_ dir: URL, _ kind: JobKind?, _ reason: String) {
        clearProgress(dir)
        let minutes = FileManager.default.fileExists(atPath: dir.appendingPathComponent("notes.md").path)
        try? store.update(dir) {
            $0.state = kind != .process && minutes ? .done : .failed
            $0.stage = nil
            $0.error = reason
            ProcessingQueue.clearJob(&$0)
        }
        onFinished?(dir, false, kind, nil)
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

    /// The queue holds this folder: it is the same folder (device and inode) as a meeting it holds, or,
    /// where nothing is any more, the path one was last found at.
    private func known(_ dir: URL) -> Bool {
        let held = [holding].compactMap { $0 } + pending
        if let identity = FolderIdentity(dir) { return held.contains { $0.identity == identity } }
        return held.contains { $0.dir.path == dir.path }
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

    /// What a job of this kind writes exists and was written at or after `since` (to the second): for
    /// Redo minutes `notes.md`; for a process and Transcribe again `transcript.txt` and `notes.md`. A run
    /// that only finishes an interrupted swap touches each file it moves in, so they count.
    private static func fresh(_ dir: URL, since: Date, kind: JobKind) -> Bool {
        let floor = since.addingTimeInterval(-1)
        let written = kind == .minutes ? ["notes.md"] : ["transcript.txt", "notes.md"]
        return written.allSatisfy { name in
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
