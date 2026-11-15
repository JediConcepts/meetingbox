import AppKit
import Combine

/// Everything the meetingbox window remembers: the meetings and which are listed, the selection and the
/// pane, the search, the text of the selected meeting and which transcript of it is shown, the rename
/// sheet with its text and error, and the redo sheets. `AppModel` owns it and `LibraryWindow` draws it;
/// the decisions are `LibraryPresentation`'s.
///
/// It runs on the main queue, which is also the session's and the processing queue's tick queue, so
/// reading `session.phase` and `queue.current` and calling `queue.process` and `queue.redo` here is safe.
/// Nothing slow runs on it: the scan, the transcripts, the search, the reading of a meeting's files and
/// the check a redo makes before it is queued are done on two background queues and published back
/// here, and a result that a newer request has overtaken is dropped.
@MainActor
final class LibraryModel: ObservableObject {
    enum Pane: CaseIterable {
        case minutes, transcript

        var title: String { self == .minutes ? "Minutes" : "Transcript" }
    }

    /// What the rows and the actions depend on apart from the clock: the session's phase and the queue's job.
    struct Live: Equatable {
        var phase: Session.Phase = .idle
        var processing: URL? = nil
        var stage: String? = nil
    }

    /// What the selected meeting's folder holds for the detail pane, read off the main queue.
    struct Content: Equatable {
        let key: String
        let minutes: AttributedString?
        let transcript: String?
        let files: MeetingFiles
        /// What the Transcript view's picker lists (`LibraryPresentation.transcriptVersions`).
        let versions: [TranscriptVersion]
    }

    /// A redo sheet: Redo minutes (`minutes`) or Transcribe again (`transcribe`) for one meeting, and what
    /// it will run with. Redo minutes uses only the writer.
    struct RedoDraft: Equatable {
        let folder: URL
        /// The meeting's `meeting.json` id when the sheet opened (nil for a folder with no record), so the
        /// check at the click can tell that the folder at the path is still that meeting.
        let id: String?
        let kind: JobKind
        var transcriber: Transcriber
        /// The counts; nil is Work it out.
        var room: Int?
        var call: Int?
        var tidy: Bool
        var writer: MeetingWriter
    }

    struct RenameDraft: Equatable {
        let key: String
        var text: String
        var error: String? = nil
    }

    /// How the window hands something to another application: the only two ways it does. A test gives
    /// its own, so nothing is really opened.
    struct Opener {
        /// Opens the file in the application with this bundle identifier; false when there is no such
        /// application, and then nothing is opened.
        var open: (URL, String) -> Bool
        /// Opens a Finder window on the folder itself, showing its files, without opening any of them.
        var showFolder: (URL) -> Void

        static let system = Opener(
            open: { file, bundleID in
                guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
                NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                return true
            },
            // With no file named, AppKit documents that the Finder opens a window on the folder itself and
            // selects nothing; nothing in it is opened.
            showFolder: { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: $0.path) })
    }

    /// The first scan has come back, so an empty list means no meetings rather than not yet read.
    @Published private(set) var hasScanned = false
    /// Every meeting, newest first, as the last scan found them.
    @Published private(set) var meetings: [Meeting] = []
    /// The ones the search lets through.
    @Published private(set) var visible: [Meeting] = []
    /// The keys of the meetings Process is offered for (never processed or failed, with the audio a job
    /// runs and a finished recording), worked out by each scan off the main queue.
    @Published private(set) var processable: Set<String> = []
    @Published private(set) var live = Live()
    /// The selected meeting's folder, as a `LibraryPresentation.key`.
    @Published private(set) var selection: String?
    @Published private(set) var content: Content?
    @Published private(set) var searchText = ""
    @Published var pane: Pane = .minutes
    @Published private(set) var renaming: RenameDraft?
    /// The redo sheet that is open, if one is.
    @Published private(set) var redoing: RedoDraft?
    /// The transcript the Transcript view shows: nil for Current (`transcript.txt`), else another file
    /// from the picker. Read only: choosing one changes no file. Back to Current when another meeting is
    /// selected and when `show` is asked for one; a rescan keeps it.
    @Published private(set) var version: URL?
    /// The listed entry `version` was chosen from, so the picker can still name it once it has gone.
    private var chosen: TranscriptVersion?
    /// Why the last action did nothing (Open in QuickTime Player when it is not installed), until the next
    /// action or another meeting is chosen.
    @Published private(set) var problem: String?
    /// A meeting the window was asked to show (`show`) that is not in the meetings folder: one recorded
    /// in a folder of its own. It is read with each scan while it is selected, and never listed.
    @Published private(set) var outside: Meeting?

    private let store: MeetingStore
    private let session: Session
    private let queue: ProcessingQueue
    private let opener: Opener
    /// What a job launched now would run with (the app's Preferences), read when a sheet opens and when
    /// it is committed.
    private let settings: () -> RunSettings
    /// Pause, resume and stop: `AppModel.perform`, so they take the path every recording command takes.
    var control: (@MainActor (MenuAction) -> Void)?
    /// An outside writer chosen in a redo sheet, or committed there, whose source Preferences have not
    /// agreed: `AppModel` asks for agreement (`.redo`), or shows why it cannot (`showWriterNotice`).
    var requestConsent: (@MainActor (OutsideWriter) -> Void)?
    /// Why the writer just chosen in the redo sheet was not taken ("Set a key for this source first."),
    /// until the next choice or the sheet closes.
    @Published private(set) var writerNotice: String?
    /// Redo's check is running (`commitRedo` until it is back): the sheet's choices stay as they are, so
    /// the job runs with what the sheet shows.
    @Published private(set) var redoChecking = false
    /// Told when a redo sheet closes (Cancel, from outside, or once its check has queued it or found it
    /// busy) and when another one begins: an agreement asked from it goes with it.
    var redoEnded: (@MainActor () -> Void)?
    /// Each redo sheet's number, given by `beginRedo`.
    private(set) var redoSerial = 0
    /// Counts the writer choices made in redo sheets, a new sheet and Redo itself, so an answer that comes
    /// late (the key read for a choice) can tell whether that choice is still the latest.
    private(set) var redoChoice = 0
    /// The number of the redo sheet now open, or nil when none is.
    var openRedo: Int? { redoing == nil ? nil : redoSerial }
    /// Told when `select` or `show` changes which meeting is selected, and not otherwise.
    var onSelectionChange: (() -> Void)?
    /// What tells whether a lock's owner is alive (`ProcessingLock.owner`), for a meeting's folder and for
    /// a redo's check; tests give one that cannot run.
    var ps = URL(fileURLWithPath: "/bin/ps")
    /// Lists a meeting's transcripts, on the reader queue (`versions(in:)`); tests wrap it to see where it runs.
    var listVersions: @Sendable (URL) -> [TranscriptVersion] = { LibraryModel.versions(in: $0) }

    private let reader = DispatchQueue(label: "meetingbox.library.read", qos: .userInitiated)
    private let searcher = DispatchQueue(label: "meetingbox.library.search", qos: .userInitiated)
    private var scanToken = 0
    private var searchToken = 0
    private var loadToken = 0
    private var redoToken = 0
    /// The store has read the transcripts of the meetings in `meetings`. Cleared by each scan.
    private var indexed = false
    /// The folder `show` was last asked for, until another meeting is chosen.
    private var shown: URL?

    init(store: MeetingStore, session: Session, queue: ProcessingQueue, opener: Opener = .system,
         settings: @escaping () -> RunSettings = { .defaults }) {
        self.store = store
        self.session = session
        self.queue = queue
        self.opener = opener
        self.settings = settings
    }

    // MARK: what the views read

    var selectedMeeting: Meeting? {
        selection.flatMap(meeting(withKey:))
    }

    /// A listed meeting, or the one shown from outside the meetings folder.
    private func meeting(withKey key: String) -> Meeting? {
        if let listed = meetings.first(where: { LibraryPresentation.key($0.folder.url) == key }) { return listed }
        return outside.flatMap { LibraryPresentation.key($0.folder.url) == key ? $0 : nil }
    }

    var rows: [LibraryRow] {
        LibraryPresentation.rows(visible, phase: live.phase, processing: live.processing, stage: live.stage, processable: processable)
    }

    func row(_ meeting: Meeting) -> LibraryRow {
        LibraryPresentation.row(meeting, phase: live.phase, processing: live.processing, stage: live.stage,
                                processable: processable.contains(LibraryPresentation.key(meeting.folder.url)))
    }

    /// The selected meeting's text, once it has been read (not the previous selection's).
    var shownContent: Content? {
        content?.key == selection ? content : nil
    }

    func actions(for meeting: Meeting) -> [LibraryAction] {
        LibraryPresentation.actions(for: meeting, phase: live.phase, files: files(of: meeting), processing: live.processing)
    }

    /// What the detail says under the meeting's title (`LibraryPresentation.notes`).
    func notes(for meeting: Meeting) -> [String] {
        LibraryPresentation.notes(for: meeting, row: row(meeting), files: files(of: meeting))
    }

    /// What the meeting's folder holds, once it has been read for the detail; nothing until then.
    private func files(of meeting: Meeting) -> MeetingFiles {
        content?.key == LibraryPresentation.key(meeting.folder.url) ? (content?.files ?? MeetingFiles()) : MeetingFiles()
    }

    // MARK: loading

    /// Scans the Meetings folder off the main queue, and reads the meeting `show` was asked for when it
    /// is not in it. Called after a job, after a rename, when the window becomes key, and when the
    /// session changes phase (a new recording appears at once).
    func reload() {
        scanToken += 1
        let token = scanToken
        let store = self.store
        let shown = self.shown
        reader.async { [weak self] in
            let found = store.scan()
            let outside = shown.flatMap { dir in
                found.contains { LibraryPresentation.samePlace($0.folder.url, dir) } ? nil : MeetingStore.meeting(at: dir)
            }
            // Only the meetings that were never processed or failed need their folders looked at.
            let processable = Set((found + [outside].compactMap { $0 })
                .filter { ($0.state == .unprocessed || $0.state == .failed) && MeetingFiles.canRun($0.folder.url) }
                .map { LibraryPresentation.key($0.folder.url) })
            Task { @MainActor in self?.scanned(found, outside, processable, token) }
        }
    }

    private func scanned(_ found: [Meeting], _ outside: Meeting?, _ canProcess: Set<String>, _ token: Int) {
        guard token == scanToken else { return }
        hasScanned = true
        processable = canProcess
        meetings = found
        // Not if another meeting has been chosen since this scan began.
        self.outside = outside.flatMap { o in shown.map { LibraryPresentation.samePlace($0, o.folder.url) } == true ? o : nil }
        indexed = false
        refilter()
        loadContent()
    }

    /// Reads the selected meeting's minutes, the transcript `version` names (else `transcript.txt`), the
    /// transcripts the picker lists, and what its folder holds, off the main queue.
    private func loadContent() {
        loadToken += 1
        let token = loadToken
        guard let folder = selectedMeeting?.folder, let key = selection else {
            content = nil
            return
        }
        let version = self.version
        let (ps, list) = (self.ps, self.listVersions)
        reader.async { [weak self] in
            let dir = folder.url
            func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
            // A chosen version is read only while it is a plain file, never through a link.
            let transcript = version.map { LibraryModel.isPlain($0, S_IFREG) ? read($0) : nil } ?? read(dir.appendingPathComponent("transcript.txt"))
            let loaded = Content(key: key, minutes: read(dir.appendingPathComponent("notes.md")).map(LibraryPresentation.minutes),
                                 transcript: transcript, files: MeetingFiles.read(folder, ps: ps), versions: list(dir))
            Task { @MainActor in self?.loaded(loaded, token, version) }
        }
    }

    /// Dropped when a newer read has begun, or when another version has been chosen since this one began.
    private func loaded(_ new: Content, _ token: Int, _ version: URL?) {
        guard token == loadToken, version == self.version, content != new else { return }
        content = new
    }

    /// The transcripts a meeting's folder holds: its own `transcript*.txt` files, and the `transcript.txt`
    /// in each folder in its `earlier/`. No link is followed, as the engine follows none there: `earlier`
    /// and each folder in it must be real folders, and every transcript a plain file. Call it off the main
    /// queue.
    nonisolated static func versions(in dir: URL) -> [TranscriptVersion] {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter {
            isPlain(dir.appendingPathComponent($0), S_IFREG)
        }
        let earlier = dir.appendingPathComponent("earlier", isDirectory: true)
        let listed = isPlain(earlier, S_IFDIR) ? (try? fm.contentsOfDirectory(atPath: earlier.path)) ?? [] : []
        let kept = listed.filter {
            let folder = earlier.appendingPathComponent($0, isDirectory: true)
            return !$0.hasPrefix(".") && isPlain(folder, S_IFDIR) && isPlain(folder.appendingPathComponent("transcript.txt"), S_IFREG)
        }
        return LibraryPresentation.transcriptVersions(in: dir, files: files, earlier: kept)
    }

    /// The path is a file of this type (`S_IFREG`, `S_IFDIR`) itself, not a link to one.
    nonisolated private static func isPlain(_ url: URL, _ type: mode_t) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == type
    }

    /// What the transcript picker offers: the selected meeting's versions when there is more than Current,
    /// or while another is chosen (even one deleted since, which reads as no transcript), so there is
    /// always a way back to Current. Empty when there is nothing to choose.
    /// A chosen version no longer listed (deleted in Finder) stays in the list, titled as it was, so the
    /// picker never shows a blank choice; it reads as no transcript.
    var versionChoices: [TranscriptVersion] {
        guard let versions = shownContent?.versions, versions.count > 1 || version != nil else { return [] }
        guard let gone = chosen, gone.url == version, !versions.contains(where: { $0.url == gone.url }) else { return versions }
        return versions + [gone]
    }

    /// Shows another of the selected meeting's transcripts, one the picker lists, read only: nothing is
    /// written, and search and the minutes still use `transcript.txt`. Current (the first) or nil goes back.
    func chooseVersion(_ url: URL?) {
        guard let versions = shownContent?.versions else { return }
        let next: URL?
        if let url = url {
            guard let index = versions.firstIndex(where: { $0.url == url }) else { return }
            next = index == 0 ? nil : url
            chosen = index == 0 ? nil : versions[index]
        } else {
            next = nil
        }
        guard next != version else { return }
        version = next
        loadContent()
    }

    // MARK: search

    func search(_ text: String) {
        guard text != searchText else { return }
        searchText = text
        refilter()
    }

    /// A blank search lists every meeting at once. Otherwise the transcripts are indexed (once per scan),
    /// then the meetings are matched, both off the main queue and one search after another, so a later
    /// keystroke never reads a half-built index.
    private func refilter() {
        searchToken += 1
        let token = searchToken
        let query = searchText
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            visible = meetings
            return
        }
        let snapshot = meetings
        let store = self.store
        let needsIndex = !indexed
        indexed = true
        searcher.async { [weak self] in
            if needsIndex {
                let built = DispatchSemaphore(value: 0)
                store.indexTranscripts { built.signal() }
                built.wait()
            }
            let found = LibraryPresentation.visible(snapshot, query: query, store: store)
            Task { @MainActor in self?.filtered(found, token) }
        }
    }

    private func filtered(_ found: [Meeting], _ token: Int) {
        guard token == searchToken else { return }
        visible = found
    }

    // MARK: selection

    /// Another meeting is chosen: its Current transcript is shown, and `onSelectionChange` is told.
    func select(_ key: String?) {
        guard key != selection else { return }
        selection = key
        problem = nil
        version = nil
        if let dir = shown, LibraryPresentation.key(dir) != key {
            shown = nil
            outside = nil
        }
        loadContent()
        onSelectionChange?()
    }

    /// The window is asked to show this meeting's minutes (a job finished, or "Minutes ready" was
    /// chosen): the search is cleared so the meeting is in the list, and the list is read again. A
    /// meeting outside the meetings folder (recorded in a folder of its own) is read with it and shown,
    /// but not listed. Its Current transcript is shown, even when it was the one selected; only a change
    /// of selection tells `onSelectionChange`.
    func show(_ dir: URL) {
        let key = LibraryPresentation.key(dir)
        let changed = key != selection
        searchText = ""
        pane = .minutes
        selection = key
        version = nil
        shown = dir
        problem = nil
        refilter()
        loadContent()
        reload()
        if changed { onSelectionChange?() }
    }

    /// The session or the queue moved on. A new phase is a new list: a recording that has just begun
    /// is a meeting, and one that has just ended has its length.
    func update(_ status: StatusInput) {
        let next = Live(phase: status.phase, processing: status.processing, stage: status.stage)
        guard next != live else { return }
        let phaseChanged = next.phase != live.phase
        live = next
        if phaseChanged { reload() }
    }

    // MARK: actions

    func perform(_ action: LibraryAction) {
        guard let meeting = selectedMeeting else { return }
        problem = nil
        switch action {
        case .pause: control?(.pause)
        case .resume: control?(.resume)
        case .stop: control?(.stop)
        case .rename: beginRename()
        case .showInFinder:
            // The meeting's own folder, with its files, not the folder of meetings around it.
            opener.showFolder(meeting.folder.url)
        case .playAudio:
            // Only while it is offered (never during a recording or a pause), and only in QuickTime Player.
            guard actions(for: meeting).contains(.playAudio), let audio = shownContent?.files.audio else { return }
            if !opener.open(audio, LibraryPresentation.quickTimePlayer) { problem = LibraryPresentation.needsQuickTime }
        case .process:
            // A failed meeting goes through retry; one that was never processed is written queued first.
            if meeting.state == .failed { queue.retry(meeting.folder.url) } else { queue.process(meeting.folder.url) }
            reload()
        case .redoMinutes, .transcribeAgain:
            // Only while it is offered: never for a meeting something has a claim on.
            guard actions(for: meeting).contains(action) else { return }
            beginRedo(meeting, kind: action == .redoMinutes ? .minutes : .transcribe)
        }
    }

    // MARK: redo

    /// Opens a redo sheet. It starts at the transcriber and tidying chosen in Preferences (never those of
    /// the meeting's last redo), at the meeting's saved counts, and at the meeting's own writer, else the
    /// Preferences one.
    func beginRedo(_ meeting: Meeting, kind: JobKind) {
        guard kind != .process else { return }
        let settings = self.settings()
        let record = meeting.record
        redoToken += 1 // a check still running for an earlier sheet is dropped
        redoChecking = false
        writerNotice = nil
        redoEnded?()
        redoSerial += 1
        redoChoice += 1
        redoing = RedoDraft(folder: meeting.folder.url, id: record?.id, kind: kind, transcriber: settings.transcriber, room: record?.people.room,
                            call: record?.people.call, tidy: settings.tidy, writer: record?.writer ?? settings.preferredWriter)
    }

    /// The sheet's choices, as its controls change them, except while Redo's check runs. The writer goes
    /// through `setRedoWriter`.
    func updateRedo(_ change: (inout RedoDraft) -> Void) {
        guard var draft = redoing, !redoChecking else { return }
        change(&draft)
        redoing = draft
    }

    /// "Write the minutes with" in a redo sheet: Apple, or an outside writer whose source Preferences
    /// have agreed (`RunSettings.agrees`), is the sheet's writer at once. Any other is not: the draft stays
    /// as it was and `requestConsent` asks for agreement, whose `agree()` then sets it here. Nothing while
    /// Redo's check runs.
    func setRedoWriter(_ writer: MeetingWriter) {
        guard redoing != nil, !redoChecking else { return }
        redoChoice += 1
        writerNotice = nil
        if case .outside(let outside) = writer, !settings().agrees(to: outside) {
            requestConsent?(outside)
            return
        }
        redoing?.writer = writer
    }

    /// The line under the sheet's writer picker, from `AppModel`; nil clears it. Only while a sheet is open.
    func showWriterNotice(_ text: String?) {
        guard redoing != nil || text == nil else { return }
        writerNotice = text
    }

    /// Closes the sheet and queues nothing; a check already under way is dropped, and so is any agreement
    /// asked from the sheet.
    func cancelRedo() {
        redoToken += 1
        redoChecking = false
        redoing = nil
        writerNotice = nil
        redoEnded?()
    }

    /// Queues the sheet's redo. An outside writer is taken only when Preferences have agreed to its
    /// source (`RunSettings.agrees`), here and again once the check is back; otherwise nothing is queued
    /// or written, the sheet stays open and agreement is asked for. Then the meeting is checked again off
    /// the main queue: its record as it is on the disk (still the same meeting's id, and its state), and
    /// the live lock a `meetingbox` run in Terminal would hold. Back on this queue, with the session and
    /// the queue's job, it is queued only if it is still that meeting, still free, and the queue takes it;
    /// otherwise "That meeting is busy" is shown under the actions. The sheet closes once the check is done,
    /// and until then its choices stay as they are (`redoChecking`).
    func commitRedo() {
        guard let draft = redoing, !redoChecking else { return }
        if case .outside(let writer) = draft.writer, !settings().agrees(to: writer) {
            requestConsent?(writer)
            return
        }
        redoChecking = true
        redoChoice += 1 // a choice still waiting on its key read is overtaken by Redo
        redoToken += 1
        let token = redoToken
        let ps = self.ps
        reader.async { [weak self] in
            let record = MeetingStore.record(in: draft.folder)
            let lock = ProcessingLock.owner(draft.folder, ps: ps, now: Date())
            Task { @MainActor in self?.redoChecked(draft, token: token, recorded: record?.state, id: record?.id, lock: lock) }
        }
    }

    private func redoChecked(_ draft: RedoDraft, token: Int, recorded: MeetingState?, id: String?, lock: ProcessingLock.Owner) {
        guard token == redoToken, redoing != nil else { return }
        redoChecking = false
        // Its source removed or changed while the check ran: as at the click, nothing goes into meeting.json.
        if case .outside(let writer) = draft.writer, !settings().agrees(to: writer) {
            requestConsent?(writer)
            return
        }
        redoing = nil
        writerNotice = nil
        redoEnded?()
        let options = draft.kind == .transcribe
            ? JobOptions(transcriber: draft.transcriber, room: draft.room, call: draft.call, tidy: draft.tidy, writer: draft.writer)
            : JobOptions(writer: draft.writer)
        // Another meeting at the path (the folders were swapped or renamed in Finder) is not this one.
        let free = id == draft.id && lock == .gone
            && !LibraryPresentation.isBusy(draft.folder, phase: session.phase, current: queue.current, recorded: recorded)
        if !(free && queue.redo(draft.folder, kind: draft.kind, options: options)),
           selection == LibraryPresentation.key(draft.folder) {
            problem = LibraryPresentation.busy
        }
        reload()
    }

    // MARK: rename

    /// The sheet opens with the title as it is, or empty for a meeting that has none.
    func beginRename() {
        guard let meeting = selectedMeeting else { return }
        let row = self.row(meeting)
        renaming = RenameDraft(key: row.id, text: row.titled ? row.title : "")
    }

    func renameText(_ text: String) {
        guard renaming != nil else { return }
        renaming?.text = text
        renaming?.error = nil
    }

    func cancelRename() {
        renaming = nil
    }

    /// Renames on this queue, the one the session and the processing queue run on, so that busy is
    /// decided at the moment of the rename (`LibraryPresentation.rename` says what is written where). A
    /// refusal is shown in the sheet, in words. If the folder moved but its title could not be saved, the
    /// sheet stays open with that said and follows the folder, and the same text again writes the title.
    func commitRename() {
        guard let draft = renaming else { return }
        guard let meeting = meeting(withKey: draft.key) else {
            renaming = nil
            return
        }
        do {
            let folder = try LibraryPresentation.rename(meeting, to: draft.text, store: store, phase: session.phase, current: queue.current)
            renaming = nil
            moved(meeting, to: folder, titled: true)
        } catch let failure as TitleNotSaved {
            moved(meeting, to: failure.folder, titled: false)
            renaming = RenameDraft(key: LibraryPresentation.key(failure.folder.url), text: draft.text, error: LibraryPresentation.renameMessage(failure))
        } catch {
            renaming?.error = LibraryPresentation.renameMessage(error)
        }
    }

    /// The list as a rename leaves it, at once and before the rescan that follows: the folder where it
    /// now is, the selection with it, and the record's title when it was written.
    private func moved(_ meeting: Meeting, to folder: MeetingFolder, titled: Bool) {
        let before = LibraryPresentation.key(meeting.folder.url)
        let patch = { (m: Meeting) -> Meeting in
            guard LibraryPresentation.key(m.folder.url) == before else { return m }
            var record = m.record
            if titled { record?.title = folder.title }
            return Meeting(folder: folder, record: record, state: m.state)
        }
        meetings = meetings.map(patch)
        visible = visible.map(patch)
        if let o = outside, LibraryPresentation.key(o.folder.url) == before {
            outside = patch(o)
            shown = folder.url
        }
        if processable.remove(before) != nil { processable.insert(LibraryPresentation.key(folder.url)) }
        if selection == before {
            selection = LibraryPresentation.key(folder.url)
            version = nil // the file it named has moved with the folder: Current again
        }
        loadContent()
        reload()
    }
}
