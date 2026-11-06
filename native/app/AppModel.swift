import AppKit
import Combine

/// The one place UI state changes. Owns the core for the app's life: one `MeetingStore` shared by
/// the session and the processing queue, the `Session`, the `ProcessingQueue`, the `ControlHandler`
/// every recording command goes through, and the control socket. Core callbacks reach UI state by
/// hopping here with `Task { @MainActor in ... }`; the core itself runs on the main queue, its tick
/// queue. The menu bar item, the floating button and the meetingbox window are views over this; every
/// recording action they offer comes back through `perform`, and from there through `ControlHandler`,
/// the one path the socket uses too. The window's own state is `library`. The Preferences window
/// changes settings only through the `set...` methods here, which apply each change at once.
@MainActor
final class AppModel: ObservableObject {
    /// What the views show, changed only by `StatusEvent`s (StatusReducer.swift, where the rules are
    /// tested): the phase, the recorded time and health, the job being processed and its stage, the
    /// line about a meeting (its minutes are ready, or it went wrong), and what the user asked for last
    /// that did not work.
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
    /// Bring the Preferences window forward. Until it is set, the menu does not offer Preferences….
    var onOpenPreferences: (@MainActor () -> Void)?
    /// The Dock icon or the menu bar item setting changed: AppDelegate shows `visibility`.
    var onVisibilityChange: (@MainActor () -> Void)?
    /// The microphones the recorder lists, nil until listed or when listing failed.
    @Published private(set) var microphones: [String]?
    /// Why the folder last chosen was not taken, until another is taken or the window opens again.
    @Published private(set) var folderProblem: String?
    private var microphonesAsked = 0
    private var folderMovesAsked = 0
    /// Told once the session is idle again (Stop and quit).
    private var idleWaiters: [@MainActor () -> Void] = []

    /// Plays a system sound by name, through `play`.
    private let playSound: (String) -> Void

    /// The recorder, the processing runner, the free space and the sound player are the real ones
    /// unless a test gives its own.
    init(stateDir: URL, preferences: Preferences, recorder: RecorderControl = ChildRecorder(), runner: PipelineRunner? = nil,
         freeBytes: @escaping (URL) -> Int64? = { AppModel.freeBytes(near: $0) },
         playSound: @escaping (String) -> Void = { NSSound(named: NSSound.Name($0))?.play() }) {
        self.playSound = playSound
        self.stateDir = stateDir
        self.preferences = preferences
        // The other folders recordings were started in are read from the setting each time they are looked in.
        let store = MeetingStore(root: preferences.meetingsFolder, otherRoots: { [preferences] in
            preferences.otherRoots.map { URL(fileURLWithPath: $0, isDirectory: true) }
        })
        let session = Session(stateDir: stateDir, recorder: recorder, store: store, now: Date.init,
                              freeBytes: freeBytes)
        let script = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/meetingbox")
        let queue = ProcessingQueue(store: store, runner: runner ?? ScriptRunner.fromBundle() ?? ScriptRunner(script: script))
        self.store = store
        self.session = session
        self.queue = queue
        self.handler = ControlHandler(session: session, preferences: preferences)
        self.library = LibraryModel(store: store, session: session, queue: queue)
        // The window's Pause, Resume and Stop take the path the menu's do.
        library.control = { [weak self] action in self?.perform(action) }
        // Settings from before (or written by hand) with neither the Dock icon nor the menu bar item.
        normaliseVisibility()
    }

    /// In this order: take up a recording left by a crash (Task 4), pick up the processing queue
    /// (Task 5), then answer on the socket. The caller already holds `app.lock`.
    func launch() {
        let queue = self.queue
        session.onChange = { [weak self] phase in
            Task { @MainActor in
                self?.apply(.phase(phase))
                self?.syncClock()
                self?.tellIdleWaiters()
            }
        }
        // Only verified audio is queued; a failed recording is never processed, and is said.
        session.onFinished = { [weak self] dir, ok in
            if ok {
                queue.enqueue(dir)
            } else {
                Task { @MainActor in self?.wentWrong(.unfinished(dir, line: StatusPresentation.recordingNotFinished)) }
            }
        }
        // A recording that ended without being asked to (its recorder went, or the disk stop).
        session.onEnded = { [weak self] dir, reason in
            Task { @MainActor in self?.wentWrong(.recordingStopped(dir, reason: reason)) }
        }
        queue.onChange = { [weak self] in
            let (current, stage) = (queue.current, queue.stage)
            Task { @MainActor in self?.apply(.processing(current, stage: stage)) }
        }
        queue.onFinished = { [weak self] dir, ok in
            Task { @MainActor in
                guard let self = self else { return }
                self.library.reload()
                guard ok else {
                    self.wentWrong(.unfinished(dir, line: StatusPresentation.minutesNotWritten(AppModel.failureReason(dir))))
                    return
                }
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
        // A start or toggle refused while the last recording is saved, from the menus or the command.
        handler.onRefused = { [weak self] in Task { @MainActor in self?.play("Basso") } }
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

    /// At quit: the socket goes, and nothing else. A recorder keeps running (it is its own process)
    /// and the next launch adopts it; the kernel releases `app.lock` when the process ends. Never
    /// stop or signal the recorder here: Keep recording and quit, and log out, end up here too.
    func shutDown() {
        server?.stop()
        server = nil
    }

    /// What the menu bar item and the floating button show now.
    var presentation: StatusPresentation {
        var input = status
        input.floating = preferences.floating
        input.preferencesAvailable = onOpenPreferences != nil
        return StatusPresentation(input)
    }

    /// Something went wrong with a meeting that nobody asked for: its line in the menu bar, with the
    /// amber icon, and the failure sound.
    private func wentWrong(_ event: StatusEvent) {
        apply(event)
        play("Basso")
    }

    /// Why a job failed, in one line, as its meeting.json has it.
    private static func failureReason(_ dir: URL) -> String {
        let error = MeetingStore.record(in: dir)?.error ?? ""
        return error.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
            ?? "processing failed"
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
        case .info, .separator:
            break
        case .preferences:
            onOpenPreferences?()
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
    /// and the menu's first line). The races, such as a pause that lost to the recorder ending, or a
    /// start that lost to another start of the recording now running, only go to the log.
    private func answered(_ request: ControlRequest, _ reply: String) {
        guard reply.hasPrefix("error ") else { return }
        if let failure = Failure.from(request, reply: reply, phase: session.phase) {
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

    // MARK: settings (the Preferences window)

    /// What the Dock icon and the menu bar item settings come to (PreferencesPresentation.swift).
    var visibility: Visibility {
        PreferencesPresentation.visibility(showInDock: preferences.showInDock, showMenuBar: preferences.showMenuBar)
    }

    /// With neither on, the menu bar item is shown, and its setting written back so the checkbox says so.
    private func normaliseVisibility() {
        if visibility.writeBackMenuBar { preferences.showMenuBar = true }
    }

    /// Each setter tells the views first (`objectWillChange`), then writes the setting: the menu bar
    /// item and the floating button redraw from it, and the Preferences window shows it.
    func setShowMenuBar(_ on: Bool) {
        objectWillChange.send()
        preferences.showMenuBar = on
        normaliseVisibility()
        onVisibilityChange?()
    }

    func setShowInDock(_ on: Bool) {
        objectWillChange.send()
        preferences.showInDock = on
        normaliseVisibility()
        onVisibilityChange?()
    }

    func setFloating(_ mode: FloatingMode) {
        objectWillChange.send()
        preferences.floating = mode
    }

    /// Read when a job finishes.
    func setOpenMinutes(_ on: Bool) {
        objectWillChange.send()
        preferences.openMinutes = on
    }

    /// Read when a sound would play.
    func setSounds(_ on: Bool) {
        objectWillChange.send()
        preferences.sounds = on
    }

    /// Nil for the system default. `ControlHandler` reads it at each start, so it applies from the next recording.
    func setMicrophone(_ name: String?) {
        objectWillChange.send()
        preferences.microphone = name
    }

    /// The microphone menu: the listed devices and the saved setting.
    var microphoneChoice: MicrophoneChoice {
        PreferencesPresentation.microphoneChoice(devices: microphones, saved: preferences.microphone)
    }

    /// Lists the microphones with the app's own recorder helper (`--record -l`), off the main queue.
    /// A listing overtaken by a newer one is dropped; one that fails leaves nil.
    func refreshMicrophones(helper: URL = ChildRecorder.helperExecutable(in: Bundle.main.bundleURL)) {
        microphonesAsked += 1
        let asked = microphonesAsked
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = PreferencesPresentation.listMicrophones(helper: helper)
            Task { @MainActor in
                guard let self = self, asked == self.microphonesAsked else { return }
                self.microphones = found
            }
        }
    }

    /// The window opens with no complaint left from last time.
    func clearFolderProblem() {
        if folderProblem != nil { folderProblem = nil }
    }

    /// The meetings folder. Taken only while nothing is recording, paused or finalising, only an
    /// existing folder this user can write to, and only once nothing in the current folder is in
    /// progress (`PreferencesPresentation.stillFinishing`) and the queue has no work: a meeting left
    /// behind would be in a folder neither the queue nor recovery looks in. Otherwise `folderProblem`
    /// says why and nothing changes.
    ///
    /// The current folder is read off the main queue; the move is then made on the main queue, after
    /// the session and the queue are checked again. Only the latest choice is made: every choice,
    /// refused at once or not, overtakes an earlier one still being checked. The next recording goes
    /// there (`ControlHandler` reads the setting at each start), and the one store the session, the
    /// queue and the library share moves to it.
    func setMeetingsFolder(_ url: URL) {
        folderMovesAsked += 1
        let asked = folderMovesAsked
        guard PreferencesPresentation.canChooseFolder(session.phase) else {
            folderProblem = PreferencesPresentation.folderBusy
            return
        }
        if let problem = PreferencesPresentation.folderProblem(url) {
            folderProblem = problem
            return
        }
        let store = self.store
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let finishing = PreferencesPresentation.stillFinishing(store.scan())
            Task { @MainActor in self?.moveMeetingsFolder(to: url, asked: asked, finishing: finishing) }
        }
    }

    private func moveMeetingsFolder(to url: URL, asked: Int, finishing: Bool) {
        guard asked == folderMovesAsked else { return } // a later choice overtook this one
        guard PreferencesPresentation.canChooseFolder(session.phase) else {
            folderProblem = PreferencesPresentation.folderBusy
            return
        }
        guard !finishing, !queue.hasWork else {
            folderProblem = PreferencesPresentation.folderStillFinishing
            return
        }
        objectWillChange.send()
        folderProblem = nil
        preferences.meetingsFolder = URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
        store.root = preferences.meetingsFolder
        library.reload()
        // What waits in the new folder is taken up now, as at launch. Both are safe to repeat: resume
        // skips what the queue already holds, and adopt does nothing unless the session is idle (it is:
        // checked above, on this queue) and skips recoveries already running.
        queue.resume()
        session.adopt()
    }

    // MARK: recording entries (the Dock menu, the main menu's Recording menu, New meeting)

    /// The menu bar item's recording entries that apply now (`PreferencesPresentation.recordingEntries`).
    var recordingEntries: [MenuEntry] { PreferencesPresentation.recordingEntries(presentation.menu) }

    /// New meeting in the window is enabled exactly when the menus offer Start recording: while idle.
    var canStartNewMeeting: Bool { recordingEntries.contains { $0.action == .start && $0.enabled } }

    /// New meeting's words: Saving the last recording… while it is, else New meeting.
    var newMeetingTitle: String { PreferencesPresentation.newMeetingTitle(recordingEntries) }

    /// New meeting: the menus' Start recording, through `perform`. Nothing while a recording is under way.
    func newMeeting() {
        guard canStartNewMeeting else { return }
        perform(.start)
    }

    // MARK: quitting

    /// Stop and quit: Stop goes through `perform`, the path every recording command takes, and
    /// `done` is told once the session is idle again (finalised and queued, or failed with its files
    /// kept). It waits on the session's phase changes; nothing polls or sleeps on the main queue.
    func stopForQuit(then done: @escaping @MainActor () -> Void) {
        idleWaiters.append(done)
        if session.phase == .idle {
            Task { @MainActor in self.tellIdleWaiters() } // nothing to stop: told on the next turn
            return
        }
        perform(.stop)
    }

    /// On each phase change: the session itself is asked, so a change delivered late never answers
    /// for a later recording.
    private func tellIdleWaiters() {
        guard session.phase == .idle, !idleWaiters.isEmpty else { return }
        let waiters = idleWaiters
        idleWaiters = []
        waiters.forEach { $0() }
    }

    /// The start, stop, done and failure sounds, unless they are turned off.
    func play(_ name: String) {
        guard preferences.sounds else { return }
        playSound(name)
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
