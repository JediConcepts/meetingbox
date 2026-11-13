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

    /// What `meetingbox engines` last said, and the voice line Preferences shows from it.
    @Published private(set) var engineStatus = EngineStatus()
    @Published private(set) var voiceStatus = ""
    /// Why "Forget my voice" last failed, until it is chosen again.
    @Published private(set) var voiceProblem: String?
    /// The voice sample, as its sheet shows it.
    @Published private(set) var sample: SampleState = .idle
    /// The engine's commands other than jobs: `engines`, `voice add`, `voice forget`.
    let engine: EngineCommands
    private let sampler: SampleRecorder?
    private var enginesAsked = 0
    /// The sample's folder while it records or is built, which sample a late answer belongs to, and
    /// where it stands: waiting for the sampler to capture, capturing, stopping (waiting for the
    /// sampler to say the sample is final, before it is built), or being built.
    private var sampleFolder: URL?
    private var samplesAsked = 0
    private var sampleClock: DispatchSourceTimer?
    private enum SampleStep { case none, waiting, capturing, stopping, building }
    private var sampleStep = SampleStep.none

    /// Plays a system sound by name, through `play`.
    private let playSound: (String) -> Void

    /// The recorder, the processing runner, the free space and the sound player are the real ones
    /// unless a test gives its own. Without an `engine` no engine command runs (each is answered that
    /// meetingbox is not installed), and without a `sampler` there is no voice sample: only AppDelegate
    /// passes the real ones.
    init(stateDir: URL, preferences: Preferences, recorder: RecorderControl = ChildRecorder(), runner: PipelineRunner? = nil,
         freeBytes: @escaping (URL) -> Int64? = { AppModel.freeBytes(near: $0) },
         playSound: @escaping (String) -> Void = { NSSound(named: NSSound.Name($0))?.play() },
         engine: EngineCommands = NoEngineCommands(), sampler: SampleRecorder? = nil) {
        self.playSound = playSound
        self.engine = engine
        self.sampler = sampler
        self.stateDir = stateDir
        self.preferences = preferences
        // The other folders recordings were started in are read from the setting each time they are looked in.
        let store = MeetingStore(root: preferences.meetingsFolder, otherRoots: { [preferences] in
            preferences.otherRoots.map { URL(fileURLWithPath: $0, isDirectory: true) }
        })
        let session = Session(stateDir: stateDir, recorder: recorder, store: store, now: Date.init,
                              freeBytes: freeBytes)
        let script = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/meetingbox")
        // Each job reads the transcriber and tidying chosen here as it launches; the window's redo sheets
        // start at them, and check their writer against them.
        let runSettings = { [preferences] in preferences.runSettings }
        let queue = ProcessingQueue(store: store, runner: runner ?? ScriptRunner.fromBundle() ?? ScriptRunner(script: script),
                                    settings: runSettings)
        self.store = store
        self.session = session
        self.queue = queue
        self.handler = ControlHandler(session: session, preferences: preferences)
        self.library = LibraryModel(store: store, session: session, queue: queue, settings: runSettings)
        // The window's Pause, Resume and Stop take the path the menu's do.
        library.control = { [weak self] action in self?.perform(action) }
        library.onSelectionChange = { [weak self] in self?.selectionChanged() }
        // A meeting always wins: every start, by any route, first cancels a voice sample being recorded.
        // The handler's queue is the session's tick queue, the main queue.
        handler.willStart = { [weak self] in MainActor.assumeIsolated { self?.cancelSampleForMeeting() } }
        // Settings from before (or written by hand) with neither the Dock icon nor the menu bar item.
        normaliseVisibility()
    }

    /// In this order: remove any voice sample folder a crash left, take up a recording left by a crash
    /// (Task 4), pick up the processing queue (Task 5), then answer on the socket. The caller already
    /// holds `app.lock`.
    func launch() {
        SampleFolder.removeLeftovers(in: stateDir)
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
        queue.onFinished = { [weak self] dir, ok, kind, reason in
            Task { @MainActor in
                guard let self = self else { return }
                self.library.reload()
                guard ok else {
                    // A redo's reason is on its meeting in the window; the menu bar only says it did not finish. A
                    // job that ended where its meeting could not be found gives its own reason: the record at
                    // its old path, if any, is another meeting's.
                    let line = kind == .process ? StatusPresentation.minutesNotWritten(reason ?? AppModel.failureReason(dir))
                        : StatusPresentation.redoNotFinished
                    self.wentWrong(.unfinished(dir, line: line))
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
        // Every answer the socket gave (the hotkey or the command): a failed start there is shown as
        // one from the menus is, with the failure sound.
        handler.onAnswered = { [weak self] request, reply in Task { @MainActor in self?.answered(request, reply, overSocket: true) } }
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

    /// At quit: the socket goes, and a voice sample being recorded is stopped and its folder deleted at
    /// once, since the app may be gone before the sampler says it has stopped (a folder left anyway is
    /// removed at the next launch). A recorder keeps running (it is its own process) and the next launch
    /// adopts it; the kernel releases `app.lock` when the process ends. Never stop or signal the recorder
    /// here: Keep recording and quit, and log out, end up here too.
    func shutDown() {
        server?.stop()
        server = nil
        let folder = sampleFolder
        switch sampleStep {
        case .waiting, .capturing:
            endSample(.idle)
        case .stopping:
            dropStopping(.idle)
        case .none, .building:
            return
        }
        if let folder = folder { SampleFolder.remove(folder) }
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

    /// The window chose another meeting. Nothing follows the selection yet; the player will stop here.
    private func selectionChanged() {}

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
                Task { @MainActor in self?.answered(request, reply, overSocket: false) }
            }
        }
    }

    /// A failed start, and a pause or resume that could not reach the recorder, are shown (the icon
    /// and the menu's first line), from the menus and the socket alike; a failed start over the socket
    /// plays the failure sound too (`Failure.shown`). The races, such as a pause that lost to the
    /// recorder ending, or a start that lost to another start of the recording now running, only go
    /// to the log. A command over the socket that acts on the recording first clears an old failure,
    /// whatever its reply, as a menu choice does in `perform`; status and show do not.
    private func answered(_ request: ControlRequest, _ reply: String, overSocket: Bool) {
        if overSocket {
            switch request {
            case .start, .stop, .pause, .resume: apply(.acted) // a toggle comes as the start or stop it became
            case .status, .toggle, .show: break
            }
        }
        guard reply.hasPrefix("error ") else { return }
        if let shown = Failure.shown(request, reply: reply, phase: session.phase, overSocket: overSocket) {
            apply(.failed(shown.failure))
            if shown.sound { play("Basso") }
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

    /// The Preferences window is opening: no complaint left from last time, and the microphones and
    /// the engine's status read afresh.
    func preferencesOpened() {
        clearFolderProblem()
        refreshMicrophones()
        refreshEngines()
    }

    // MARK: transcripts: the transcriber, tidying and the user's voice

    /// Read when the next job launches.
    func setTranscriber(_ transcriber: Transcriber) {
        objectWillChange.send()
        preferences.transcriber = transcriber
    }

    /// Read when the next job launches.
    func setTidyLines(_ on: Bool) {
        objectWillChange.send()
        preferences.tidyLines = on
    }

    /// "Parakeet is not set up, …" while Parakeet is chosen and the engine says it cannot be used.
    var parakeetNotSetUp: String? {
        PreferencesPresentation.parakeetNotSetUp(transcriber: preferences.transcriber, engines: engineStatus)
    }

    /// Runs `engines` through the engine, with a 10 s limit, when Preferences opens and after any change
    /// to the voice. An answer overtaken by a newer one is dropped.
    func refreshEngines() {
        enginesAsked += 1
        let asked = enginesAsked
        engine.run(["engines"], stdin: nil, timeout: 10) { [weak self] _, output in
            MainActor.assumeIsolated {
                guard let self = self, asked == self.enginesAsked else { return }
                self.engineStatus = PreferencesPresentation.parseEngines(output)
                self.voiceStatus = PreferencesPresentation.voiceLine(self.engineStatus.voice)
            }
        }
    }

    /// There is a voice print to forget.
    var canForgetVoice: Bool {
        if case .print = engineStatus.voice { return true }
        return false
    }

    /// "Forget my voice": `voice forget` through the engine, then the status afresh. A refusal (another
    /// writer held the print for too long) is shown in the engine's words.
    func forgetVoice() {
        voiceProblem = nil
        engine.run(["voice", "forget"], stdin: nil, timeout: 60) { [weak self] status, output in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                if status != 0 { self.voiceProblem = PreferencesPresentation.engineProblem(status: status, output: output) }
                self.refreshEngines()
            }
        }
    }

    /// "Record a voice sample…" is offered only while nothing records and no sample is under way.
    var canRecordSample: Bool { sampler != nil && session.phase == .idle && sample == .idle }

    /// Starts a voice sample: a private folder `<stateDir>/sample.XXXXXX`, and the sampler on the
    /// Preferences microphone. Refused unless the session is idle, no sample is under way and a sampler
    /// was given. When the engine has said Parakeet cannot be used, it fails at once with that, rather
    /// than after 90 seconds of reading. The countdown starts once the sampler is capturing.
    func recordSample() {
        guard canRecordSample, let sampler = sampler else { return }
        if case .unavailable = engineStatus.parakeet {
            sample = .failed(PreferencesPresentation.sampleNeedsParakeet)
            return
        }
        guard let folder = SampleFolder.make(in: stateDir) else {
            sample = .failed(PreferencesPresentation.sampleNoFolder)
            return
        }
        samplesAsked += 1
        let asked = samplesAsked
        sampleFolder = folder
        sampleStep = .waiting
        sample = .recording(secondsLeft: SampleState.seconds)
        sampler.start(folder: folder, microphone: preferences.microphone) { [weak self] reason in
            MainActor.assumeIsolated { self?.sampleStarted(asked, folder: folder, reason: reason) }
        }
    }

    /// The sampler's word on a start: capturing (nil), or why it cannot, which can also come later, once,
    /// when capturing fails. A failure before Stop ends the sample with that reason, and nothing is
    /// built; one after Stop leaves what was recorded to be built. A word about a sample that has already
    /// ended (Stop before it was capturing, a meeting, a quit) that it is capturing stops the sampler
    /// again, unless a newer sample is under way, and that sample's folder goes once it has.
    private func sampleStarted(_ asked: Int, folder: URL, reason: String?) {
        guard asked == samplesAsked else {
            if reason == nil, sampleStep == .none, let sampler = sampler {
                sampler.stop { SampleFolder.remove(folder) }
            } else {
                SampleFolder.remove(folder)
            }
            return
        }
        switch (sampleStep, reason) {
        case (.waiting, nil):
            sampleStep = .capturing
            startSampleClock()
        case (.waiting, let reason?), (.capturing, let reason?):
            endSample(.failed(reason))
        default:
            break
        }
    }

    /// One second of the countdown, only while the sampler is capturing: the app's 1 s timer calls it
    /// (tests call it directly). At 0 the sample is finished.
    func tickSample() {
        guard sampleStep == .capturing, case .recording(let left) = sample else { return }
        if left > 1 {
            sample = .recording(secondsLeft: left - 1)
        } else {
            sample = .recording(secondsLeft: 0)
            finishSample()
        }
    }

    /// Stop: a sample being captured ends early and is built from what was recorded. Before the sampler
    /// is capturing (a first-time permission prompt still up) there is nothing to build: back to idle.
    func stopSample() {
        switch sampleStep {
        case .waiting: endSample(.idle)
        case .capturing: finishSample()
        case .none, .stopping, .building: break
        }
    }

    /// Done (or the sheet closing): back to idle once the sample has an outcome; a sample still being
    /// recorded is cancelled and deleted. One stopping to be built, or being built, is left to finish.
    func closeSample() {
        switch sample {
        case .done, .failed: sample = .idle
        case .recording where sampleStep == .waiting || sampleStep == .capturing: endSample(.idle)
        case .idle, .recording, .building: break
        }
    }

    /// The sampler is asked to stop, and nothing waits for it. Once it says the sample is final, the
    /// engine makes the print: `voice add <folder>/sample.caf`, with a 300 s limit. Once that answers,
    /// the folder goes, the outcome is put into words and the status is read afresh.
    private func finishSample() {
        guard let folder = sampleFolder, let sampler = sampler else { return }
        stopSampleClock()
        sampleStep = .stopping
        let asked = samplesAsked
        sampler.stop { [weak self] in
            MainActor.assumeIsolated {
                guard let self = self, asked == self.samplesAsked, self.sampleStep == .stopping else {
                    SampleFolder.remove(folder)
                    return
                }
                self.buildSample(folder)
            }
        }
    }

    private func buildSample(_ folder: URL) {
        sampleStep = .building
        sample = .building
        samplesAsked += 1
        let asked = samplesAsked
        let audio = folder.appendingPathComponent(SampleFolder.audioName)
        engine.run(["voice", "add", audio.path], stdin: nil, timeout: 300) { [weak self] status, output in
            MainActor.assumeIsolated {
                SampleFolder.remove(folder)
                guard let self = self, asked == self.samplesAsked, self.sampleStep == .building else { return }
                self.sampleFolder = nil
                self.sampleStep = .none
                self.sample = PreferencesPresentation.sampleOutcome(status: status, output: output)
                self.refreshEngines()
            }
        }
    }

    /// A recording is about to start (`ControlHandler.willStart`, on the main queue just before the
    /// recorder is launched): a sample not yet being built fails, saying why. One being recorded has its
    /// sampler asked to stop; one already stopping keeps the stop it has, and is not built once that is
    /// done. Nothing waits for the sampler, so the meeting starts at once; the folder goes once the
    /// sampler is done. One being built has left the microphone and is left to finish.
    private func cancelSampleForMeeting() {
        switch sampleStep {
        case .waiting, .capturing: endSample(.failed(PreferencesPresentation.sampleStoppedForMeeting))
        case .stopping: dropStopping(.failed(PreferencesPresentation.sampleStoppedForMeeting))
        case .none, .building: break
        }
    }

    /// A sample whose sampler is already stopping is let go: that stop's `done` then finds it gone, so
    /// it removes the folder and builds nothing.
    private func dropStopping(_ outcome: SampleState) {
        sampleFolder = nil
        sampleStep = .none
        samplesAsked += 1
        sample = outcome
    }

    /// Ends a sample being recorded without building it: the clock stops, the outcome is shown, any
    /// later word about it is answered as a late one, and the sampler is asked to stop. Its folder goes
    /// once the sampler says it has.
    private func endSample(_ outcome: SampleState) {
        stopSampleClock()
        let folder = sampleFolder
        sampleFolder = nil
        sampleStep = .none
        samplesAsked += 1
        sample = outcome
        sampler?.stop { if let folder = folder { SampleFolder.remove(folder) } }
    }

    private func startSampleClock() {
        guard sampleClock == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.tickSample() } }
        timer.resume()
        sampleClock = timer
    }

    private func stopSampleClock() {
        sampleClock?.cancel()
        sampleClock = nil
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
