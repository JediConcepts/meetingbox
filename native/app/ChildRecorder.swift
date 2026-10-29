import Darwin
import Foundation

/// The real recorder: this same executable run as `--record`, a child of the app. Its stderr is
/// teed: every byte goes to `<dir>/capture.log` (0600) and each `health ...` line to the caller.
/// The recorder ignores SIGPIPE, so it keeps recording if the app goes away and the pipe breaks;
/// the next launch finds it again by its command line.
final class ChildRecorder: RecorderControl {
    let executable: URL
    private let lock = NSLock()
    private var children: [Int32: Process] = [:]

    init(executable: URL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])) {
        self.executable = executable
    }

    /// `--record -o <dir> -n meeting [-d <mic>]`, per the shared contract.
    static func arguments(dir: URL, mic: String?) -> [String] {
        var args = ["--record", "-o", dir.path, "-n", "meeting"]
        if let mic = mic, !mic.isEmpty { args += ["-d", mic] }
        return args
    }

    func launch(dir: URL, mic: String?, onHealthLine: @escaping (String) -> Void) throws -> Int32 {
        let log = try ChildRecorder.openLog(in: dir)
        let pipe = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = ChildRecorder.arguments(dir: dir, mic: mic)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = pipe
        let tee = LineTee(log: log) { line in
            if line.hasPrefix("health ") { onHealthLine(line) }
        }
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                tee.finish()
            } else {
                tee.feed(data)
            }
        }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            tee.finish()
            throw error
        }
        let pid = process.processIdentifier
        lock.lock()
        children[pid] = process
        lock.unlock()
        return pid
    }

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

    /// The first process whose command line starts `<executable> --record -o <dir> -n`.
    func find(dir: URL) -> Int32? {
        let needle = "\(executable.path) --record -o \(dir.path) -n"
        let ps = Process()
        let out = Pipe()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,command="]
        ps.standardInput = FileHandle.nullDevice
        ps.standardOutput = out
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let trimmed = line.drop { $0 == " " }
            guard let space = trimmed.firstIndex(of: " "), let pid = Int32(trimmed[..<space]) else { continue }
            if trimmed[trimmed.index(after: space)...].hasPrefix(needle) { return pid }
        }
        return nil
    }

    /// Runs `--recover <dir>` and waits; its stderr is appended to capture.log. Blocks: call it off
    /// the main queue.
    func recover(dir: URL) -> Bool {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--recover", dir.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let log = try? ChildRecorder.openLog(in: dir)
        process.standardError = log ?? FileHandle.nullDevice
        defer { try? log?.close() }
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationReason == .exit && process.terminationStatus == 0
    }

    func verify(dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(Finaliser.marker).path)
            && Finaliser.verify(directory: dir)
    }

    private func child(_ pid: Int32) -> Process? {
        lock.lock()
        defer { lock.unlock() }
        return children[pid]
    }

    /// `<dir>/capture.log`, created 0600 (and made 0600 if it already existed), opened to append.
    private static func openLog(in dir: URL) throws -> FileHandle {
        let path = dir.appendingPathComponent("capture.log").path
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        fchmod(fd, 0o600)
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
}

/// Writes every byte to the log as it arrives and hands on each complete line. Fed from one
/// readability handler at a time, so it needs no lock.
private final class LineTee {
    private let log: FileHandle
    private let onLine: (String) -> Void
    private var pending = Data()

    init(log: FileHandle, onLine: @escaping (String) -> Void) {
        self.log = log
        self.onLine = onLine
    }

    func feed(_ data: Data) {
        try? log.write(contentsOf: data)
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            onLine(String(decoding: line, as: UTF8.self))
        }
    }

    func finish() {
        if !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)) }
        pending.removeAll()
        try? log.close()
    }
}
