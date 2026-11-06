import Darwin
import Foundation

// The private control socket, `~/.meetingbox/control.sock`: one request line in, one reply line
// out, then close. The `meetingbox` command is its client. Only the instance holding `app.lock`
// binds it. Foundation only, so it is tested without the app.

/// One request on the socket:
/// `status`, `start [mic=<pct>] [dir=<pct>]`, `pause`, `resume`, `stop`, `toggle [mic=...] [dir=...]`, `show`.
enum ControlRequest: Equatable {
    case status
    case start(mic: String?, dir: String?)
    case pause, resume, stop
    case toggle(mic: String?, dir: String?)
    case show

    /// Nil for anything that is not exactly one well formed request: unknown words, extra or
    /// repeated arguments, empty values, bad percent-encoding, control characters, more than one line.
    static func parse(_ line: String) -> ControlRequest? {
        guard !line.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        let words = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let args = Array(words.dropFirst())
        switch words[0] {
        case "status": return args.isEmpty ? .status : nil
        case "pause": return args.isEmpty ? .pause : nil
        case "resume": return args.isEmpty ? .resume : nil
        case "stop": return args.isEmpty ? .stop : nil
        case "show": return args.isEmpty ? .show : nil
        case "start", "toggle":
            var mic: String?
            var dir: String?
            for arg in args {
                guard let eq = arg.firstIndex(of: "=") else { return nil }
                let key = arg[..<eq]
                guard let value = String(arg[arg.index(after: eq)...]).removingPercentEncoding, !value.isEmpty,
                      !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
                switch key {
                case "mic" where mic == nil: mic = value
                case "dir" where dir == nil: dir = value
                default: return nil
                }
            }
            return words[0] == "start" ? .start(mic: mic, dir: dir) : .toggle(mic: mic, dir: dir)
        default:
            return nil
        }
    }
}

/// Turns requests into the session's answers. Serial: every reply is computed on `queue`, the
/// session's tick queue, so two requests that arrive together are answered one after the other.
/// Every recording command, whatever it comes from, goes through here. Sounds and windows are the
/// app's: it hears about starts, stops, refusals and `show` through the closures, called on `queue`.
///
/// A start counts only once its recorder has stayed up for `startGrace`: one that exits at once (a
/// missing permission, no microphone matching) is reported with its reason, not as recording. While
/// the last recording is still being saved, start and toggle are refused: nothing new starts.
final class ControlHandler {
    /// What a request comes to: a reply now, or a start decided once the recorder has survived.
    enum Handled: Equatable { case reply(String), starting(URL) }
    /// How long a new recorder must stay up before its start is reported (the session's own grace).
    static let startGrace: TimeInterval = Session.startGrace
    /// After the grace, how long more to wait for a recorder that died to be settled.
    static let settleLimit: TimeInterval = 10
    static let cannotReach = "error cannot reach the recorder right now, try again"

    let queue: DispatchQueue
    private let session: Session
    private let preferences: Preferences
    /// A recording started (for the start sound).
    var onStarted: ((URL) -> Void)?
    /// A recording or paused session was asked to stop (for the stop sound).
    var onStopped: ((URL) -> Void)?
    /// `show`: bring the app forward.
    var onShow: (() -> Void)?
    /// A start or toggle was refused because the last recording is still being saved (for the
    /// failure sound).
    var onRefused: (() -> Void)?
    /// The folder of the last recording a stop was asked for (on `queue`), so a start still settling
    /// for it is told apart from one that failed.
    private var stoppedFolder: URL?

    /// The queue is the session's tick queue, so the two can never differ.
    init(session: Session, preferences: Preferences) {
        self.session = session
        self.preferences = preferences
        self.queue = session.tickQueue ?? .main
    }

    /// `ok <state> <folder or ->` or `error <message>`, always one line, without waiting: a start is
    /// reported on the state it is in at once. The socket uses `handle` and `startOutcome`. Call on `queue`.
    func reply(for request: ControlRequest) -> String {
        switch handle(request) {
        case .reply(let text): return text
        case .starting(let dir): return startOutcome(dir, settled: true, giveUp: true) ?? status()
        }
    }

    /// `handle` for a caller that must not wait: the menu and the floating button run on `queue`,
    /// which is the main queue in the app. Call on `queue`. A reply completes at once. A start is
    /// re-checked on `queue` every `pollInterval`, by the socket's rules (settled once `startGrace` has
    /// passed, given up on once `settleLimit` more has), and completes with its final line, on `queue`.
    /// As on the socket, a start that is then stopped within the grace is not reported as a failure;
    /// unlike the socket, one that is paused within it is not announced as a start either: the menu
    /// puts Pause and Stop one click away from Start.
    func perform(_ request: ControlRequest, completion: @escaping (String) -> Void) {
        switch handle(request) {
        case .reply(let text):
            completion(text)
        case .starting(let dir):
            let settleAt = Date().addingTimeInterval(ControlHandler.startGrace)
            awaitStart(dir, settleAt: settleAt, giveUpAt: settleAt.addingTimeInterval(ControlHandler.settleLimit), completion)
        }
    }

    /// How often `perform` looks again at a start that is not decided.
    static let pollInterval: DispatchTimeInterval = .milliseconds(250)

    private func awaitStart(_ dir: URL, settleAt: Date, giveUpAt: Date, _ completion: @escaping (String) -> Void) {
        queue.asyncAfter(deadline: .now() + ControlHandler.pollInterval) { [self] in
            let now = Date()
            let settled = now >= settleAt
            let outcome: String?
            if case .paused(let paused) = session.phase, paused == dir {
                outcome = settled ? status() : nil // paused within the grace: no start sound; wait for the recorder to prove itself
            } else {
                outcome = startOutcome(dir, settled: settled, giveUp: now >= giveUpAt)
            }
            if let outcome = outcome {
                completion(outcome)
            } else {
                awaitStart(dir, settleAt: settleAt, giveUpAt: giveUpAt, completion)
            }
        }
    }

    /// Call on `queue`. A start that launched comes back as `.starting`: ask `startOutcome` until it answers.
    func handle(_ request: ControlRequest) -> Handled {
        dispatchPrecondition(condition: .onQueue(queue))
        let handled = handleRequest(request)
        if case .reply(let text) = handled { return .reply(ControlHandler.oneLine(text)) }
        return handled
    }

    private func handleRequest(_ request: ControlRequest) -> Handled {
        switch request {
        case .status:
            return .reply(status())
        case .start(let mic, let dir):
            return start(mic: mic, dir: dir)
        case .toggle(let mic, let dir):
            // While the last recording is being saved, toggle neither stops it again nor starts
            // another: it is refused as a start is.
            switch session.phase {
            case .idle, .finalising: return start(mic: mic, dir: dir)
            case .recording, .paused: return .reply(stop())
            }
        case .pause:
            return .reply(whileRecording(wanted: { if case .paused = $0 { return true }; return false }) { session.pause() })
        case .resume:
            return .reply(whileRecording(wanted: { if case .recording = $0 { return true }; return false }) { session.resume() })
        case .stop:
            return .reply(stop())
        case .show:
            onShow?()
            return .reply(status())
        }
    }

    /// Where a start stands, nil while undecided. Call on `queue`. `settled`: the grace has passed;
    /// `giveUp`: stop waiting for a dead recorder to be settled. The start sound goes only with `ok`.
    /// A start that any client then stopped (a second press of the hotkey, or Stop) is answered with
    /// the status, not as a failed start, and plays no start sound.
    func startOutcome(_ dir: URL, settled: Bool, giveUp: Bool) -> String? {
        dispatchPrecondition(condition: .onQueue(queue))
        if stoppedFolder == dir { return status() }
        switch session.phase {
        case .recording(let d) where d == dir, .paused(let d) where d == dir:
            guard settled else { return nil }
            onStarted?(dir)
            return "ok recording \(dir.path)"
        case .finalising(let d) where d == dir:
            // It stopped already; its reason is written once it is settled.
            return giveUp ? ControlHandler.oneLine("error the recorder stopped straight after it started; its files are in \(dir.path)") : nil
        default:
            return ControlHandler.oneLine("error \(ControlHandler.failure(dir))")
        }
    }

    /// The reason Session recorded for a recording that ended at once.
    private static func failure(_ dir: URL) -> String {
        if let data = try? Data(contentsOf: dir.appendingPathComponent("meeting.json")),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let error = obj["error"] as? String, !error.isEmpty {
            return error
        }
        return "the recorder stopped straight after it started; its files are in \(dir.path)"
    }

    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    private func status() -> String {
        switch session.phase {
        case .idle: return "ok idle -"
        case .recording(let dir): return "ok recording \(dir.path)"
        case .paused(let dir): return "ok paused \(dir.path)"
        case .finalising(let dir): return "ok finalising \(dir.path)"
        }
    }


    /// The request's folder beats the meetings folder setting, and its mic the microphone setting.
    /// While the last recording is being saved nothing starts, in Session's words, and the app is
    /// told, for its failure sound.
    private func start(mic: String?, dir: String?) -> Handled {
        if case .finalising = session.phase {
            onRefused?()
            return .reply(ControlHandler.oneLine("error \(Session.stillSaving)"))
        }
        let root: URL
        if let dir = dir {
            guard dir.hasPrefix("/") else { return .reply(ControlHandler.oneLine("error the folder must be a full path: \(dir)")) }
            root = URL(fileURLWithPath: dir, isDirectory: true)
        } else {
            root = preferences.meetingsFolder
        }
        do {
            return .starting(try session.start(root: root, mic: mic ?? preferences.microphone))
        } catch {
            return .reply(ControlHandler.oneLine("error \(error.localizedDescription)"))
        }
    }

    /// Replies once the session is finalising; the folder is in the reply.
    private func stop() -> String {
        let running: Bool
        switch session.phase {
        case .recording, .paused: running = true
        case .idle, .finalising: running = false
        }
        guard let dir = session.stop() else { return "error not recording" }
        if running {
            stoppedFolder = dir
            onStopped?(dir)
        }
        return ControlHandler.oneLine("ok finalising \(dir.path)")
    }

    /// Pause or resume. When the session is still where it was and not where it was asked to be,
    /// the recorder could not be reached (its identity cannot be checked), so nothing was sent.
    private func whileRecording(wanted: (Session.Phase) -> Bool, _ change: () -> Void) -> String {
        switch session.phase {
        case .idle: return "error not recording"
        case .finalising(let dir): return ControlHandler.oneLine("error the recording in \(dir.path) has already stopped")
        case .recording, .paused:
            let before = session.phase
            change()
            if session.phase == before && !wanted(before) { return ControlHandler.cannotReach }
            return ControlHandler.oneLine(status())
        }
    }
}

struct ControlError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The listening socket. Accepts on its own queue and reads each request on a connection queue,
/// off the main thread; the reply itself is computed on the handler's queue.
final class ControlServer {
    let socket: URL
    private let handler: ControlHandler
    private var fd: Int32
    private var source: DispatchSourceRead?
    private let acceptQueue = DispatchQueue(label: "meetingbox.control.accept")
    private let connections = DispatchQueue(label: "meetingbox.control.connection", attributes: .concurrent)
    /// The socket file this server made, so `stop` removes only its own.
    private var inode: ino_t = 0
    /// A request line longer than this is refused.
    static let maxLine = 8192

    /// Makes the folder (0700), replaces a socket file left by a dead instance (one that refuses a
    /// connection), binds, makes the socket 0600 and listens. Throws, touching nothing, when another
    /// instance is answering on the socket or the path is something other than a socket.
    init(socket: URL, handler: ControlHandler) throws {
        self.socket = socket
        self.handler = handler
        try ControlServer.privateFolder(socket.deletingLastPathComponent())
        guard var addr = ControlServer.address(socket.path) else {
            throw ControlError("the socket path is too long: \(socket.path)")
        }
        try ControlServer.clearStale(socket.path)
        // Kept in a local until it listens: a throw before `fd` is set runs no deinit, so the one
        // close below is the only one (a deinit after a failure would close the number again,
        // perhaps someone else's by then).
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlServer.posix("could not make the socket") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        // Set on the listener so every accepted socket has it from the start: on one whose client
        // has already gone, setting it fails (EINVAL), and a reply written to it would otherwise
        // raise SIGPIPE for the whole app.
        ControlServer.noSigPipe(fd)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let error = ControlServer.posix("could not bind \(socket.path)")
            close(fd)
            throw error
        }
        // The folder is 0700, so nobody else can reach the socket in the moment before this.
        chmod(socket.path, 0o600)
        var st = stat()
        if lstat(socket.path, &st) == 0 { inode = st.st_ino }
        guard listen(fd, 16) == 0 else {
            let error = ControlServer.posix("could not listen on \(socket.path)")
            close(fd)
            unlink(socket.path)
            throw error
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        self.fd = fd
    }

    deinit { stop() }

    func start() {
        guard source == nil, fd >= 0 else { return }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        let listening = fd
        src.setEventHandler { [weak self] in self?.acceptAll(listening) }
        src.setCancelHandler { close(listening) }
        source = src
        src.resume()
    }

    /// Stops listening and removes the socket file, if it is still the one this server made.
    func stop() {
        guard fd >= 0 else { return }
        var st = stat()
        if lstat(socket.path, &st) == 0, st.st_ino == inode { unlink(socket.path) }
        if let src = source { src.cancel() } else { close(fd) }
        source = nil
        fd = -1
    }

    /// `listening` is the descriptor `start()` captured: `fd` itself is changed by `stop()` on another queue.
    private func acceptAll(_ listening: Int32) {
        while true {
            let c = accept(listening, nil, nil)
            if c < 0 {
                if errno == EINTR { continue }
                return // EAGAIN: nothing more waiting
            }
            _ = fcntl(c, F_SETFD, FD_CLOEXEC)
            connections.async { [handler] in ControlServer.serve(c, handler) }
        }
    }

    /// Reads one line, answers it, closes. Only the user who owns the app is answered.
    private static func serve(_ c: Int32, _ handler: ControlHandler) {
        defer { close(c) }
        var uid = uid_t(0), gid = gid_t(0)
        guard getpeereid(c, &uid, &gid) == 0, uid == getuid() else { return }
        _ = fcntl(c, F_SETFL, fcntl(c, F_GETFL) & ~O_NONBLOCK) // SO_NOSIGPIPE comes from the listener
        setTimeout(c, 5)
        guard let line = readLine(c) else { return }
        let reply: String
        if let text = String(data: line, encoding: .utf8), let request = ControlRequest.parse(text) {
            switch handler.queue.sync(execute: { handler.handle(request) }) {
            case .reply(let text):
                reply = text
            case .starting(let dir):
                // Waits here, on the connection's thread, never on the handler's queue or main.
                let settleAt = Date().addingTimeInterval(ControlHandler.startGrace)
                let giveUpAt = settleAt.addingTimeInterval(ControlHandler.settleLimit)
                var outcome: String?
                while outcome == nil {
                    usleep(100_000)
                    let now = Date()
                    outcome = handler.queue.sync { handler.startOutcome(dir, settled: now >= settleAt, giveUp: now >= giveUpAt) }
                }
                reply = outcome ?? "error not recording"
            }
        } else {
            reply = "error unknown request"
        }
        writeAll(c, Data((reply + "\n").utf8))
    }

    // MARK: helpers shared with the client

    /// A folder made 0700, or made 0700 if it is ours and already there.
    static func privateFolder(_ dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var st = stat()
        if lstat(dir.path, &st) == 0, st.st_uid == getuid(), st.st_mode & 0o777 != 0o700 { chmod(dir.path, 0o700) }
    }

    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
        }
        return addr
    }

    /// A socket file nobody listens on (connect is refused) is removed. One with a listener, or a
    /// path that is not a socket at all, is left as it is and the server does not start.
    private static func clearStale(_ path: String) throws {
        var st = stat()
        guard lstat(path, &st) == 0 else {
            if errno == ENOENT { return }
            throw posix("could not look at \(path)")
        }
        guard st.st_mode & S_IFMT == S_IFSOCK else {
            throw ControlError("\(path) is not a socket; it is left as it is")
        }
        switch connectTo(path) {
        case .connected(let fd):
            close(fd)
            throw ControlError("another meetingbox is already answering on \(path)")
        case .failed(ECONNREFUSED):
            unlink(path)
        case .failed(let e):
            throw ControlError("could not check \(path): \(String(cString: strerror(e)))")
        }
    }

    enum Connect { case connected(Int32), failed(Int32) }

    static func connectTo(_ path: String) -> Connect {
        guard var addr = address(path) else { return .failed(ENAMETOOLONG) }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failed(errno) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        noSigPipe(fd) // before connecting, while it can still be set
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if rc != 0 {
            let e = errno
            close(fd)
            return .failed(e)
        }
        return .connected(fd)
    }

    /// A write to a socket whose peer has gone fails with EPIPE instead of raising SIGPIPE. The app
    /// cannot ignore SIGPIPE process-wide: an ignored signal is inherited by the recorder and the
    /// script it launches.
    static func noSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func setTimeout(_ fd: Int32, _ seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// The bytes before the first newline, or before the end if the peer closes first. Nil on a
    /// timeout, an error, or a line over `maxLine`.
    static func readLine(_ fd: Int32) -> Data? {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 1024)
        while data.count <= maxLine {
            if let nl = data.firstIndex(of: 0x0A) { return data[data.startIndex..<nl] }
            let n = read(fd, &buf, buf.count)
            if n == 0 { return data }
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            data.append(contentsOf: buf[0..<n])
        }
        return nil
    }

    @discardableResult
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                off += n
            }
            return true
        }
    }

    private static func posix(_ what: String) -> ControlError {
        ControlError("\(what): \(String(cString: strerror(errno)))")
    }
}

/// The client side, for a second instance asking the first to `show`, and for tests.
enum ControlClient {
    /// The reply line, "" when the connection closed with no reply, nil when nothing is listening.
    static func send(_ line: String, to socket: URL, timeout: TimeInterval = 5) -> String? {
        guard case .connected(let fd) = ControlServer.connectTo(socket.path) else { return nil }
        defer { close(fd) }
        ControlServer.setTimeout(fd, timeout)
        guard ControlServer.writeAll(fd, Data((line + "\n").utf8)), let reply = ControlServer.readLine(fd) else { return "" }
        return String(decoding: reply, as: UTF8.self)
    }
}

/// `app.lock`: an exclusive `flock`, held for the app's life and released by the kernel when the
/// process ends, however it ends. Only the holder binds the socket.
final class AppLock {
    private var fd: Int32

    private init(fd: Int32) { self.fd = fd }

    /// Nil when another instance (in this process or any other) holds it.
    static func take(_ url: URL) -> AppLock? {
        guard (try? ControlServer.privateFolder(url.deletingLastPathComponent())) != nil else { return nil }
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        fchmod(fd, 0o600)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return AppLock(fd: fd)
    }

    /// Closing the file releases the lock.
    func release() {
        guard fd >= 0 else { return }
        close(fd)
        fd = -1
    }

    deinit { release() }
}
