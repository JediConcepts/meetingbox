import AppKit
import Combine

/// The one place UI state changes. Owns the core for the app's life: one `MeetingStore` shared by
/// the session and the processing queue, the `Session`, the `ProcessingQueue`, the `ControlHandler`
/// every recording command goes through, and the control socket. Core callbacks reach UI state by
/// hopping here with `Task { @MainActor in ... }`; the core itself runs on the main queue, its tick
/// queue. The menus, floating button and windows (later tasks) are views over this.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var phase: Session.Phase = .idle
    /// The meeting being processed, and its stage.
    @Published private(set) var processing: URL?
    @Published private(set) var stage: String?

    let preferences: Preferences
    let stateDir: URL
    let store: MeetingStore
    let session: Session
    let queue: ProcessingQueue
    let handler: ControlHandler
    private var server: ControlServer?
    /// `show` from the socket (a second launch, or the command): bring the app forward.
    var onShow: (() -> Void)?

    init(stateDir: URL, preferences: Preferences) {
        self.stateDir = stateDir
        self.preferences = preferences
        let store = MeetingStore(root: preferences.meetingsFolder)
        // Free space where the recording is (or, before one starts, in the meetings folder).
        let box = SessionBox()
        let session = Session(stateDir: stateDir, recorder: ChildRecorder(), store: store, now: Date.init,
                              freeBytes: { AppModel.freeBytes(near: box.session?.phase.folder ?? store.root) })
        box.session = session
        let script = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/meetingbox")
        self.store = store
        self.session = session
        self.queue = ProcessingQueue(store: store, runner: ScriptRunner.fromBundle() ?? ScriptRunner(script: script))
        self.handler = ControlHandler(session: session, preferences: preferences)
    }

    /// In this order: take up a recording left by a crash (Task 4), pick up the processing queue
    /// (Task 5), then answer on the socket. The caller already holds `app.lock`.
    func launch() {
        let queue = self.queue
        session.onChange = { [weak self] phase in Task { @MainActor in self?.phase = phase } }
        // Only verified audio is queued; a failed recording is never processed.
        session.onFinished = { dir, ok in if ok { queue.enqueue(dir) } }
        queue.onChange = { [weak self] in
            let (current, stage) = (queue.current, queue.stage)
            Task { @MainActor in
                self?.processing = current
                self?.stage = stage
            }
        }
        queue.onFinished = { [weak self] _, ok in Task { @MainActor in if ok { self?.play("Glass") } } }
        handler.onStarted = { [weak self] _ in Task { @MainActor in self?.play("Tink") } }
        handler.onStopped = { [weak self] _ in Task { @MainActor in self?.play("Pop") } }
        handler.onShow = { [weak self] in Task { @MainActor in self?.onShow?() } }

        session.adopt()
        queue.resume()
        do {
            let server = try ControlServer(socket: stateDir.appendingPathComponent("control.sock"), handler: handler)
            server.start()
            self.server = server
        } catch {
            NSLog("meetingbox: the control socket could not be opened: %@", error.localizedDescription)
        }
    }

    /// At quit: the socket goes. A recorder keeps running (it is its own process) and the next
    /// launch adopts it; the kernel releases `app.lock` when the process ends.
    func shutDown() {
        server?.stop()
        server = nil
    }

    /// The start, stop and done sounds, unless they are turned off.
    func play(_ name: String) {
        guard preferences.sounds else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    /// Free bytes on the volume holding `url`, or on its nearest existing parent.
    nonisolated static func freeBytes(near url: URL) -> Int64 {
        var dir = url
        while !FileManager.default.fileExists(atPath: dir.path), dir.pathComponents.count > 1 {
            dir = dir.deletingLastPathComponent()
        }
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: dir.path)
        return (attrs?[.systemFreeSize] as? NSNumber)?.int64Value ?? Int64.max
    }
}

/// Lets the session's free-space closure see the session, which does not exist yet when the closure is made.
private final class SessionBox {
    weak var session: Session?
}
