import AppKit
import Combine

/// The one place UI state changes. Owns the core for the app's life: one `MeetingStore` shared by
/// the session and the processing queue, the `Session`, the `ProcessingQueue`, the `ControlHandler`
/// every recording command goes through, and the control socket. Core callbacks reach UI state by
/// hopping here with `Task { @MainActor in ... }`; the core itself runs on the main queue, its tick
/// queue. The menu bar item, the floating button and the windows (later tasks) are views over this;
/// every action they offer comes back through `perform`, and from there through `ControlHandler`,
/// the one path the socket uses too.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var phase: Session.Phase = .idle
    /// Recorded time, and the capture health, refreshed each second while recording or paused.
    @Published private(set) var seconds = 0
    @Published private(set) var health = Session.Health(mic: .ok, system: .ok, disk: .ok)
    /// The meeting being processed, and its stage.
    @Published private(set) var processing: URL?
    @Published private(set) var stage: String?
    /// The meeting whose minutes were finished last, until it is opened or the next recording starts.
    @Published private(set) var ready: URL?
    /// Why the last start did not work, until the next action.
    @Published private(set) var failure: String?

    let preferences: Preferences
    let stateDir: URL
    let store: MeetingStore
    let session: Session
    let queue: ProcessingQueue
    let handler: ControlHandler
    private var server: ControlServer?
    private var clock: DispatchSourceTimer?
    /// `show` from the socket (a second launch, or the command): bring the app forward.
    var onShow: (() -> Void)?

    init(stateDir: URL, preferences: Preferences) {
        self.stateDir = stateDir
        self.preferences = preferences
        let store = MeetingStore(root: preferences.meetingsFolder)
        let session = Session(stateDir: stateDir, recorder: ChildRecorder(), store: store, now: Date.init,
                              freeBytes: { AppModel.freeBytes(near: $0) })
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
        session.onChange = { [weak self] phase in Task { @MainActor in self?.changed(to: phase) } }
        // Only verified audio is queued; a failed recording is never processed.
        session.onFinished = { dir, ok in if ok { queue.enqueue(dir) } }
        queue.onChange = { [weak self] in
            let (current, stage) = (queue.current, queue.stage)
            Task { @MainActor in
                self?.processing = current
                self?.stage = stage
            }
        }
        queue.onFinished = { [weak self] dir, ok in
            Task { @MainActor in
                guard ok else { return }
                self?.ready = dir
                self?.play("Glass")
            }
        }
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

    /// What the menu bar item and the floating button show now.
    var presentation: StatusPresentation {
        StatusPresentation(StatusInput(phase: phase, seconds: seconds, health: health, processing: processing, stage: stage,
                                       ready: ready, failure: failure, floating: preferences.floating))
    }

    /// A menu entry or floating button was chosen. Recording commands go through the same
    /// `ControlHandler` as the socket, so a click and `meetingbox start` get the same answers;
    /// nothing here waits (a modal alert would block the queue the session ticks on).
    func perform(_ action: MenuAction) {
        failure = nil
        switch action {
        case .none, .separator, .preferences:
            break // the preferences window comes with Task 9
        case .start:
            send(.start(mic: nil, dir: nil))
        case .pause:
            send(.pause)
        case .resume:
            send(.resume)
        case .stop:
            send(.stop)
        case .showFolder(let dir):
            NSWorkspace.shared.open(dir)
        case .openMeetingbox:
            // Task 8 opens the library window instead.
            NSWorkspace.shared.open(preferences.meetingsFolder)
        case .openMinutes(let dir):
            // Task 8 opens the meeting in the window instead.
            if ready == dir { ready = nil }
            let notes = dir.appendingPathComponent("notes.md")
            NSWorkspace.shared.open(FileManager.default.fileExists(atPath: notes.path) ? notes : dir)
        case .quit:
            NSApp.terminate(nil)
        }
    }

    private func send(_ request: ControlRequest) {
        // The handler is used only on its own queue, which is what makes it safe to hand to it.
        nonisolated(unsafe) let handler = self.handler
        handler.queue.async { [weak self] in
            handler.perform(request) { reply in
                Task { @MainActor in self?.answered(request, reply) }
            }
        }
    }

    /// Only a start that fails is shown (the icon and the menu's first line). A pause or stop that
    /// loses a race with the recorder ending changes nothing worth a warning.
    private func answered(_ request: ControlRequest, _ reply: String) {
        guard reply.hasPrefix("error ") else { return }
        let reason = String(reply.dropFirst("error ".count))
        if case .start = request {
            failure = reason
        } else {
            NSLog("meetingbox: %@ was refused: %@", String(describing: request), reason)
        }
    }

    /// The session moved to `new`: remember it, start the clock when there is one to show, and
    /// forget the last minutes and any old failure once a recording is under way.
    private func changed(to new: Session.Phase) {
        let began = phase == .idle
        phase = new
        if case .recording = new, began {
            ready = nil
            failure = nil
        }
        refreshClock()
    }

    /// Once a second while recording or paused, on the main queue (the session's tick queue), so
    /// reading the session here is safe. Stops when idle.
    private func refreshClock() {
        switch phase {
        case .recording, .paused:
            let (now, current) = (session.recordedSeconds(at: Date()), session.health)
            if seconds != now { seconds = now }
            if health != current { health = current }
            guard clock == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in Task { @MainActor in self?.refreshClock() } }
            timer.resume()
            clock = timer
        case .idle, .finalising:
            clock?.cancel()
            clock = nil
            if seconds != 0 { seconds = 0 }
        }
    }

    /// The start, stop and done sounds, unless they are turned off.
    func play(_ name: String) {
        guard preferences.sounds else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    /// Free bytes on the volume holding `url`, or on its nearest existing parent; nil when unreadable.
    nonisolated static func freeBytes(near url: URL) -> Int64? {
        var dir = url
        while !FileManager.default.fileExists(atPath: dir.path), dir.pathComponents.count > 1 {
            dir = dir.deletingLastPathComponent()
        }
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: dir.path)
        return (attrs?[.systemFreeSize] as? NSNumber)?.int64Value
    }
}
