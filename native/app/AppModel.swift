import AppKit
import Combine

/// The one place UI state changes. Owns the core for the app's life: one `MeetingStore` shared by
/// the session and the processing queue, the `Session`, the `ProcessingQueue`, the `ControlHandler`
/// every recording command goes through, and the control socket. Core callbacks reach UI state by
/// hopping here with `Task { @MainActor in ... }`; the core itself runs on the main queue, its tick
/// queue. The menu bar item, the floating button and the meetingbox window are views over this; every
/// recording action they offer comes back through `perform`, and from there through `ControlHandler`,
/// the one path the socket uses too. The window's own state is `library`.
@MainActor
final class AppModel: ObservableObject {
    /// What the views show, changed only by `StatusEvent`s (StatusReducer.swift, where the rules are
    /// tested): the phase, the recorded time and health, the job being processed and its stage, the
    /// meeting whose minutes are ready, and what the user asked for last that did not work.
    @Published private(set) var status = StatusInput()
    var phase: Session.Phase { status.phase }
    var processing: URL? { status.processing }
    var stage: String? { status.stage }

    let preferences: Preferences
    let stateDir: URL
    let store: MeetingStore
    let session: Session
    let queue: ProcessingQueue
    let handler: ControlHandler
    /// What the meetingbox window shows and remembers (LibraryModel.swift).
    let library: LibraryModel
    private var server: ControlServer?
    private var clock: DispatchSourceTimer?
    /// Bring the meetingbox window forward (AppDelegate makes it the first time).
    var onOpenLibrary: (@MainActor () -> Void)?

    init(stateDir: URL, preferences: Preferences) {
        self.stateDir = stateDir
        self.preferences = preferences
        let store = MeetingStore(root: preferences.meetingsFolder)
        let session = Session(stateDir: stateDir, recorder: ChildRecorder(), store: store, now: Date.init,
                              freeBytes: { AppModel.freeBytes(near: $0) })
        let script = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/meetingbox")
        let queue = ProcessingQueue(store: store, runner: ScriptRunner.fromBundle() ?? ScriptRunner(script: script))
        self.store = store
        self.session = session
        self.queue = queue
        self.handler = ControlHandler(session: session, preferences: preferences)
        self.library = LibraryModel(store: store, session: session, queue: queue)
        // The window's Pause, Resume and Stop take the path the menu's do.
        library.control = { [weak self] action in self?.perform(action) }
    }

    /// In this order: take up a recording left by a crash (Task 4), pick up the processing queue
    /// (Task 5), then answer on the socket. The caller already holds `app.lock`.
    func launch() {
        let queue = self.queue
        session.onChange = { [weak self] phase in
            Task { @MainActor in
                self?.apply(.phase(phase))
                self?.syncClock()
            }
        }
        // Only verified audio is queued; a failed recording is never processed.
        session.onFinished = { dir, ok in if ok { queue.enqueue(dir) } }
        queue.onChange = { [weak self] in
            let (current, stage) = (queue.current, queue.stage)
            Task { @MainActor in self?.apply(.processing(current, stage: stage)) }
        }
        queue.onFinished = { [weak self] dir, ok in
            Task { @MainActor in
                guard let self = self else { return }
                self.library.reload()
                guard ok else { return }
                self.apply(.minutesReady(dir))
                self.play("Glass")
                // The window comes forward on the minutes, unless a recording is running.
                if LibraryPresentation.shouldOpenMinutes(openMinutes: self.preferences.openMinutes, phase: self.session.phase) {
                    self.apply(.minutesOpened(dir))
                    self.showLibrary(on: dir)
                }
            }
        }
        handler.onStarted = { [weak self] _ in Task { @MainActor in self?.play("Tink") } }
        handler.onStopped = { [weak self] _ in Task { @MainActor in self?.play("Pop") } }
        // `show` from the socket (a second launch, or the command): the window.
        handler.onShow = { [weak self] in Task { @MainActor in self?.showLibrary() } }

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
        var input = status
        input.floating = preferences.floating
        return StatusPresentation(input)
    }

    /// Only a change publishes, so the views are not told every second that nothing happened.
    private func apply(_ event: StatusEvent) {
        var next = status
        next.apply(event)
        if next != status {
            status = next
            library.update(next)
        }
    }

    /// Brings the meetingbox window forward, on that meeting's minutes when one is given.
    func showLibrary(on dir: URL? = nil) {
        if let dir = dir { library.show(dir) }
        onOpenLibrary?()
    }

    /// A menu entry or floating button was chosen. Recording commands go through the same
    /// `ControlHandler` as the socket, so a click and `meetingbox start` get the same answers;
    /// nothing here waits (a modal alert would block the queue the session ticks on).
    func perform(_ action: MenuAction) {
        apply(.acted)
        switch action {
        case .info, .separator, .preferences:
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
            showLibrary()
        case .openMinutes(let dir):
            apply(.minutesOpened(dir))
            showLibrary(on: dir)
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

    /// A failed start, and a pause or resume that could not reach the recorder, are shown (the icon
    /// and the menu's first line). The races, such as a pause that lost to the recorder ending, only go
    /// to the log.
    private func answered(_ request: ControlRequest, _ reply: String) {
        guard reply.hasPrefix("error ") else { return }
        if let failure = Failure.from(request, reply: reply) {
            apply(.failed(failure))
        } else {
            NSLog("meetingbox: %@ was refused: %@", String(describing: request), String(reply.dropFirst("error ".count)))
        }
    }

    /// Once a second while recording or paused, on the main queue (the session's tick queue), so
    /// reading the session here is safe. One timer at most, cancelled when `clockRuns` is false.
    private func syncClock() {
        guard status.clockRuns else {
            clock?.cancel()
            clock = nil
            return
        }
        apply(.tick(seconds: session.recordedSeconds(at: Date()), health: session.health))
        guard clock == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in Task { @MainActor in self?.syncClock() } }
        timer.resume()
        clock = timer
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
