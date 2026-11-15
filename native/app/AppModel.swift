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
    /// The top bar's player of the selected meeting's audio (Player.swift). Only the bar's player view
    /// observes it; this model does not pass its changes on.
    let player: Player

    /// The recorder, the processing runner, the free space and the sound player are the real ones
    /// unless a test gives its own. Without an `engine` no engine command runs (each is answered that
    /// meetingbox is not installed), without a `sampler` there is no voice sample, and without a `player`
    /// nothing plays (every file is refused): only AppDelegate passes the real ones.
    init(stateDir: URL, preferences: Preferences, recorder: RecorderControl = ChildRecorder(), runner: PipelineRunner? = nil,
         freeBytes: @escaping (URL) -> Int64? = { AppModel.freeBytes(near: $0) },
         playSound: @escaping (String) -> Void = { NSSound(named: NSSound.Name($0))?.play() },
         engine: EngineCommands = NoEngineCommands(), sampler: SampleRecorder? = nil,
         player: Player = Player(audio: NoAudio(), tickQueue: nil)) {
        self.playSound = playSound
        self.player = player
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
        // An outside writer chosen in a redo sheet whose source is not agreed: asked about from the window.
        library.requestConsent = { [weak self] writer in self?.ask(writer, origin: .redo) }
        // A meeting always wins: every start, by any route, first stops playback and then cancels a voice
        // sample being recorded. The handler's queue is the session's tick queue, the main queue.
        handler.willStart = { [weak self] in MainActor.assumeIsolated { self?.makeWayForRecording() } }
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
                // A recording or a pause by any route, one adopted after a relaunch included (it never goes
                // through willStart): nothing plays into it and no sample goes on. Nothing to do after a start.
                switch phase {
                case .recording, .paused: self?.makeWayForRecording()
                case .idle, .finalising: break
                }
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

        adopt()
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

    /// The window chose another meeting: the player, which plays the selected meeting, stops.
    private func selectionChanged() {
        player.stop()
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

    /// The Preferences window is opening: no complaint left from last time, and the microphones, the
    /// engine's status and whether each source has a key (`key status`, which reads the keychain only)
    /// read afresh. No source is contacted: its models are listed only on Check, on opening the picker,
    /// or on saving it.
    func preferencesOpened() {
        clearFolderProblem()
        writerNotice = nil
        minutesProblem = nil
        refreshMicrophones()
        refreshEngines()
        preferences.sources.forEach { refreshKey($0.address) }
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

    /// "Record a voice sample…" is offered only while nothing records, no recorder left running is waiting
    /// to be confirmed, and no sample is under way.
    var canRecordSample: Bool { sampler != nil && session.phase == .idle && !session.unconfirmed && sample == .idle }

    /// Starts a voice sample: a private folder `<stateDir>/sample.XXXXXX`, and the sampler on the
    /// Preferences microphone. Refused unless the session is idle, no sample is under way and a sampler
    /// was given. When the engine has said Parakeet cannot be used, it fails at once with that, rather
    /// than after 90 seconds of reading. Playback stops before the sampler starts, so the microphone does
    /// not take in a meeting being played. The countdown starts once the sampler is capturing.
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
        player.stop()
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

    /// A recording is about to start, by any route (`ControlHandler.willStart`, on the main queue just
    /// before the recorder is launched), or one has begun without a start (adopted on the tick): playback
    /// stops first, since the recorder takes in the Mac's own sound, and then a voice sample under way is
    /// cancelled. Doing it again changes nothing.
    private func makeWayForRecording() {
        player.stop()
        cancelSampleForMeeting()
    }

    /// A meeting is starting: a sample not yet being built fails, saying why. One being recorded has its
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
        adopt()
    }

    /// Takes up a recording left running (`Session.adopt`), at launch and after the meetings folder changes.
    /// One found running changes the phase, and the backstop in `session.onChange` makes way for it. One
    /// that ps cannot confirm changes no phase but may be recording, so what plays stops and a sample under
    /// way is cancelled now, the same way. Nothing is played or sampled until it is confirmed or gone.
    func adopt() {
        session.adopt()
        if session.unconfirmed { makeWayForRecording() }
    }

    // MARK: minutes: the outside sources, their keys and models, the writer, and agreement

    // Every command here goes through `engine`, off the main queue, and its answer comes back on it. A
    // source is contacted (`engines --kind K --address A`) only on Check, on opening the picker, or on
    // saving it; `key` commands touch only the keychain. A key travels on stdin, never in the arguments.

    /// The source being added (index nil) or changed in its sheet.
    @Published private(set) var sourceDraft: SourceDraft?
    /// The key being typed in its sheet, for one source.
    @Published private(set) var keyDraft: KeyDraft?
    /// Each source's models, or why they could not be listed, by address.
    @Published private(set) var listings: [String: SourceListing] = [:]
    /// Whether each source has a key stored, by address, from `key status` (and the answers of Set… and
    /// Remove); absent while not known, as when the keychain could not be read, which is never "none".
    @Published private(set) var keys: [String: Bool] = [:]
    /// Why `key status` could not say set or none, by address.
    @Published private var keyStatusProblems: [String: String] = [:]
    /// Why Set… or Remove did not work, by address, until it is tried again.
    @Published private var keyActionProblems: [String: String] = [:]
    /// The agreement being asked for: the Preferences window shows it for `.preferences`, the meetingbox
    /// window, over its redo sheet, for `.redo`.
    @Published private(set) var consent: ConsentRequest?
    /// Why the writer just chosen in Preferences was not taken, until the next choice.
    @Published private(set) var writerNotice: String?
    /// A key that could not be removed with its source, until Preferences opens again or a source changes.
    @Published private(set) var minutesProblem: String?
    /// What is typed in each source's Model name field, by address.
    @Published private(set) var modelNames: [String: String] = [:]
    private var listingsAsked = 0
    private var latestListing: [String: Int] = [:]
    private var keysAsked = 0
    private var latestKey: [String: Int] = [:]

    /// A source's key line problem: what Set… or Remove said, else what `key status` said.
    var keyProblems: [String: String] { keyStatusProblems.merging(keyActionProblems) { _, action in action } }

    private func source(at index: Int) -> Source? {
        let sources = preferences.sources
        return sources.indices.contains(index) ? sources[index] : nil
    }

    private func hasSource(_ address: String) -> Bool { preferences.sources.contains { $0.address == address } }

    private func sourceOf(_ writer: OutsideWriter) -> Int? {
        preferences.sources.firstIndex { $0.kind == writer.kind && $0.address == writer.address }
    }

    /// The address as it is kept: without spaces around it, and the Claude API's own when none is given.
    private static func normalised(_ source: Source) -> Source {
        let address = source.address.trimmingCharacters(in: .whitespacesAndNewlines)
        return Source(kind: source.kind, address: address.isEmpty ? PreferencesPresentation.defaultAddress(source.kind) : address,
                      agreed: source.agreed)
    }

    /// Why this address cannot be a source beside `others`: the rule refuses it, or one of them has it.
    private static func sourceProblem(_ address: String, among others: [Source]) -> String? {
        if let problem = PreferencesPresentation.addressProblem(address) { return problem }
        return others.contains { PreferencesPresentation.sameAddress($0.address, address) } ? PreferencesPresentation.addressTaken : nil
    }

    /// Adds a source, never agreed. Refused, with why and with nothing run, when the rule refuses its
    /// address or another source has it. Once saved, its models are listed and its key is read.
    @discardableResult
    func addSource(_ source: Source) -> String? {
        let new = Source(kind: source.kind, address: AppModel.normalised(source).address, agreed: false)
        var sources = preferences.sources
        if let problem = AppModel.sourceProblem(new.address, among: sources) { return problem }
        sources.append(new)
        objectWillChange.send()
        preferences.sources = sources
        minutesProblem = nil
        refreshKey(new.address)
        list(new)
        return nil
    }

    /// Changes the source at `index`. A new kind or address withdraws its agreement (it is never given
    /// here: only `agree()` gives it), and its listing goes; a new address also has the key stored for the
    /// old one removed (`key remove --address <old>`). Refused as `addSource` is. Once saved, its models are
    /// listed and its key is read.
    @discardableResult
    func updateSource(at index: Int, _ source: Source) -> String? {
        var sources = preferences.sources
        guard sources.indices.contains(index) else { return nil }
        let old = sources[index]
        let address = AppModel.normalised(source).address
        var others = sources
        others.remove(at: index)
        if let problem = AppModel.sourceProblem(address, among: others) { return problem }
        let same = source.kind == old.kind && address == old.address
        sources[index] = Source(kind: source.kind, address: address, agreed: same && old.agreed)
        objectWillChange.send()
        preferences.sources = sources
        minutesProblem = nil
        if !same { forget(old) }
        if address != old.address { removeOldKey(old.address) }
        refreshKey(address)
        list(sources[index])
        return nil
    }

    /// Removes the source at `index`, which withdraws its agreement, and removes its key.
    func removeSource(at index: Int) {
        var sources = preferences.sources
        guard sources.indices.contains(index) else { return }
        let gone = sources.remove(at: index)
        objectWillChange.send()
        preferences.sources = sources
        minutesProblem = nil
        forget(gone)
        modelNames[gone.address] = nil
        removeOldKey(gone.address)
    }

    /// A source as it was is gone: its listing (and any still being made), and any agreement asked for it.
    private func forget(_ source: Source) {
        listings[source.address] = nil
        latestListing[source.address] = nil
        if let asked = consent?.writer, asked.kind == source.kind, asked.address == source.address { consent = nil }
    }

    /// The key stored for an address no source has now: removed, and said when it could not be.
    private func removeOldKey(_ address: String) {
        keys[address] = nil
        latestKey[address] = nil
        keyStatusProblems[address] = nil
        keyActionProblems[address] = nil
        engine.run(["key", "remove", "--address", address], stdin: nil, timeout: 60) { [weak self] status, output in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                if !(status == 0 && PreferencesPresentation.firstLine(output) == "none") {
                    self.minutesProblem = PreferencesPresentation.oldKeyLeft(address: address)
                }
                if self.hasSource(address) { self.refreshKey(address) } // a source has that address again since
            }
        }
    }

    // The source sheet (Add… and Edit…).

    /// Add…: the Claude API, at its own address.
    func beginAddSource() {
        sourceDraft = SourceDraft(index: nil, kind: .claude, address: PreferencesPresentation.claudeAddress, problem: nil)
    }

    /// Edit…: the source as it is.
    func beginEditSource(at index: Int) {
        guard let source = source(at: index) else { return }
        sourceDraft = SourceDraft(index: index, kind: source.kind, address: source.address, problem: nil)
    }

    /// The sheet's kind and address, as its controls change them. The address filled in for one kind
    /// (or none) follows a new kind; one typed stays.
    func updateSourceDraft(_ change: (inout SourceDraft) -> Void) {
        guard var draft = sourceDraft else { return }
        let kind = draft.kind
        change(&draft)
        if draft.kind != kind, draft.address.isEmpty || draft.address == PreferencesPresentation.defaultAddress(kind) {
            draft.address = PreferencesPresentation.defaultAddress(draft.kind)
        }
        draft.problem = nil
        sourceDraft = draft
    }

    func cancelSourceDraft() { sourceDraft = nil }

    /// Add or Save: the sheet closes once the source is taken, and says why when it is not.
    func saveSourceDraft() {
        guard let draft = sourceDraft else { return }
        let source = Source(kind: draft.kind, address: draft.address, agreed: false)
        let problem: String?
        if let index = draft.index { problem = updateSource(at: index, source) } else { problem = addSource(source) }
        if let problem = problem { sourceDraft?.problem = problem } else { sourceDraft = nil }
    }

    // Keys.

    /// `key status --address A`: whether a key is stored, without reading it. An answer overtaken by a
    /// newer one for that address, or for an address no source has, is dropped.
    private func refreshKey(_ address: String) {
        keysAsked += 1
        let asked = keysAsked
        latestKey[address] = asked
        engine.run(["key", "status", "--address", address], stdin: nil, timeout: 10) { [weak self] status, output in
            MainActor.assumeIsolated {
                guard let self = self, self.latestKey[address] == asked, self.hasSource(address) else { return }
                switch (status, PreferencesPresentation.firstLine(output)) {
                case (0, "set"?): self.keys[address] = true
                case (0, "none"?): self.keys[address] = false
                default:
                    self.keys[address] = nil
                    self.keyStatusProblems[address] = PreferencesPresentation.engineProblem(status: status, output: output)
                    return
                }
                self.keyStatusProblems[address] = nil
            }
        }
    }

    /// Set…: the key sheet for that source.
    func beginKey(at index: Int) {
        guard let source = source(at: index) else { return }
        keyDraft = KeyDraft(index: index, address: source.address, text: "", problem: nil, saving: false)
    }

    func keyText(_ text: String) {
        guard keyDraft?.saving == false else { return }
        keyDraft?.text = text
        keyDraft?.problem = nil
    }

    func cancelKey() { keyDraft = nil }

    /// Stores a key for the source at `index`: `key set --address A` with the key, without the spaces
    /// around it, on stdin and never in the arguments. One the key rule refuses never reaches the engine.
    /// The sheet waits for the answer: it closes once stored, and otherwise says why in the engine's
    /// words. Then `keys` is read again.
    func saveKey(_ key: String, for index: Int) {
        guard let source = source(at: index) else { return }
        let address = source.address
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let inSheet = keyDraft?.address == address
        guard !(inSheet && keyDraft?.saving == true) else { return } // pressed again while it is being stored
        guard PreferencesPresentation.keyOK(key) else {
            if inSheet { keyDraft?.problem = PreferencesPresentation.keyRefused } else { keyActionProblems[address] = PreferencesPresentation.keyRefused }
            return
        }
        keyActionProblems[address] = nil
        if inSheet {
            keyDraft?.problem = nil
            keyDraft?.saving = true
        }
        engine.run(["key", "set", "--address", address], stdin: Data(key.utf8), timeout: 60) { [weak self] status, output in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                let waiting = self.keyDraft?.address == address && self.keyDraft?.saving == true
                if status == 0 && PreferencesPresentation.firstLine(output) == "set" {
                    if waiting { self.keyDraft = nil }
                    if self.hasSource(address) { self.keys[address] = true }
                } else {
                    let problem = PreferencesPresentation.engineProblem(status: status, output: output)
                    if waiting {
                        self.keyDraft?.problem = problem
                        self.keyDraft?.saving = false
                    } else {
                        self.keyActionProblems[address] = problem
                    }
                }
                if self.hasSource(address) { self.refreshKey(address) }
            }
        }
    }

    /// Remove: `key remove --address A`. One it could not remove may still be there: that is said, and
    /// `keys` keeps what it had until `key status`, read again after, says otherwise.
    func removeKey(for index: Int) {
        guard let source = source(at: index) else { return }
        let address = source.address
        keyActionProblems[address] = nil
        engine.run(["key", "remove", "--address", address], stdin: nil, timeout: 60) { [weak self] status, output in
            MainActor.assumeIsolated {
                guard let self = self, self.hasSource(address) else { return }
                if status == 0 && PreferencesPresentation.firstLine(output) == "none" {
                    self.keys[address] = false
                } else {
                    self.keyActionProblems[address] = PreferencesPresentation.keyNotRemoved(PreferencesPresentation.engineProblem(status: status, output: output))
                }
                self.refreshKey(address)
            }
        }
    }

    // Listings.

    /// Check: lists that source's models.
    func refreshListing(at index: Int) {
        if let source = source(at: index) { list(source) }
    }

    /// The writer picker is opening, in Preferences or a redo sheet: every source's models are listed.
    func writerPickerOpened() {
        preferences.sources.forEach { list($0) }
    }

    /// `engines --kind K --address A` with a 10 s limit. An answer overtaken by a newer one for that
    /// address, or for a source since changed or removed, is dropped.
    private func list(_ source: Source) {
        listingsAsked += 1
        let asked = listingsAsked
        latestListing[source.address] = asked
        engine.run(["engines", "--kind", source.kind.rawValue, "--address", source.address], stdin: nil, timeout: 10) { [weak self] status, output in
            MainActor.assumeIsolated {
                guard let self = self, self.latestListing[source.address] == asked,
                      self.preferences.sources.contains(where: { $0.kind == source.kind && $0.address == source.address }) else { return }
                self.listings[source.address] = PreferencesPresentation.listing(status: status, output: output)
            }
        }
    }

    // The writer and agreement.

    /// "Write the minutes with" in Preferences, at the saved choice.
    var writerOptions: [WriterOption] {
        PreferencesPresentation.writerChoice(sources: preferences.sources, listings: listings, saved: preferences.minutesWriter)
    }

    var writerSelection: Int {
        let saved = preferences.minutesWriter
        return writerOptions.firstIndex { $0.writer == saved } ?? 0
    }

    /// The redo sheet's own writer, when it is an outside one.
    private var redoWriter: OutsideWriter? {
        if case .outside(let writer)? = library.redoing?.writer { return writer }
        return nil
    }

    /// "Write the minutes with" in a redo sheet, at the sheet's writer.
    var redoWriterOptions: [WriterOption] {
        PreferencesPresentation.writerChoice(sources: preferences.sources, listings: listings, saved: redoWriter)
    }

    var redoWriterSelection: Int {
        let saved = redoWriter
        return redoWriterOptions.firstIndex { $0.writer == saved } ?? 0
    }

    /// The line under the Preferences picker, for the writer a job would use now: an outside one only
    /// while its source is agreed (`ScriptRunner.writer`, the launch-time rule).
    var privacy: (text: String, amber: Bool) {
        PreferencesPresentation.privacyLine(writer: ScriptRunner.writer(meeting: nil, settings: preferences.runSettings).use)
    }

    /// "Outside models need Node 20 or later. Run meetingbox setup." while the engine says so.
    var outsideRuntimeLine: String? { PreferencesPresentation.outsideRuntimeLine(engineStatus) }

    /// The Preferences picker: Apple (nil) at once; an outside model through `ask`.
    func chooseWriter(_ writer: OutsideWriter?) {
        writerNotice = nil
        guard let writer = writer else {
            objectWillChange.send()
            preferences.minutesWriter = nil
            return
        }
        ask(writer, origin: .preferences)
    }

    /// An outside writer chosen in Preferences or in a redo sheet. Taken at once when its source is
    /// agreed. Otherwise agreement is asked for (`consent`), except for a Claude API model whose source
    /// has no key, which says "Set a key for this source first." instead. A name the engine would refuse,
    /// or a source that has gone or changed, is said and nothing is taken.
    private func ask(_ writer: OutsideWriter, origin: ConsentOrigin) {
        let notice: String?
        if let problem = PreferencesPresentation.modelNameProblem(writer.model) {
            notice = problem
        } else if let index = sourceOf(writer) {
            if preferences.sources[index].agreed {
                take(writer, origin)
                return
            }
            if writer.kind == .claude && keys[writer.address] == false {
                notice = PreferencesPresentation.setKeyFirst
            } else {
                consent = ConsentRequest(writer: writer, origin: origin)
                return
            }
        } else {
            notice = PreferencesPresentation.writerGone(writer)
        }
        switch origin {
        case .preferences: writerNotice = notice
        case .redo: library.showWriterNotice(notice)
        }
    }

    /// An agreed writer becomes Preferences' choice, or the redo sheet's.
    private func take(_ writer: OutsideWriter, _ origin: ConsentOrigin) {
        switch origin {
        case .preferences:
            objectWillChange.send()
            preferences.minutesWriter = writer
        case .redo:
            library.setRedoWriter(.outside(writer))
        }
    }

    /// "Send transcripts to <host>": the source is marked agreed, then the writer is taken where it was
    /// chosen. Nothing, if the source has changed or gone since.
    func agree() {
        guard let request = consent else { return }
        consent = nil
        guard let index = sourceOf(request.writer) else { return }
        var sources = preferences.sources
        sources[index].agreed = true
        objectWillChange.send()
        preferences.sources = sources
        take(request.writer, request.origin)
    }

    /// Cancel: nothing else changes.
    func cancelConsent() { consent = nil }

    func setModelName(_ name: String, for address: String) { modelNames[address] = name }

    /// Use, or Return in a source's Model name field: that name, as the source's model, chosen where the
    /// field is.
    func useModelName(for address: String, origin: ConsentOrigin) {
        guard let source = preferences.sources.first(where: { $0.address == address }) else { return }
        let writer = OutsideWriter(kind: source.kind, address: address,
                                   model: (modelNames[address] ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        switch origin {
        case .preferences:
            chooseWriter(writer)
        case .redo:
            if let problem = PreferencesPresentation.modelNameProblem(writer.model) {
                library.showWriterNotice(problem)
            } else {
                library.setRedoWriter(.outside(writer))
            }
        }
    }

    /// The one sheet the Preferences window shows, if any.
    var preferencesSheet: PreferencesSheet? {
        if sample != .idle { return .sample }
        if consent?.origin == .preferences { return .consent }
        if keyDraft != nil { return .key }
        if sourceDraft != nil { return .source }
        return nil
    }

    /// The sheet closed from outside (Escape): as its Cancel, or Done for the voice sample.
    func closePreferencesSheet() {
        switch preferencesSheet {
        case .sample?: closeSample()
        case .consent?: cancelConsent()
        case .key?: cancelKey()
        case .source?: cancelSourceDraft()
        case nil: break
        }
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

    // MARK: the window's top bar: the recording's controls and the player

    /// A voice sample holds the microphone: from its start until the sampler has stopped (`sample` stays
    /// `.recording` while it stops). Nothing plays meanwhile.
    var sampling: Bool {
        if case .recording = sample { return true }
        return false
    }

    /// What the top bar shows (TopBarPresentation.swift). The phase is the session's own, read on its tick
    /// queue (this one), so Play is refused from the moment a recording starts; a recorder left running
    /// and not confirmed yet counts as taking the sound in, as a sample does. A meeting is `selected` once
    /// its folder is read and its recording finished, so missing audio is said only there. The length is
    /// the file the player holds, else the selected meeting's recorded length. Its Pause, Resume and Stop
    /// are the menu bar's actions, which the bar hands to `perform`.
    var topBar: TopBar {
        let meeting = library.selectedMeeting
        let files = library.shownContent?.files
        return TopBarPresentation.bar(phase: session.phase, seconds: status.seconds, sampling: sampling || session.unconfirmed,
                                      player: player.state, selected: TopBarPresentation.selected(meeting?.folder.url, files: files),
                                      audio: files?.audio, position: player.position,
                                      duration: TopBarPresentation.length(loaded: player.duration, recorded: meeting?.record?.seconds ?? 0))
    }

    /// Play or Pause, only while the bar offers it: never while a recording runs, is paused or is being
    /// saved, while a recorder left running is unconfirmed, or while a voice sample records.
    func togglePlayer() {
        guard let playback = topBar.player, playback.toggle.enabled, let file = playback.file else { return }
        player.toggle(file)
    }

    /// Stop: back to the start.
    func stopPlayer() {
        player.stop()
    }

    /// The slider, while the player holds a file.
    func seekPlayer(to seconds: Double) {
        guard topBar.player?.canSeek == true else { return }
        player.seek(to: seconds)
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

/// Where an outside writer was chosen: in Preferences, or in a redo sheet.
enum ConsentOrigin: Equatable { case preferences, redo }

/// The agreement asked for before transcripts may go to a source: "Send transcripts to <host>?".
struct ConsentRequest: Equatable {
    let writer: OutsideWriter
    let origin: ConsentOrigin
}

/// The source sheet: a new source (`index` nil) or the one at `index`, its kind and address as typed,
/// and why it was not taken.
struct SourceDraft: Equatable {
    let index: Int?
    var kind: SourceKind
    var address: String
    var problem: String?
}

/// The key sheet for one source: the key as typed, why it was not stored, and whether the engine is
/// storing it now.
struct KeyDraft: Equatable {
    let index: Int
    let address: String
    var text: String
    var problem: String?
    var saving: Bool
}

/// The sheet the Preferences window shows: the voice sample, agreement, a key, or a source.
enum PreferencesSheet: Equatable { case sample, consent, key, source }
