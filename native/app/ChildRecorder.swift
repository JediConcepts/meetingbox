import Darwin
import Foundation

/// The real recorder: a copy of this same executable, run from the helper bundle inside the app
/// (`meetingbox.app/Contents/Helpers/meetingbox-recorder.app`) as `--record`, a child of the app.
/// A recorder connects to the window server, so LaunchServices registers the bundle its
/// executable is in. Run from the app's own executable it was taken for the app itself, and one
/// left running by a crash made macOS refuse to open the app again. The helper has an identifier
/// of its own. It is still our child, so macOS still files the permissions under the app.
///
/// Its stderr is `<dir>/capture.log` itself (0600, appended), not a pipe, so it keeps logging if
/// the app goes away. Health lines are read back by tailing that file: from its start for a
/// recorder launched here, from its end for one adopted after a crash. The next launch finds a
/// running recorder again by its command line, whichever executable started it.
final class ChildRecorder: RecorderControl {
    /// What `--record` and `--recover` run: the helper's executable.
    let executable: URL
    /// The app's own executable: to recognise a recorder the previous build started with it, and to
    /// recover with when the helper is missing (recovery never touches the window server).
    let legacyExecutable: URL
    private let ps: URL
    private let lock = NSLock()
    private var children: [Int32: Process] = [:]
    private var tails: [String: LogTail] = [:]

    /// The helper's name: its bundle is `<name>.app` and its executable `<name>`, in Contents/Helpers
    /// of the app. A process started under this name is the recorder, never the app (LaunchMode).
    static let helperName = "meetingbox-recorder"

    /// The helper's executable inside the app bundle at `app`.
    static func helperExecutable(in app: URL) -> URL {
        app.appendingPathComponent("Contents/Helpers/\(helperName).app/Contents/MacOS/\(helperName)")
    }

    /// `ps` is injectable so a test can make it fail.
    init(executable: URL = ChildRecorder.helperExecutable(in: Bundle.main.bundleURL),
         legacyExecutable: URL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]),
         ps: URL = URL(fileURLWithPath: "/bin/ps")) {
        self.executable = executable
        self.legacyExecutable = legacyExecutable
        self.ps = ps
    }

    /// Shown when a recording cannot start because the helper is not there (an install from before
    /// the helper, or a damaged one). Never worked around by running the app's own executable.
    static let missingMessage = "the recorder is missing; run meetingbox setup"

    /// `--record -o <dir> -n meeting [-d <mic>]`, per the shared contract.
    static func arguments(dir: URL, mic: String?) -> [String] {
        var args = ["--record", "-o", dir.path, "-n", "meeting"]
        if let mic = mic, !mic.isEmpty { args += ["-d", mic] }
        return args
    }

    func launch(dir: URL, mic: String?, onHealthLine: @escaping (String) -> Void) throws -> Int32 {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw SessionError(ChildRecorder.missingMessage)
        }
        let log = try ChildRecorder.openLog(in: dir)
        defer { try? log.close() } // the child has its own copy once it runs
        let process = Process()
        process.executableURL = executable
        process.arguments = ChildRecorder.arguments(dir: dir, mic: mic)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = log
        let tail = LogTail(ChildRecorder.logURL(dir), fromEnd: false, onHealthLine: onHealthLine)
        try process.run()
        let pid = process.processIdentifier
        lock.lock()
        children[pid] = process
        tails[dir.path] = tail
        lock.unlock()
        return pid
    }

    func attach(dir: URL, onHealthLine: @escaping (String) -> Void) {
        let tail = LogTail(ChildRecorder.logURL(dir), fromEnd: true, onHealthLine: onHealthLine)
        lock.lock()
        tails[dir.path] = tail
        lock.unlock()
    }

    func pollLog(dir: URL) { tail(dir)?.poll() }

    func lastMessage(dir: URL) -> String? { tail(dir)?.lastMessage }

    func signal(_ pid: Int32, _ sig: Int32) {
        guard pid > 0 else { return }
        kill(pid, sig)
    }

    func isRunning(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        // Our own child is asked through Process, which reaps it: kill(pid, 0) succeeds on a zombie.
        if let child = child(pid) { return child.isRunning }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    func exitStatus(_ pid: Int32) -> Int32? {
        guard let child = child(pid), !child.isRunning else { return nil }
        return child.terminationReason == .uncaughtSignal ? 128 + child.terminationStatus : child.terminationStatus
    }

    /// The first process whose command line starts `<helper> --record -o <dir> -n`, or the same
    /// with the app's own executable, which is how the previous build started its recorder: one
    /// still running after an upgrade is found and adopted all the same. Unknown when `ps` cannot
    /// be run, fails, or gives nothing readable (it always lists itself).
    func find(dir: URL) -> FindResult {
        let needles = [executable, legacyExecutable].map { "\($0.path) --record -o \(dir.path) -n" }
        let process = Process()
        let out = Pipe()
        process.executableURL = ps
        process.arguments = ["-axo", "pid=,command="]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return .unknown }
        let data = try? out.fileHandleForReading.readToEnd()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0,
              let bytes = data, !bytes.isEmpty, let text = String(data: bytes, encoding: .utf8) else { return .unknown }
        for line in text.split(separator: "\n") {
            let trimmed = line.drop { $0 == " " }
            guard let space = trimmed.firstIndex(of: " "), let pid = Int32(trimmed[..<space]) else { continue }
            let command = trimmed[trimmed.index(after: space)...]
            if needles.contains(where: command.hasPrefix) { return .found(pid) }
        }
        return .notFound
    }

    /// Runs `--recover <dir>` and waits; its stderr is appended to capture.log. Blocks: call it off
    /// the main queue. Exit 75 means another process holds the folder (busy), and only that is
    /// busy. With the helper missing it runs from the app's own executable, which is safe because
    /// recovery never touches the window server, and says so in capture.log. A recovery that cannot
    /// be started at all (neither executable runs) is failed, with the reason in capture.log: never
    /// busy, or an interrupted meeting would stay unrecovered and block setup for good.
    func recover(dir: URL) -> RecoverResult {
        let log = try? ChildRecorder.openLog(in: dir)
        defer { try? log?.close() }
        func note(_ line: String) { try? log?.write(contentsOf: Data((line + "\n").utf8)) }

        var program = executable
        if !FileManager.default.isExecutableFile(atPath: executable.path) {
            note(ChildRecorder.helperMissingNote)
            program = legacyExecutable
        }
        let process = Process()
        process.executableURL = program
        process.arguments = ["--recover", dir.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = log ?? FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            note("meetingbox: cannot recover: the recorder could not be started (\(error.localizedDescription))")
            return .failed
        }
        process.waitUntilExit()
        guard process.terminationReason == .exit else { return .failed }
        switch process.terminationStatus {
        case 0: return .recovered
        case ChildRecorder.busyExit: return .busy
        default: return .failed
        }
    }

    /// Written to capture.log when a recovery has to run from the app's own executable.
    static let helperMissingNote = "meetingbox: the recorder helper is missing; recovering with the app's own executable"

    /// `--recover`'s exit status when the folder's lock is held (EX_TEMPFAIL).
    static let busyExit: Int32 = 75

    /// The duration of `audio.m4a` when `.recording-complete` exists and the three `.m4a` verify.
    func verify(dir: URL) -> Double? {
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent(Finaliser.marker).path),
              let durations = Finaliser.durations(Finaliser.finals.map { dir.appendingPathComponent($0) }),
              let audio = Finaliser.finals.firstIndex(of: "audio.m4a") else { return nil }
        return durations[audio]
    }

    private func child(_ pid: Int32) -> Process? {
        lock.lock()
        defer { lock.unlock() }
        return children[pid]
    }

    private func tail(_ dir: URL) -> LogTail? {
        lock.lock()
        defer { lock.unlock() }
        return tails[dir.path]
    }

    private static func logURL(_ dir: URL) -> URL { dir.appendingPathComponent("capture.log") }

    /// `<dir>/capture.log`, created 0600 (and made 0600 if it already existed), opened to append.
    private static func openLog(in dir: URL) throws -> FileHandle {
        let fd = open(logURL(dir).path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        fchmod(fd, 0o600)
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
}

/// Follows a recorder's capture.log: each `poll()` reads what was appended since the last one,
/// passes on every complete `health ...` line, and remembers the last line that could be the
/// recorder's reason for stopping: not a health line, not an indented continuation line (device
/// lists, file paths), and not one of its progress lines. Polled from one queue at a time, so it
/// needs no lock.
final class LogTail {
    let url: URL
    private var offset: UInt64
    private var pending = Data()
    private let onHealthLine: (String) -> Void
    private var lastLine: String?

    /// `fromEnd`: skip what the file already holds (an adopted recorder's earlier lines).
    init(_ url: URL, fromEnd: Bool, onHealthLine: @escaping (String) -> Void) {
        self.url = url
        self.onHealthLine = onHealthLine
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
        offset = fromEnd ? (size?.uint64Value ?? 0) : 0
    }

    func poll() {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return }
        if size < offset { // replaced or cut short: start again
            offset = 0
            pending.removeAll()
        }
        guard size > offset, (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return }
        offset += UInt64(data.count)
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...newline)
            take(line)
        }
    }

    /// The last line that could be a reason, including one not yet ended by a newline.
    var lastMessage: String? {
        LogTail.reason(String(decoding: pending, as: UTF8.self)) ?? lastLine
    }

    /// What the recorder prints while all is well (Recorder.swift), never a reason for failing.
    private static let progress: Set<String> = ["Starting recording...", "Press Ctrl+C to stop.", "Paused",
                                                "Resumed", "Stopping...", "Available devices:"]
    private static let progressPrefixes = ["Recording started at ", "Saved (", "Recovered ",
                                           "Its working files are kept."]

    private static func reason(_ line: String) -> String? {
        guard let first = line.first, !first.isWhitespace, !line.hasPrefix("health ") else { return nil }
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || progress.contains(text) || progressPrefixes.contains(where: text.hasPrefix) { return nil }
        return text
    }

    private func take(_ line: String) {
        if line.hasPrefix("health ") {
            onHealthLine(line)
        } else if let text = LogTail.reason(line) {
            lastLine = text
        }
    }
}
