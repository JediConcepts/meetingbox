import Darwin
import Foundation

/// The real recorder: this same executable run as `--record`, a child of the app. Its stderr is
/// `<dir>/capture.log` itself (0600, appended), not a pipe, so it keeps logging if the app goes
/// away. Health lines are read back by tailing that file: from its start for a recorder launched
/// here, from its end for one adopted after a crash. The next launch finds a running recorder
/// again by its command line.
final class ChildRecorder: RecorderControl {
    let executable: URL
    private let ps: URL
    private let lock = NSLock()
    private var children: [Int32: Process] = [:]
    private var tails: [String: LogTail] = [:]

    /// `ps` is injectable so a test can make it fail.
    init(executable: URL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]),
         ps: URL = URL(fileURLWithPath: "/bin/ps")) {
        self.executable = executable
        self.ps = ps
    }

    /// `--record -o <dir> -n meeting [-d <mic>]`, per the shared contract.
    static func arguments(dir: URL, mic: String?) -> [String] {
        var args = ["--record", "-o", dir.path, "-n", "meeting"]
        if let mic = mic, !mic.isEmpty { args += ["-d", mic] }
        return args
    }

    func launch(dir: URL, mic: String?, onHealthLine: @escaping (String) -> Void) throws -> Int32 {
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

    /// The first process whose command line starts `<executable> --record -o <dir> -n`. Unknown
    /// when `ps` cannot be run, fails, or gives nothing readable (it always lists itself).
    func find(dir: URL) -> FindResult {
        let needle = "\(executable.path) --record -o \(dir.path) -n"
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
            if trimmed[trimmed.index(after: space)...].hasPrefix(needle) { return .found(pid) }
        }
        return .notFound
    }

    /// Runs `--recover <dir>` and waits; its stderr is appended to capture.log. Blocks: call it off
    /// the main queue. Exit 75 means another process holds the folder (busy); a recovery that
    /// cannot even be started is reported as busy too, so nothing is marked failed on its account.
    func recover(dir: URL) -> RecoverResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--recover", dir.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let log = try? ChildRecorder.openLog(in: dir)
        process.standardError = log ?? FileHandle.nullDevice
        defer { try? log?.close() }
        guard (try? process.run()) != nil else { return .busy }
        process.waitUntilExit()
        guard process.terminationReason == .exit else { return .failed }
        switch process.terminationStatus {
        case 0: return .recovered
        case ChildRecorder.busyExit: return .busy
        default: return .failed
        }
    }

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
/// passes on every complete `health ...` line, and remembers the last other line (the recorder's
/// own account of why it stopped). Polled from one queue at a time, so it needs no lock.
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

    /// The last line that is not a health line, including one not yet ended by a newline.
    var lastMessage: String? {
        let partial = String(decoding: pending, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !partial.isEmpty && !partial.hasPrefix("health ") { return partial }
        return lastLine
    }

    private func take(_ line: String) {
        if line.hasPrefix("health ") {
            onHealthLine(line)
        } else {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { lastLine = text }
        }
    }
}
